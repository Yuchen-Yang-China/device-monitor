using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using DeviceMonitor.Core;
using Forms = System.Windows.Forms;

namespace DeviceMonitor.App;

public partial class StatusFlyoutWindow : Window, IDisposable
{
    private readonly AppRuntime _runtime;
    private readonly TranslateTransform _slide = new();
    private CancellationTokenSource? _deactivateHide;
    private bool _hiding;
    private bool _disposed;

    public StatusFlyoutWindow(AppRuntime runtime)
    {
        InitializeComponent();
        _runtime = runtime;
        RenderTransform = _slide;
        RenderTransformOrigin = new System.Windows.Point(1, 1);
        _runtime.LocalStore.Changed += OnSnapshot;
        Localization.Changed += OnLanguageChanged;
        OnLanguageChanged();
        OnSnapshot(_runtime.LocalStore.Snapshot);
    }

    public void ToggleNear(System.Drawing.Point anchorPoint)
    {
        CancelDeactivateHide();
        if (IsVisible && !_hiding) HideAnimated();
        else ShowNear(anchorPoint);
    }

    public void ShowNear(System.Drawing.Point anchorPoint)
    {
        CancelDeactivateHide();
        _hiding = false;
        PositionNear(anchorPoint);
        _slide.BeginAnimation(TranslateTransform.YProperty, null);
        BeginAnimation(OpacityProperty, null);
        _slide.Y = 28;
        Opacity = 0;
        if (!IsVisible) Show();
        Activate();

        var motion = new DoubleAnimation(28, 0, TimeSpan.FromMilliseconds(380))
        {
            EasingFunction = new BackEase { Amplitude = 0.18, EasingMode = EasingMode.EaseOut }
        };
        var fade = new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(170))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseOut }
        };
        _slide.BeginAnimation(TranslateTransform.YProperty, motion);
        BeginAnimation(OpacityProperty, fade);
    }

    public void HideAnimated()
    {
        if (!IsVisible || _hiding) return;
        _hiding = true;
        var motion = new DoubleAnimation(0, 18, TimeSpan.FromMilliseconds(150))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseIn }
        };
        var fade = new DoubleAnimation(Opacity, 0, TimeSpan.FromMilliseconds(130));
        fade.Completed += (_, _) =>
        {
            Hide();
            _hiding = false;
            _slide.BeginAnimation(TranslateTransform.YProperty, null);
            BeginAnimation(OpacityProperty, null);
            _slide.Y = 0;
            Opacity = 1;
        };
        _slide.BeginAnimation(TranslateTransform.YProperty, motion);
        BeginAnimation(OpacityProperty, fade);
    }

    private void PositionNear(System.Drawing.Point anchorPoint)
    {
        var screen = Forms.Screen.FromPoint(anchorPoint);
        var dpi = VisualTreeHelper.GetDpi(this);
        var workArea = new Rect(
            screen.WorkingArea.Left / dpi.DpiScaleX,
            screen.WorkingArea.Top / dpi.DpiScaleY,
            screen.WorkingArea.Width / dpi.DpiScaleX,
            screen.WorkingArea.Height / dpi.DpiScaleY);
        var anchorX = anchorPoint.X / dpi.DpiScaleX;
        var anchorY = anchorPoint.Y / dpi.DpiScaleY;
        Left = Math.Clamp(anchorX - Width / 2, workArea.Left + 4, workArea.Right - Width - 4);
        var above = anchorY - Height - 8;
        Top = above >= workArea.Top + 4 ? above : Math.Min(anchorY + 8, workArea.Bottom - Height - 4);
    }

    private void OnLanguageChanged() => Dispatcher.BeginInvoke(() =>
    {
        SubtitleText.Text = Localization.Text("LocalDeviceStatus");
        LiveText.Text = Localization.Text("LiveStatus");
        UploadLabel.Text = $"↑ {Localization.Text("Upload")}";
        DownloadLabel.Text = $"↓ {Localization.Text("Download")}";
        MemoryLabel.Text = Localization.Text("LabelMemory");
        HintText.Text = Localization.Text("FlyoutDismissHint");
    });

    private void OnSnapshot(LocalSnapshot value) => Dispatcher.BeginInvoke(() =>
    {
        UploadValue.Text = StatusPresentation.Rate(value.Network.UploadBytesPerSecond);
        DownloadValue.Text = StatusPresentation.Rate(value.Network.DownloadBytesPerSecond);

        SetProgress(CpuScale, CpuIndicator, value.Cpu.UtilizationPct, value.Cpu.State);
        UpdateVerticalBar(FlyoutCpuBar, value.Cpu.UtilizationPct, value.Cpu.State);
        CpuValue.Text = StatusPresentation.CpuSummary(value);
        SetProgress(MemoryScale, MemoryIndicator, value.Memory.UsedPct, value.Memory.State);
        UpdateVerticalBar(FlyoutMemoryBar, value.Memory.UsedPct, value.Memory.State);
        MemoryValue.Text = StatusPresentation.Percent(value.Memory.UsedPct);
        var storageState = StatusPresentation.StorageState(value.Thermal);
        SetProgress(StorageScale, StorageIndicator, value.Thermal.StorageCelsius, storageState);
        UpdateVerticalBar(FlyoutStorageBar, value.Thermal.StorageCelsius, storageState);
        StorageValue.Text = StatusPresentation.Temperature(value.Thermal.StorageCelsius);
    });

    private static void SetProgress(ScaleTransform scale, System.Windows.Controls.Border indicator, double? value, HealthState state)
    {
        scale.ScaleX = value is null ? 0.04 : Math.Clamp(value.Value, 0, 100) / 100;
        indicator.Background = StatusPresentation.Brush(state);
    }

    private static void UpdateVerticalBar(System.Windows.Shapes.Rectangle bar, double? value, HealthState state)
    {
        bar.Height = value is null ? 4 : Math.Max(4, Math.Round(20 * Math.Clamp(value.Value, 0, 100) / 100));
        bar.Fill = StatusPresentation.Brush(state);
    }

    private async void Window_Deactivated(object? sender, EventArgs e)
    {
        CancelDeactivateHide();
        var pending = new CancellationTokenSource();
        _deactivateHide = pending;
        try
        {
            await Task.Delay(90, pending.Token);
            if (_deactivateHide == pending) HideAnimated();
        }
        catch (OperationCanceledException) { }
        finally
        {
            if (_deactivateHide == pending) _deactivateHide = null;
            pending.Dispose();
        }
    }

    private void CancelDeactivateHide()
    {
        _deactivateHide?.Cancel();
        _deactivateHide = null;
    }
    private void Window_PreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e) { if (e.Key == Key.Escape) { HideAnimated(); e.Handled = true; } }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        CancelDeactivateHide();
        _runtime.LocalStore.Changed -= OnSnapshot;
        Localization.Changed -= OnLanguageChanged;
        Close();
    }
}
