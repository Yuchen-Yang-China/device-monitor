using System.Windows;
using System.Windows.Media;
using DeviceMonitor.Core;
using Microsoft.Win32;
using Forms = System.Windows.Forms;

namespace DeviceMonitor.App;

public partial class TaskbarPillWindow : Window, IDisposable
{
    private readonly AppRuntime _runtime;
    private readonly System.Windows.Controls.MenuItem _openItem;
    private readonly System.Windows.Controls.MenuItem _quitItem;
    private bool _disposed;

    public event Action? ToggleRequested;
    public event Action? OpenRequested;
    public event Action? QuitRequested;

    public TaskbarPillWindow(AppRuntime runtime)
    {
        InitializeComponent();
        _runtime = runtime;
        var menu = new System.Windows.Controls.ContextMenu();
        _openItem = new System.Windows.Controls.MenuItem();
        _quitItem = new System.Windows.Controls.MenuItem();
        _openItem.Click += (_, _) => OpenRequested?.Invoke();
        _quitItem.Click += (_, _) => QuitRequested?.Invoke();
        menu.Items.Add(_openItem);
        menu.Items.Add(new System.Windows.Controls.Separator());
        menu.Items.Add(_quitItem);
        PillButton.ContextMenu = menu;

        Loaded += (_, _) => PositionAboveTaskbar();
        _runtime.LocalStore.Changed += OnSnapshot;
        Localization.Changed += OnLanguageChanged;
        SystemEvents.DisplaySettingsChanged += DisplaySettingsChanged;
        OnLanguageChanged();
        OnSnapshot(_runtime.LocalStore.Snapshot);
    }

    public void ShowNearTaskbar()
    {
        if (!IsVisible) Show();
        PositionAboveTaskbar();
    }

    private void PillButton_Click(object sender, RoutedEventArgs e) => ToggleRequested?.Invoke();

    private void OnLanguageChanged()
    {
        Dispatcher.BeginInvoke(() =>
        {
            _openItem.Header = Localization.Text("MenuOpen");
            _quitItem.Header = Localization.Text("MenuQuit");
            PillButton.ToolTip = Localization.Text("TaskbarPillTooltip");
        });
    }

    private void OnSnapshot(LocalSnapshot value) => Dispatcher.BeginInvoke(() =>
    {
        UpdateBar(CpuBar, value.Cpu.UtilizationPct, value.Cpu.State);
        UpdateBar(MemoryBar, value.Memory.UsedPct, value.Memory.State);
        var storageState = StatusPresentation.StorageState(value.Thermal);
        UpdateBar(StorageBar, value.Thermal.StorageCelsius, storageState);
        UploadText.Text = $"↑ {StatusPresentation.CompactRate(value.Network.UploadBytesPerSecond)}";
        DownloadText.Text = $"↓ {StatusPresentation.CompactRate(value.Network.DownloadBytesPerSecond)}";
    });

    private void DisplaySettingsChanged(object? sender, EventArgs e) => Dispatcher.BeginInvoke(PositionAboveTaskbar);

    private void PositionAboveTaskbar()
    {
        var screen = Forms.Screen.PrimaryScreen;
        if (screen is null) return;
        var dpi = VisualTreeHelper.GetDpi(this);
        var work = screen.WorkingArea;
        var widthPixels = Width * dpi.DpiScaleX;
        var heightPixels = Height * dpi.DpiScaleY;

        // Keep the pill immediately above the Wi-Fi/volume area. Windows does not
        // reserve variable-width notification-area slots, so the pill must stay
        // in the desktop work area instead of covering the taskbar itself.
        var leftPixels = work.Right - widthPixels - 156 * dpi.DpiScaleX;
        var topPixels = work.Bottom - heightPixels - 8 * dpi.DpiScaleY;

        Left = Math.Max(work.Left, leftPixels) / dpi.DpiScaleX;
        Top = Math.Max(work.Top, topPixels) / dpi.DpiScaleY;
    }

    private static void UpdateBar(System.Windows.Shapes.Rectangle bar, double? value, HealthState state)
    {
        bar.Height = value is null ? 5 : Math.Max(5, Math.Round(23 * Math.Clamp(value.Value, 0, 100) / 100));
        bar.Fill = StatusPresentation.Brush(state);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _runtime.LocalStore.Changed -= OnSnapshot;
        Localization.Changed -= OnLanguageChanged;
        SystemEvents.DisplaySettingsChanged -= DisplaySettingsChanged;
        Close();
    }
}
