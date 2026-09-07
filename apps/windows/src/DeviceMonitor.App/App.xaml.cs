using System.Windows;
using System.Diagnostics;

namespace DeviceMonitor.App;

public partial class App : System.Windows.Application
{
    private AppRuntime? _runtime; private TrayController? _tray; private MainWindow? _window; private bool _shuttingDown;
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e); _runtime = new AppRuntime(); Localization.Apply(_runtime.Settings.Language); _runtime.StartMonitoring();
        _window = new MainWindow(_runtime); MainWindow = _window;
        _tray = new TrayController(_runtime, ShowOrHideWindow, ShutdownApplicationAsync);
        if (e.Args.Contains("--show", StringComparer.OrdinalIgnoreCase)) { _window.Show(); _window.Activate(); }
        try { await _runtime.ApplyPeerSettingsAsync(); } catch (Exception exception) { _runtime.PeerConfigurationError = exception.Message; }
    }
    private void ShowOrHideWindow()
    {
        if (_window is null) return;
        if (_window.IsVisible) _window.Hide(); else { _window.Show(); _window.Activate(); }
    }
    private async void ShutdownApplicationAsync()
    {
        if (_shuttingDown) return; _shuttingDown = true; _tray?.Dispose();
        if (_runtime is not null) await _runtime.DisposeAsync(); Shutdown();
    }

    public void RestartElevated()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException(Localization.Text("ElevationFailed"));
        Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true, Verb = "runas" });
        ShutdownApplicationAsync();
    }
}
