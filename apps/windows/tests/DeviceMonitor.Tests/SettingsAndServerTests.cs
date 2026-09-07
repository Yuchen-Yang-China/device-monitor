using System.Net;
using System.Net.Sockets;
using System.Globalization;
using System.Xml.Linq;
using DeviceMonitor.Core;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.Tests;

public sealed class SettingsAndServerTests
{
    [Fact] public void PeerAddressUsesFrozenDefaultPortAndPath()
    {
        Assert.True(PeerEndpoint.TryParse("peer-device", out var endpoint));
        Assert.Equal(48621, endpoint.Port); Assert.Equal("/v1/status", endpoint.AbsolutePath);
        Assert.False(PeerEndpoint.TryParse("https://public.example/status", out _));
    }

    [Theory] [InlineData("10.0.0.1", true)] [InlineData("172.31.1.2", true)] [InlineData("192.168.1.2", true)]
    [InlineData("100.64.0.1", true)] [InlineData("8.8.8.8", false)] [InlineData("127.0.0.1", false)]
    public void OnlyPrivateOrOverlayIPv4CanBeSelected(string text, bool expected) => Assert.Equal(expected, NetworkBinding.IsPrivateIPv4(IPAddress.Parse(text)));

    [Fact] public void PairingSecretRoundTripsThroughDpapiAndIsNotPlaintext()
    {
        var directory = Path.Combine(Path.GetTempPath(), "device-monitor-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new ProtectedSecretStore(directory); var first = store.LoadOrCreate(); var second = store.LoadOrCreate();
            Assert.Equal(32, first.Length); Assert.Equal(first, second);
            var persisted = File.ReadAllBytes(Path.Combine(directory, "pairing-secret.dat")); Assert.NotEqual(first, persisted);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact] public void SettingsPersistLanguageAndNeverContainASecretField()
    {
        var directory = Path.Combine(Path.GetTempPath(), "device-monitor-settings-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new SettingsStore(directory); var settings = new AppSettings { Language = AppLanguage.SimplifiedChinese };
            store.Save(settings); Assert.Equal(AppLanguage.SimplifiedChinese, store.LoadOrCreate().Language);
            Assert.DoesNotContain("secret", File.ReadAllText(store.SettingsPath), StringComparison.OrdinalIgnoreCase);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Fact] public void EnglishAndSimplifiedChineseResourcesHaveIdenticalKeys()
    {
        static string[] Keys(string file)
        {
            XNamespace x = "http://schemas.microsoft.com/winfx/2006/xaml";
            return XDocument.Load(Path.Combine(AppContext.BaseDirectory, file)).Root!.Elements()
                .Select(element => (string?)element.Attribute(x + "Key")).Where(key => key is not null).OrderBy(key => key).ToArray()!;
        }
        Assert.Equal(Keys("Strings.en-US.xaml"), Keys("Strings.zh-CN.xaml"));
    }

    [Fact] public async Task RealServerAndClientExchangeSignedFixture()
    {
        var secret = PeerAuthentication.GenerateSecret(); var fixture = PeerStatusCodec.Decode(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json")));
        var port = FindFreePort();
        await using var server = new PeerStatusServer(() => fixture, secret, IPAddress.Loopback, port);
        await server.StartAsync();
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        var received = await new PeerStatusClient(http).GetStatusAsync(new Uri($"http://127.0.0.1:{port}/v1/status"), Guid.NewGuid().ToString("D"), secret);
        Assert.Equal(fixture, received);
    }

    [Fact] public async Task RealServerReturnsConflictForReplayedNonceAndNoStoreHeaders()
    {
        var secret = PeerAuthentication.GenerateSecret(); var fixture = PeerStatusCodec.Decode(File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json")));
        var port = FindFreePort(); await using var server = new PeerStatusServer(() => fixture, secret, IPAddress.Loopback, port); await server.StartAsync();
        using var http = new HttpClient(); var endpoint = new Uri($"http://127.0.0.1:{port}/v1/status");
        const string nonce = "AAECAwQFBgcICQoLDA0ODw"; var timestamp = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(); var deviceId = Guid.NewGuid().ToString("D");
        using var first = CreateSignedRequest(endpoint, deviceId, timestamp, nonce, secret); using var firstResponse = await http.SendAsync(first);
        Assert.Equal(HttpStatusCode.OK, firstResponse.StatusCode); Assert.True(firstResponse.Headers.CacheControl?.NoStore);
        using var second = CreateSignedRequest(endpoint, deviceId, timestamp, nonce, secret); using var secondResponse = await http.SendAsync(second);
        Assert.Equal(HttpStatusCode.Conflict, secondResponse.StatusCode); Assert.True(secondResponse.Headers.CacheControl?.NoStore);
    }

    private static HttpRequestMessage CreateSignedRequest(Uri endpoint, string deviceId, long timestamp, string nonce, byte[] secret)
    {
        var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.DeviceId, deviceId);
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.Timestamp, timestamp.ToString(CultureInfo.InvariantCulture));
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.Nonce, nonce);
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.ApiVersion, "1");
        request.Headers.TryAddWithoutValidation(AuthenticationHeaders.Signature, PeerAuthentication.CreateRequestSignature(secret, timestamp, nonce));
        return request;
    }

    private static int FindFreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
        try { return ((IPEndPoint)listener.LocalEndpoint).Port; } finally { listener.Stop(); }
    }
}
