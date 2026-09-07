using System.ComponentModel;
using System.Net;
using System.Security.Principal;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using DeviceMonitor.Core;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.App;

public partial class MainWindow : Window
{
    private readonly AppRuntime _runtime; private readonly DispatcherTimer _timer;
    private sealed record Choice<T>(T Value, string Name);
    public MainWindow(AppRuntime runtime)
    {
        InitializeComponent(); _runtime = runtime;
        LoadLocalizedChoices(runtime.Settings.SamplingMode, runtime.Settings.Language);
        DeviceNameBox.Text = runtime.Settings.DeviceName; PeerEnabledCheck.IsChecked = runtime.Settings.PeerEnabled;
        var addresses = NetworkBinding.PrivateIPv4Addresses().Select(a => a.ToString()).ToList();
        if (runtime.Settings.ListenAddress is { } saved && !addresses.Contains(saved)) addresses.Add(saved);
        ListenAddressBox.ItemsSource = addresses; ListenAddressBox.SelectedItem = runtime.Settings.ListenAddress;
        PeerAddressBox.Text = runtime.Settings.PeerAddress ?? string.Empty;
        _timer = new(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (_, _) => Refresh(), Dispatcher);
        runtime.PeerChanged += PeerChanged; Refresh();
    }

    private void LoadLocalizedChoices(SamplingMode samplingMode, AppLanguage language)
    {
        var sampling = new[] { new Choice<SamplingMode>(SamplingMode.Balanced, Localization.Text("SamplingBalanced")),
            new Choice<SamplingMode>(SamplingMode.LowPower, Localization.Text("SamplingLowPower")),
            new Choice<SamplingMode>(SamplingMode.Responsive, Localization.Text("SamplingResponsive")) };
        SamplingModeBox.ItemsSource = sampling; SamplingModeBox.SelectedItem = sampling.Single(item => item.Value == samplingMode);
        var languages = new[] { new Choice<AppLanguage>(AppLanguage.SimplifiedChinese, Localization.Text("LanguageChinese")),
            new Choice<AppLanguage>(AppLanguage.English, Localization.Text("LanguageEnglish")) };
        LanguageBox.ItemsSource = languages; LanguageBox.SelectedItem = languages.Single(item => item.Value == language);
    }

