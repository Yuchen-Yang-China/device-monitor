using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace DeviceMonitor.Protocol;

public static class AuthenticationHeaders
{
    public const string DeviceId = "X-DM-Device-Id";
    public const string Timestamp = "X-DM-Timestamp";
    public const string Nonce = "X-DM-Nonce";
    public const string Signature = "X-DM-Signature";
    public const string ApiVersion = "X-DM-Api-Version";
}

public static class PeerAuthentication
{
    private const string EmptyBodyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    public static string CreateRequestSignature(ReadOnlySpan<byte> secret, long timestamp, string nonce) =>
        HmacHex(secret, $"GET\n{ProtocolConstants.StatusPath}\n{timestamp}\n{nonce}\n{EmptyBodyHash}");

    public static string CreateResponseSignature(ReadOnlySpan<byte> secret, long timestamp, string requestNonce, ReadOnlySpan<byte> rawBody)
    {
        var bodyHash = Convert.ToHexStringLower(SHA256.HashData(rawBody));
        return HmacHex(secret, $"200\n{ProtocolConstants.StatusPath}\n{timestamp}\n{requestNonce}\n{bodyHash}");
    }

    public static bool VerifyRequestSignature(ReadOnlySpan<byte> secret, long timestamp, string nonce, string supplied) =>
        FixedTimeHexEquals(CreateRequestSignature(secret, timestamp, nonce), supplied);
    public static bool VerifyResponseSignature(ReadOnlySpan<byte> secret, long timestamp, string nonce, ReadOnlySpan<byte> body, string supplied) =>
        FixedTimeHexEquals(CreateResponseSignature(secret, timestamp, nonce, body), supplied);

    public static bool IsWithinWindow(long timestampMilliseconds, DateTimeOffset now) =>
        Math.Abs((decimal)now.ToUnixTimeMilliseconds() - timestampMilliseconds) <= (decimal)ProtocolConstants.AuthenticationWindow.TotalMilliseconds;

    public static string CreateNonce() { Span<byte> bytes = stackalloc byte[16]; RandomNumberGenerator.Fill(bytes); return Base64UrlEncode(bytes); }
    public static byte[] GenerateSecret() { var bytes = new byte[32]; RandomNumberGenerator.Fill(bytes); return bytes; }
    public static string Base64UrlEncode(ReadOnlySpan<byte> bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static byte[] Base64UrlDecode(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Contains('=') || value.Any(c => !(char.IsLetterOrDigit(c) || c is '-' or '_')))
            throw new FormatException("Invalid unpadded Base64URL value.");
        var padded = value.Replace('-', '+').Replace('_', '/');
        padded += new string('=', (4 - padded.Length % 4) % 4);
        return Convert.FromBase64String(padded);
    }

    public static bool IsValidNonce(string nonce) { try { return Base64UrlDecode(nonce).Length >= 16; } catch (FormatException) { return false; } }

    private static string HmacHex(ReadOnlySpan<byte> secret, string canonical)
    {
        using var hmac = new HMACSHA256(secret.ToArray());
        return Convert.ToHexStringLower(hmac.ComputeHash(Encoding.UTF8.GetBytes(canonical)));
    }

    private static bool FixedTimeHexEquals(string expected, string supplied)
    {
        if (supplied.Length != 64 || supplied.Any(c => c is not (>= '0' and <= '9') and not (>= 'a' and <= 'f'))) return false;
        var expectedBytes = Convert.FromHexString(expected);
        var suppliedBytes = Convert.FromHexString(supplied);
        return CryptographicOperations.FixedTimeEquals(expectedBytes, suppliedBytes);
    }
}

public sealed class NonceReplayCache
{
    private readonly ConcurrentDictionary<string, long> _accepted = new(StringComparer.Ordinal);
    private long _nextCleanupMilliseconds;
    public bool TryAccept(string nonce, DateTimeOffset now)
    {
        var nowMilliseconds = now.ToUnixTimeMilliseconds();
        if (nowMilliseconds >= Interlocked.Read(ref _nextCleanupMilliseconds)) Cleanup(nowMilliseconds);
        return _accepted.TryAdd(nonce, nowMilliseconds);
    }
    public int Count => _accepted.Count;
    private void Cleanup(long nowMilliseconds)
    {
        var cutoff = nowMilliseconds - (long)ProtocolConstants.NonceRetention.TotalMilliseconds;
        foreach (var item in _accepted) if (item.Value < cutoff) _accepted.TryRemove(item.Key, out _);
        Interlocked.Exchange(ref _nextCleanupMilliseconds, nowMilliseconds + 30_000);
    }
}
