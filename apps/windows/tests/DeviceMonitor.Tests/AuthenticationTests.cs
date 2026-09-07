using DeviceMonitor.Protocol;

namespace DeviceMonitor.Tests;

public sealed class AuthenticationTests
{
    private static readonly byte[] Secret = Convert.FromHexString("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");

    [Fact] public void FixedRequestVectorMatchesProtocol()
    {
        var actual = PeerAuthentication.CreateRequestSignature(Secret, 1788681600123, "AAECAwQFBgcICQoLDA0ODw");
        Assert.Equal("ba66319222045ec9fde8f1aee9e39a378d77af5c3413c0b6306b05c62b83586f", actual);
    }

    [Fact] public void ChangedRequestSignatureIsRejected() =>
        Assert.False(PeerAuthentication.VerifyRequestSignature(Secret, 1788681600123, "AAECAwQFBgcICQoLDA0ODw", "aa66319222045ec9fde8f1aee9e39a378d77af5c3413c0b6306b05c62b83586f"));

    [Fact] public void ChangedResponseBodyIsRejected()
    {
        const string nonce = "AAECAwQFBgcICQoLDA0ODw"; var body = "{}"u8.ToArray();
        var signature = PeerAuthentication.CreateResponseSignature(Secret, 1788681600456, nonce, body);
        Assert.True(PeerAuthentication.VerifyResponseSignature(Secret, 1788681600456, nonce, body, signature));
        Assert.False(PeerAuthentication.VerifyResponseSignature(Secret, 1788681600456, nonce, "{ }"u8, signature));
    }

    [Fact] public void FixedResponseVectorMatchesCanonicalForm()
    {
        var actual = PeerAuthentication.CreateResponseSignature(Secret, 1788681600456, "AAECAwQFBgcICQoLDA0ODw", "{}"u8);
        Assert.Equal("66c95c35059edc92762ee50f0089d2a71e2e83956d6ea9a60aa7fd3af34cb7ee", actual);
    }

    [Fact] public void TimestampWindowIsExactlyOneHundredTwentySeconds()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(1788681600123);
        Assert.True(PeerAuthentication.IsWithinWindow(now.AddSeconds(-120).ToUnixTimeMilliseconds(), now));
        Assert.False(PeerAuthentication.IsWithinWindow(now.AddMilliseconds(-120001).ToUnixTimeMilliseconds(), now));
        Assert.False(PeerAuthentication.IsWithinWindow(long.MinValue, now));
        Assert.False(PeerAuthentication.IsWithinWindow(long.MaxValue, now));
    }

    [Fact] public void NonceCannotBeReusedAndExpiresAfterFiveMinutes()
    {
        var cache = new NonceReplayCache(); var now = DateTimeOffset.FromUnixTimeMilliseconds(1788681600123);
        Assert.True(cache.TryAccept("AAECAwQFBgcICQoLDA0ODw", now));
        Assert.False(cache.TryAccept("AAECAwQFBgcICQoLDA0ODw", now.AddMinutes(1)));
        Assert.True(cache.TryAccept("AAECAwQFBgcICQoLDA0ODw", now.AddMinutes(5).AddMilliseconds(1)));
    }

    [Fact] public void GeneratedValuesHaveRequiredEntropyAndEncoding()
    {
        Assert.Equal(32, PeerAuthentication.GenerateSecret().Length);
        Assert.True(PeerAuthentication.IsValidNonce(PeerAuthentication.CreateNonce()));
        Assert.Equal(32, PeerAuthentication.Base64UrlDecode("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8").Length);
    }
}