    private void PeerChanged() => Dispatcher.BeginInvoke(Refresh);
    private void Refresh()
    {
        var value = _runtime.LocalStore.Snapshot;
        HeaderNetworkText.Text = $"↑ {Rate(value.Network.UploadBytesPerSecond)}  ↓ {Rate(value.Network.DownloadBytesPerSecond)}";
        OverviewCpuValue.Text = Percent(value.Cpu.UtilizationPct); OverviewCpuState.Text = State(value.Cpu.State);
        OverviewMemoryValue.Text = Percent(value.Memory.UsedPct); OverviewMemoryState.Text = State(value.Memory.State);
        OverviewThermalValue.Text = value.Thermal.AverageCelsius is { } cpuTemperature ? $"{cpuTemperature:0.0} °C" :
            value.Thermal.GpuCelsius is { } gpuTemperature ? $"GPU {gpuTemperature:0.0} °C" :
            value.Thermal.StorageCelsius is { } storageTemperature ? $"{storageTemperature:0.0} °C" : Localization.Text("StateUnavailable");
        OverviewThermalState.Text = value.Thermal.State == HealthState.Unavailable && value.Thermal.GpuCelsius is not null ? Localization.Text("GpuOnlyStatus") : State(value.Thermal.State);
        OverviewNetworkValue.Text = $"↑ {Rate(value.Network.UploadBytesPerSecond)}\n↓ {Rate(value.Network.DownloadBytesPerSecond)}";
        OverviewNetworkState.Text = State(value.Network.State);
        CpuValue.Text = Percent(value.Cpu.UtilizationPct); CpuState.Text = State(value.Cpu.State);
        CpuBreakdown.Text = $"{Localization.Text("User"),-8}{Percent(value.Cpu.UserPct),7}\n{Localization.Text("System"),-8}{Percent(value.Cpu.SystemPct),7}\n{Localization.Text("Idle"),-8}{Percent(value.Cpu.IdlePct),7}";
        CpuTopology.Text = string.Format(Localization.Text("CpuTopologyFormat"), value.Cpu.LogicalProcessors);
        CpuProcesses.ItemsSource = value.TopProcesses.OrderByDescending(p => p.CpuPct ?? -1).Take(3)
            .Select(p => $"{Trim(p.Name, 20),-20} {(p.CpuPct is { } cpu ? $"{cpu,5:0.0}%" : Localization.Text("StateCollecting")),10}").ToArray();
        MemoryProcesses.ItemsSource = value.TopProcesses.OrderByDescending(p => p.WorkingSetBytes).Take(3)
            .Select(p => $"{Trim(p.Name, 20),-20} {Bytes(p.WorkingSetBytes),10}").ToArray();
        MemoryValue.Text = value.Memory.UsedBytes is { } used && value.Memory.TotalBytes is { } total ? $"{Bytes(used)} / {Bytes(total)}" : Localization.Text("StateCollecting");
        MemoryState.Text = $"{State(value.Memory.State)} · {Percent(value.Memory.UsedPct)}";
        var trend = _runtime.LocalStore.MemoryTrend; LocalMemoryTrend.Points = trend; LocalMemoryTrend.InvalidateVisual();
        MemoryStats.Text = trend.Count == 0 ? Localization.Text("StateCollecting") : string.Format(Localization.Text("AveragePeakFormat"), trend.Average(p => p.Value), trend.Max(p => p.Value));
        ThermalValue.Text = value.Thermal.AverageCelsius is { } cpuTemp ? $"{cpuTemp:0.0} °C" :
            value.Thermal.GpuCelsius is { } gpuTemp ? $"GPU {gpuTemp:0.0} °C" :
            value.Thermal.StorageCelsius is { } storageTemp ? $"{storageTemp:0.0} °C" : Localization.Text("StateUnavailable");
        ThermalState.Text = value.Thermal.State == HealthState.Unavailable && value.Thermal.GpuCelsius is not null ? Localization.Text("GpuOnlyStatus") : State(value.Thermal.State);
        var needsElevation = value.Thermal.AverageCelsius is null && value.Thermal.HottestCelsius is null && !IsAdministrator();
        RestartElevatedButton.Visibility = needsElevation ? Visibility.Visible : Visibility.Collapsed;
        var sensorLines = $"{Localization.Text("CpuAverage"),-12}{Temperature(value.Thermal.AverageCelsius)}\n{Localization.Text("CpuHottest"),-12}{Temperature(value.Thermal.HottestCelsius)}\n{Localization.Text("GpuTemperature"),-12}{Temperature(value.Thermal.GpuCelsius)}\n{Localization.Text("Storage"),-12}{Temperature(value.Thermal.StorageCelsius)}";
        var hasAnyTemperature = value.Thermal.AverageCelsius is not null || value.Thermal.HottestCelsius is not null || value.Thermal.GpuCelsius is not null || value.Thermal.StorageCelsius is not null;
        ThermalDetails.Text = hasAnyTemperature ? sensorLines + (needsElevation ? $"\n\n{Localization.Text("SensorsNeedAdmin")}" : string.Empty) : Localization.Text(needsElevation ? "SensorsNeedAdmin" : "NoSensors");
        NetworkState.Text = State(value.Network.State); NetworkRates.Text = $"↑ {Rate(value.Network.UploadBytesPerSecond)}\n↓ {Rate(value.Network.DownloadBytesPerSecond)}";
        NetworkSession.Text = $"{Localization.Text("Uploaded"),-12}{Bytes(value.Network.SessionUploadBytes)}\n{Localization.Text("Downloaded"),-12}{Bytes(value.Network.SessionDownloadBytes)}";
        RefreshPeer(); FooterStatus.Text = string.Format(Localization.Text("UpdatedFormat"), value.CapturedAt.ToLocalTime().ToString("T"), State(value.Cpu.State), State(value.Memory.State), State(value.Thermal.State));
    }

