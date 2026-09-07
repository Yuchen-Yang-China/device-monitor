using System.Windows;
using System.Diagnostics;

namespace DeviceMonitor.App;

public partial class App : System.Windows.Application
{
    private AppRuntime? _runtime; private MainWindow? _window; private TrayController? _tray; private StatusFlyoutWindow? _flyout; private bool _shuttingDown;
    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e); _runtime = new AppRuntime(); Localization.Apply(_runtime.Settings.Language); _runtime.StartMonitoring();
        _window = new MainWindow(_runtime); MainWindow = _window;
        _flyout = new StatusFlyoutWindow(_runtime);
        _tray = new TrayController(_runtime, ToggleFlyout, ShowOrHideWindow, ShutdownApplicationAsync);
        if (e.Args.Contains("--show", StringComparer.OrdinalIgnoreCase)) _window.ShowNearTaskbar();
        if (e.Args.Contains("--show-flyout", StringComparer.OrdinalIgnoreCase)) _flyout.ShowNear(System.Windows.Forms.Cursor.Position);
        try { await _runtime.ApplyPeerSettingsAsync(); } catch (Exception exception) { _runtime.PeerConfigurationError = exception.Message; }
    }
    private void ShowOrHideWindow()
    {
        if (_window is null) return;
        _window.ToggleNearTaskbar();
    }
    private void ToggleFlyout(System.Drawing.Point anchorPoint)
    {
        _flyout?.ToggleNear(anchorPoint);
    }
    private async void ShutdownApplicationAsync()
    {
        if (_shuttingDown) return; _shuttingDown = true; _flyout?.Dispose(); _tray?.Dispose();
        if (_runtime is not null) await _runtime.DisposeAsync(); Shutdown();
    }

    public void RestartElevated()
    {
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException(Localization.Text("ElevationFailed"));
        Process.Start(new ProcessStartInfo(executable) { UseShellExecute = true, Verb = "runas" });
        ShutdownApplicationAsync();
    }
}
