using System.Net;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.Tests;

public sealed class PeerClientTests
{
    private static readonly byte[] Secret = Convert.FromHexString("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");

    [Fact] public async Task ClientVerifiesResponseBeforeDecoding()
    {
        var body = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json"));
        using var http = new HttpClient(new SignedHandler(body, Secret));
        var result = await new PeerStatusClient(http).GetStatusAsync(new Uri("http://127.0.0.1:48621/v1/status"), Guid.NewGuid().ToString("D"), Secret);
        Assert.Equal(42, result.Sequence);
    }

    [Fact] public async Task ClientRejectsTamperedBody()
    {
        var body = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json"));
        using var http = new HttpClient(new SignedHandler(body, Secret, tamperAfterSigning: true));
        var error = await Assert.ThrowsAsync<PeerTransportException>(() => new PeerStatusClient(http).GetStatusAsync(
            new Uri("http://127.0.0.1:48621/v1/status"), Guid.NewGuid().ToString("D"), Secret));
        Assert.Equal(PeerTransportError.InvalidSignature, error.Error);
    }

    [Fact] public async Task ClientRejectsBodyOverSixtyFourKiB()
    {
        var body = new byte[ProtocolConstants.MaximumBodyBytes + 1];
        using var http = new HttpClient(new SignedHandler(body, Secret));
        var error = await Assert.ThrowsAsync<PeerTransportException>(() => new PeerStatusClient(http).GetStatusAsync(
            new Uri("http://127.0.0.1:48621/v1/status"), Guid.NewGuid().ToString("D"), Secret));
        Assert.Equal(PeerTransportError.BodyTooLarge, error.Error);
    }

    [Fact] public async Task ClientAcceptsAChunkedResponseWithoutContentLength()
    {
        var body = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json"));
        using var http = new HttpClient(new SignedHandler(body, Secret, useUnknownLengthContent: true));
        var result = await new PeerStatusClient(http).GetStatusAsync(new Uri("http://127.0.0.1:48621/v1/status"), Guid.NewGuid().ToString("D"), Secret);
        Assert.Equal(42, result.Sequence);
    }

    private sealed class SignedHandler(byte[] body, byte[] secret, bool tamperAfterSigning = false, bool useUnknownLengthContent = false) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var nonce = request.Headers.GetValues(AuthenticationHeaders.Nonce).Single(); var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            var signature = PeerAuthentication.CreateResponseSignature(secret, timestamp, nonce, body);
            var sent = tamperAfterSigning ? body.Concat(new byte[] { 32 }).ToArray() : body;
            HttpContent content = useUnknownLengthContent ? new UnknownLengthContent(sent) : new ByteArrayContent(sent);
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
            if (useUnknownLengthContent) response.Headers.TransferEncodingChunked = true;
            response.Headers.TryAddWithoutValidation(AuthenticationHeaders.Timestamp, timestamp.ToString());
            response.Headers.TryAddWithoutValidation(AuthenticationHeaders.Nonce, nonce);
            response.Headers.TryAddWithoutValidation(AuthenticationHeaders.ApiVersion, "1");
            response.Headers.TryAddWithoutValidation(AuthenticationHeaders.Signature, signature);
            return Task.FromResult(response);
        }
    }

    private sealed class UnknownLengthContent(byte[] body) : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            stream.WriteAsync(body, 0, body.Length);
        protected override bool TryComputeLength(out long length) { length = 0; return false; }
    }
}