    private void RefreshPeer()
    {
        var peer = _runtime.RemoteStore.Snapshot; var poller = _runtime.Poller;
        if (!_runtime.Settings.PeerEnabled)
        {
            PeerAvailability.Text = Localization.Text("PeerOffline"); PeerIdentity.Text = Localization.Text("PeerDisabled"); PeerLastSeen.Text = string.Empty; PeerSummary.Text = Localization.Text("NoRemoteData"); return;
        }
        if (_runtime.PeerConfigurationError is { } configError)
        {
            PeerAvailability.Text = Localization.Text("PeerOffline"); PeerIdentity.Text = Localization.Error(configError); PeerLastSeen.Text = string.Empty; PeerSummary.Text = Localization.Text("NoRemoteData"); return;
        }
        var availability = poller?.Availability ?? Core.PeerAvailability.Offline;
        PeerAvailability.Text = availability switch { Core.PeerAvailability.Online => Localization.Text("PeerOnline"), Core.PeerAvailability.Degraded => Localization.Text("PeerDegraded"), _ => Localization.Text("PeerOffline") };
        if (poller?.LastError == PeerTransportError.ClockMismatch.ToString()) PeerAvailability.Text = Localization.Text("ClockMismatch");
        PeerIdentity.Text = peer is null ? Localization.Text("WaitingPeer") : $"{peer.Device.Name} · {peer.Device.Platform} · app {peer.Device.AppVersion}";
        PeerLastSeen.Text = _runtime.RemoteStore.LastReceivedAt is { } received ? string.Format(Localization.Text("LastReceivedFormat"), received.ToLocalTime().ToString("G")) : Localization.Text("NoValidResponse");
        PeerSummary.Text = peer is null ? Localization.Text("NoRemoteData") :
            $"CPU          {Percent(peer.Metrics.Cpu.UtilizationPct),8}  {UiState(peer.Metrics.Cpu.State)}\n" +
            $"{Localization.Text("LabelMemory"),-12}{Percent(peer.Metrics.Memory.UsedPct),8}  {UiState(peer.Metrics.Memory.State)}\n" +
            $"{Localization.Text("LabelTemperature"),-12}{Temperature(peer.Metrics.Thermal.AverageCelsius),8}  {UiState(peer.Metrics.Thermal.State)}\n" +
            $"{Localization.Text("LabelNetwork"),-12}↑{Rate(peer.Metrics.Network.UploadBytesPerSecond)} ↓{Rate(peer.Metrics.Network.DownloadBytesPerSecond)}";
        RemoteMemoryTrend.Points = _runtime.RemoteStore.MemoryTrend; RemoteMemoryTrend.InvalidateVisual();
    }

