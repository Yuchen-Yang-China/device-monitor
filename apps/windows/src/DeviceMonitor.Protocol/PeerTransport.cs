using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Server.Kestrel.Core;
using Microsoft.Extensions.Logging;

namespace DeviceMonitor.Protocol;

public enum PeerTransportError
{
    Connection, Timeout, HttpError, HeaderFormat, InvalidSignature, ClockMismatch,
    Replay, IncompatibleVersion, BodyTooLarge, InvalidBody
}

public sealed class PeerTransportException(PeerTransportError error, string message) : Exception(message)
{
    public PeerTransportError Error { get; } = error;
}

public sealed class PeerStatusServer : IAsyncDisposable
{
    private readonly Func<PeerStatusDocument> _snapshotProvider;
    private readonly byte[] _secret;
    private readonly IPAddress _listenAddress;
    private readonly int _port;
    private readonly NonceReplayCache _nonces = new();
    private readonly Dictionary<string, long> _lastAcceptedByDevice = new(StringComparer.Ordinal);
    private readonly object _rateGate = new();
    private WebApplication? _application;

    public PeerStatusServer(Func<PeerStatusDocument> snapshotProvider, ReadOnlySpan<byte> secret, IPAddress listenAddress, int port = ProtocolConstants.DefaultPort)
    {
        if (secret.Length != 32) throw new ArgumentException("Pairing secret must contain exactly 32 bytes.", nameof(secret));
        _snapshotProvider = snapshotProvider;
        _secret = secret.ToArray();
        _listenAddress = listenAddress;
        _port = port;
    }

    public string ListeningAddress => $"http://{_listenAddress}:{_port}{ProtocolConstants.StatusPath}";

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        if (_application is not null) return;
        var options = new WebApplicationOptions { Args = [], ApplicationName = typeof(PeerStatusServer).Assembly.FullName };
        var builder = WebApplication.CreateSlimBuilder(options);
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(server =>
        {
            server.Limits.MaxRequestBodySize = ProtocolConstants.MaximumBodyBytes;
            server.Listen(_listenAddress, _port, listen => listen.Protocols = HttpProtocols.Http1);
        });
        var app = builder.Build();
        app.Use(async (context, next) =>
        {
            context.Response.OnStarting(() => { context.Response.Headers.CacheControl = "no-store"; return Task.CompletedTask; });
            await next().ConfigureAwait(false);
        });
        app.MapMethods(ProtocolConstants.StatusPath, ["GET"], HandleStatusAsync);
        _application = app;
        try { await app.StartAsync(cancellationToken).ConfigureAwait(false); }
        catch { _application = null; await app.DisposeAsync().ConfigureAwait(false); throw; }
    }

    private async Task HandleStatusAsync(HttpContext context)
    {
        context.Response.Headers.CacheControl = "no-store";
        if (context.Request.QueryString.HasValue || context.Request.ContentLength is > 0)
        {
            await WriteError(context, 400, "invalid_request"); return;
        }
        if (!TrySingleHeader(context, AuthenticationHeaders.ApiVersion, out var apiText) || !int.TryParse(apiText, NumberStyles.None, CultureInfo.InvariantCulture, out var api))
        {
            await WriteError(context, 400, "invalid_headers"); return;
        }
        if (api != ProtocolConstants.ApiVersion) { await WriteError(context, 426, "incompatible_version"); return; }
        if (!TrySingleHeader(context, AuthenticationHeaders.DeviceId, out var deviceId) || !Guid.TryParseExact(deviceId, "D", out _) || deviceId != deviceId.ToLowerInvariant() ||
            !TrySingleHeader(context, AuthenticationHeaders.Timestamp, out var timestampText) || !long.TryParse(timestampText, NumberStyles.None, CultureInfo.InvariantCulture, out var timestamp) ||
            !TrySingleHeader(context, AuthenticationHeaders.Nonce, out var nonce) || !PeerAuthentication.IsValidNonce(nonce))
        {
            await WriteError(context, 400, "invalid_headers"); return;
        }
        if (!TrySingleHeader(context, AuthenticationHeaders.Signature, out var signature))
        {
            await WriteError(context, 401, "invalid_signature"); return;
        }
        var now = DateTimeOffset.UtcNow;
        if (!PeerAuthentication.IsWithinWindow(timestamp, now)) { await WriteError(context, 401, "clock_mismatch"); return; }
        if (!PeerAuthentication.VerifyRequestSignature(_secret, timestamp, nonce, signature)) { await WriteError(context, 401, "invalid_signature"); return; }
        if (!_nonces.TryAccept(nonce, now)) { await WriteError(context, 409, "replayed_nonce"); return; }
        var nowMs = now.ToUnixTimeMilliseconds();
        lock (_rateGate)
        {
            if (_lastAcceptedByDevice.TryGetValue(deviceId, out var previous) && nowMs - previous < 250)
            { context.Items["rate_limited"] = true; }
            else _lastAcceptedByDevice[deviceId] = nowMs;
        }
        if (context.Items.ContainsKey("rate_limited")) { await WriteError(context, 429, "rate_limited"); return; }

        byte[] body;
        try { body = PeerStatusCodec.Encode(_snapshotProvider()); }
        catch { await WriteError(context, 500, "internal_error"); return; }
        var responseTimestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        context.Response.StatusCode = 200;
        context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.ContentLength = body.Length;
        context.Response.Headers[AuthenticationHeaders.Timestamp] = responseTimestamp.ToString(CultureInfo.InvariantCulture);
        context.Response.Headers[AuthenticationHeaders.Nonce] = nonce;
        context.Response.Headers[AuthenticationHeaders.ApiVersion] = "1";
        context.Response.Headers[AuthenticationHeaders.Signature] = PeerAuthentication.CreateResponseSignature(_secret, responseTimestamp, nonce, body);
        await context.Response.Body.WriteAsync(body, context.RequestAborted);
    }

    private static bool TrySingleHeader(HttpContext context, string name, out string value)
    {
        if (context.Request.Headers.TryGetValue(name, out var values) && values.Count == 1 && !string.IsNullOrWhiteSpace(values[0]))
        { value = values[0]!; return true; }
        value = string.Empty; return false;
    }

    private static async Task WriteError(HttpContext context, int status, string error)
    {
        var body = Encoding.UTF8.GetBytes($"{{\"error\":\"{error}\"}}");
        context.Response.StatusCode = status; context.Response.ContentType = "application/json; charset=utf-8";
        context.Response.ContentLength = body.Length; context.Response.Headers.CacheControl = "no-store";
        await context.Response.Body.WriteAsync(body, context.RequestAborted);
    }

    public async ValueTask DisposeAsync()
    {
        if (_application is not null) { await _application.StopAsync().ConfigureAwait(false); await _application.DisposeAsync().ConfigureAwait(false); _application = null; }
        CryptographicOperations.ZeroMemory(_secret);
    }
}

