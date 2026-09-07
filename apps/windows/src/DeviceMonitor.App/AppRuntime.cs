using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Reflection;
using System.Security.Cryptography;
using DeviceMonitor.Core;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.App;

public sealed class AppRuntime : IAsyncDisposable
{
    private readonly SettingsStore _settingsStore; private readonly ProtectedSecretStore _secretStore;
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(2) };
    private byte[] _secret; private PeerStatusServer? _server; private PeerPoller? _poller;
    public AppRuntime()
    {
        var directory = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DeviceMonitor");
        _settingsStore = new(directory); _secretStore = new(directory); Settings = _settingsStore.LoadOrCreate();
        _secret = _secretStore.LoadOrCreate(); StartedAt = DateTimeOffset.UtcNow;
        LocalStore = new(StartedAt); Monitor = new(LocalStore) { Mode = Settings.SamplingMode };
        NetworkChange.NetworkAvailabilityChanged += NetworkChanged;
        NetworkChange.NetworkAddressChanged += NetworkAddressChanged;
        Microsoft.Win32.SystemEvents.PowerModeChanged += PowerModeChanged;
    }
    public DateTimeOffset StartedAt { get; }
    public AppSettings Settings { get; private set; }
    public LocalMonitorStore LocalStore { get; }
    public MonitoringService Monitor { get; }
    public RemoteSnapshotStore RemoteStore { get; } = new();
    public PeerPoller? Poller => _poller;
    public string? PeerConfigurationError { get; set; }
    public string? ListeningAddress => _server?.ListeningAddress;
    public event Action? PeerChanged;
    public void StartMonitoring() => Monitor.Start();
    public string PairingSecretText => PeerAuthentication.Base64UrlEncode(_secret);

    public async Task SaveSettingsAsync(AppSettings settings, string? replacementSecret)
    {
        byte[]? nextSecret = null;
        if (!string.IsNullOrWhiteSpace(replacementSecret))
        {
            nextSecret = PeerAuthentication.Base64UrlDecode(replacementSecret.Trim());
            if (nextSecret.Length != 32) { CryptographicOperations.ZeroMemory(nextSecret); throw new ArgumentException("ErrorSecretLength"); }
            _secretStore.Save(nextSecret);
        }
        Settings = settings; _settingsStore.Save(settings); Monitor.Mode = settings.SamplingMode;
        if (nextSecret is not null) { CryptographicOperations.ZeroMemory(_secret); _secret = nextSecret; }
        await ApplyPeerSettingsAsync();
    }

    public async Task ApplyPeerSettingsAsync()
    {
        if (_poller is not null) { _poller.Changed -= OnPeerChanged; await _poller.DisposeAsync(); _poller = null; }
        if (_server is not null) { await _server.DisposeAsync(); _server = null; }
        PeerConfigurationError = null;
        if (!Settings.PeerEnabled) { PeerChanged?.Invoke(); return; }
        if (!IPAddress.TryParse(Settings.ListenAddress, out var listen) || !NetworkBinding.IsPrivateIPv4(listen) || !NetworkBinding.PrivateIPv4Addresses().Contains(listen))
            throw new InvalidOperationException("ErrorSelectPrivate");
        if (!PeerEndpoint.TryParse(Settings.PeerAddress, out var endpoint))
            throw new InvalidOperationException("ErrorPeerAddress");
        var identity = new DeviceIdentity(Settings.DeviceId, Settings.DeviceName, Environment.OSVersion.VersionString,
            Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0.1.0", StartedAt);
        _server = new(() => ProtocolMapper.ToProtocol(LocalStore.Snapshot, identity), _secret, listen);
        await _server.StartAsync();
        _poller = new(new PeerStatusClient(_httpClient), endpoint, Settings.DeviceId, _secret, RemoteStore);
        _poller.Changed += OnPeerChanged; _poller.Start(); PeerChanged?.Invoke();
    }
    private void OnPeerChanged() => PeerChanged?.Invoke();
    private void NetworkChanged(object? sender, NetworkAvailabilityEventArgs e) => _poller?.RequestImmediatePoll();
    private void NetworkAddressChanged(object? sender, EventArgs e) => _poller?.RequestImmediatePoll();
    private void PowerModeChanged(object sender, Microsoft.Win32.PowerModeChangedEventArgs e)
    { if (e.Mode == Microsoft.Win32.PowerModes.Resume) _poller?.RequestImmediatePoll(); }
    public byte[] GenerateAndSaveSecret()
    {
        var replacement = PeerAuthentication.GenerateSecret(); _secretStore.Save(replacement);
        CryptographicOperations.ZeroMemory(_secret); _secret = replacement; return replacement.ToArray();
    }
    public async ValueTask DisposeAsync()
    {
        NetworkChange.NetworkAvailabilityChanged -= NetworkChanged; NetworkChange.NetworkAddressChanged -= NetworkAddressChanged;
        Microsoft.Win32.SystemEvents.PowerModeChanged -= PowerModeChanged;
        if (_poller is not null) await _poller.DisposeAsync(); if (_server is not null) await _server.DisposeAsync();
        await Monitor.DisposeAsync(); _httpClient.Dispose(); CryptographicOperations.ZeroMemory(_secret);
    }
}