    private async void SaveSettings_Click(object sender, RoutedEventArgs e) => await SaveSettingsAsync(false);
    private async void TestConnection_Click(object sender, RoutedEventArgs e) => await SaveSettingsAsync(true);
    private async Task SaveSettingsAsync(bool test)
    {
        SettingsStatus.Text = Localization.Text(test ? "Testing" : "Saving");
        try
        {
            var settings = _runtime.Settings with { DeviceName = string.IsNullOrWhiteSpace(DeviceNameBox.Text) ? Environment.MachineName : DeviceNameBox.Text.Trim(),
                SamplingMode = SamplingModeBox.SelectedItem is Choice<SamplingMode> mode ? mode.Value : SamplingMode.Balanced,
                Language = LanguageBox.SelectedItem is Choice<AppLanguage> language ? language.Value : _runtime.Settings.Language,
                PeerEnabled = PeerEnabledCheck.IsChecked == true, ListenAddress = ListenAddressBox.SelectedItem as string,
                PeerAddress = string.IsNullOrWhiteSpace(PeerAddressBox.Text) ? null : PeerAddressBox.Text.Trim() };
            await _runtime.SaveSettingsAsync(settings, string.IsNullOrWhiteSpace(SecretBox.Password) ? null : SecretBox.Password);
            SecretBox.Clear(); Localization.Apply(settings.Language); LoadLocalizedChoices(settings.SamplingMode, settings.Language);
            if (test) { await Task.Delay(2300); Refresh(); SettingsStatus.Text = _runtime.Poller?.Availability is Core.PeerAvailability.Online or Core.PeerAvailability.Degraded ? Localization.Text("ConnectionSucceeded") : string.Format(Localization.Text("NoValidResponseFormat"), _runtime.Poller?.LastError ?? Localization.Text("WaitingPeer")); }
            else SettingsStatus.Text = _runtime.Settings.PeerEnabled ? string.Format(Localization.Text("SavedListeningFormat"), _runtime.ListeningAddress) : Localization.Text("SettingsSavedDisabled");
        }
        catch (Exception exception) { _runtime.PeerConfigurationError = exception.Message; SettingsStatus.Text = Localization.Error(exception.Message); Refresh(); }
    }
    private void GenerateSecret_Click(object sender, RoutedEventArgs e)
    {
        var secret = PeerAuthentication.GenerateSecret();
        try { SecretBox.Password = PeerAuthentication.Base64UrlEncode(secret); }
        finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(secret); }
        SettingsStatus.Text = Localization.Text("SecretGenerated");
    }
    private void CopySecret_Click(object sender, RoutedEventArgs e)
    {
        System.Windows.Clipboard.SetText(string.IsNullOrEmpty(SecretBox.Password) ? _runtime.PairingSecretText : SecretBox.Password); SettingsStatus.Text = Localization.Text("SecretCopied");
    }
    private void RestartElevated_Click(object sender, RoutedEventArgs e)
    {
        try { ((App)System.Windows.Application.Current).RestartElevated(); }
        catch (Exception exception) { SettingsStatus.Text = $"{Localization.Text("ElevationFailed")} {exception.Message}"; }
    }
    private void Tabs_SelectionChanged(object sender, SelectionChangedEventArgs e) { if (Tabs is not null) _runtime.Monitor.ProcessDetailActive = IsVisible && Tabs.SelectedIndex is 1 or 2; }
    private void OpenCpu_Click(object sender, RoutedEventArgs e) => Tabs.SelectedIndex = 1;
    private void OpenMemory_Click(object sender, RoutedEventArgs e) => Tabs.SelectedIndex = 2;
    private void OpenThermal_Click(object sender, RoutedEventArgs e) => Tabs.SelectedIndex = 3;
    private void OpenNetwork_Click(object sender, RoutedEventArgs e) => Tabs.SelectedIndex = 4;
    private void Window_Closing(object? sender, CancelEventArgs e) { e.Cancel = true; Hide(); }
    private void Window_IsVisibleChanged(object sender, DependencyPropertyChangedEventArgs e) => _runtime.Monitor.ProcessDetailActive = IsVisible && Tabs.SelectedIndex is 1 or 2;

    private static string Percent(double? value) => value is null ? "--" : $"{value:0.0}%";
    private static string Rate(double? value) => value switch { null => "--", < 1024 => $"{value:0} B/s", < 1048576 => $"{value / 1024:0.0} KB/s", _ => $"{value / 1048576:0.0} MB/s" };
    private static string Bytes(long value) => value switch { < 1024 => $"{value} B", < 1048576 => $"{value / 1024d:0.0} KB", < 1073741824 => $"{value / 1048576d:0.0} MB", _ => $"{value / 1073741824d:0.0} GB" };
    private static string Temperature(double? value) => value is null ? Localization.Text("StateUnavailable") : $"{value:0.0} °C";
    private static string State(HealthState value) => value switch { HealthState.Normal => Localization.Text("StateNormal"), HealthState.Elevated => Localization.Text("StateAttention"), HealthState.Critical => Localization.Text("StateCritical"), HealthState.Collecting => Localization.Text("StateCollecting"), HealthState.Unavailable => Localization.Text("StateUnavailable"), _ => Localization.Text("StateStale") };
    private static string UiState(string value) => value switch { MetricStates.Normal => Localization.Text("StateNormal"), MetricStates.Elevated => Localization.Text("StateAttention"), MetricStates.Critical => Localization.Text("StateCritical"), MetricStates.Collecting => Localization.Text("StateCollecting"), MetricStates.Unavailable => Localization.Text("StateUnavailable"), _ => Localization.Text("StateStale") };
    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent(); return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }
    private static string Trim(string value, int length) => value.Length <= length ? value : value[..(length - 1)] + "…";
}