public sealed class PeerStatusClient(HttpClient httpClient)
{
    public async Task<PeerStatusDocument> GetStatusAsync(Uri endpoint, string localDeviceId, ReadOnlyMemory<byte> secret, CancellationToken cancellationToken = default)
    {
        var nonce = PeerAuthentication.CreateNonce(); var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.DeviceId, localDeviceId);
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.Timestamp, timestamp.ToString(CultureInfo.InvariantCulture));
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.Nonce, nonce);
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.ApiVersion, "1");
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.Signature, PeerAuthentication.CreateRequestSignature(secret.Span, timestamp, nonce));

        HttpResponseMessage response;
        try { response = await httpClient.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false); }
        catch (TaskCanceledException exception) when (!cancellationToken.IsCancellationRequested) { throw new PeerTransportException(PeerTransportError.Timeout, exception.Message); }
        catch (HttpRequestException exception) { throw new PeerTransportException(PeerTransportError.Connection, exception.Message); }
        using (response)
        {
            if (response.StatusCode == HttpStatusCode.UpgradeRequired) throw new PeerTransportException(PeerTransportError.IncompatibleVersion, "incompatible_version");
            if (!response.IsSuccessStatusCode) throw new PeerTransportException(PeerTransportError.HttpError, $"http_{(int)response.StatusCode}");
            if (response.Content.Headers.ContentLength is > ProtocolConstants.MaximumBodyBytes) throw new PeerTransportException(PeerTransportError.BodyTooLarge, "body_too_large");
            var body = await ReadBoundedAsync(response.Content, cancellationToken).ConfigureAwait(false);
            if (!TryHeader(response, AuthenticationHeaders.ApiVersion, out var apiText) || apiText != "1")
                throw new PeerTransportException(PeerTransportError.IncompatibleVersion, "incompatible_version");
            if (!TryHeader(response, AuthenticationHeaders.Nonce, out var responseNonce) || !string.Equals(responseNonce, nonce, StringComparison.Ordinal))
                throw new PeerTransportException(PeerTransportError.HeaderFormat, "nonce_mismatch");
            if (!TryHeader(response, AuthenticationHeaders.Timestamp, out var responseTimestampText) ||
                !long.TryParse(responseTimestampText, NumberStyles.None, CultureInfo.InvariantCulture, out var responseTimestamp))
                throw new PeerTransportException(PeerTransportError.HeaderFormat, "invalid_timestamp");
            if (!PeerAuthentication.IsWithinWindow(responseTimestamp, DateTimeOffset.UtcNow))
                throw new PeerTransportException(PeerTransportError.ClockMismatch, "clock_mismatch");
            if (!TryHeader(response, AuthenticationHeaders.Signature, out var responseSignature) ||
                !PeerAuthentication.VerifyResponseSignature(secret.Span, responseTimestamp, nonce, body, responseSignature))
                throw new PeerTransportException(PeerTransportError.InvalidSignature, "invalid_signature");
            try { return PeerStatusCodec.Decode(body); }
            catch (ProtocolException exception) { throw new PeerTransportException(PeerTransportError.InvalidBody, exception.Message); }
        }
    }

    private static bool TryHeader(HttpResponseMessage response, string name, out string value)
    {
        if (response.Headers.TryGetValues(name, out var values)) { var array = values.ToArray(); if (array.Length == 1) { value = array[0]; return true; } }
        value = string.Empty; return false;
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream(); var buffer = new byte[8192];
        while (true)
        {
            var count = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false); if (count == 0) break;
            if (output.Length + count > ProtocolConstants.MaximumBodyBytes) throw new PeerTransportException(PeerTransportError.BodyTooLarge, "body_too_large");
            output.Write(buffer, 0, count);
        }
        return output.ToArray();
    }
}
