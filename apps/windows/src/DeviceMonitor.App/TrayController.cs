using System.Drawing;
using System.Runtime.InteropServices;
using DeviceMonitor.Core;
using Forms = System.Windows.Forms;

namespace DeviceMonitor.App;

public sealed class TrayController : IDisposable
{
    private readonly AppRuntime _runtime;
    private readonly Forms.NotifyIcon _notifyIcon;
    private readonly Forms.ToolStripItem _openItem;
    private readonly Forms.ToolStripItem _quitItem;
    private Icon? _icon;

    public TrayController(AppRuntime runtime, Action<Point> toggleFlyout, Action openDetails, Action quit)
    {
        _runtime = runtime;
        var menu = new Forms.ContextMenuStrip();
        _openItem = menu.Items.Add(Localization.Text("MenuOpen"), null, (_, _) => openDetails());
        _quitItem = menu.Items.Add(Localization.Text("MenuQuit"), null, (_, _) => quit());
        _icon = CreateIcon(_runtime.LocalStore.Snapshot);
        _notifyIcon = new Forms.NotifyIcon
        {
            Icon = _icon,
            ContextMenuStrip = menu,
            Text = $"{Localization.Text("AppTitle")} — {Localization.Text("StateCollecting")}",
            Visible = true
        };
        _notifyIcon.MouseClick += (_, eventArgs) =>
        {
            if (eventArgs.Button == Forms.MouseButtons.Left) toggleFlyout(Forms.Cursor.Position);
        };
        _runtime.LocalStore.Changed += OnSnapshot;
        Localization.Changed += OnLanguageChanged;
        OnSnapshot(_runtime.LocalStore.Snapshot);
    }

    private void OnLanguageChanged()
    {
        _openItem.Text = Localization.Text("MenuOpen");
        _quitItem.Text = Localization.Text("MenuQuit");
        OnSnapshot(_runtime.LocalStore.Snapshot);
    }

    private void OnSnapshot(LocalSnapshot value) => System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
    {
        var next = CreateIcon(value);
        var old = _icon;
        _icon = next;
        _notifyIcon.Icon = next;
        old?.Dispose();
        _notifyIcon.Text = TrimTooltip(
            $"{Localization.Text("AppTitle")} | CPU {StatusPresentation.Percent(value.Cpu.UtilizationPct)} | " +
            $"{Localization.Text("LabelMemory")} {StatusPresentation.Percent(value.Memory.UsedPct)} | " +
            $"↑{StatusPresentation.CompactRate(value.Network.UploadBytesPerSecond)} " +
            $"↓{StatusPresentation.CompactRate(value.Network.DownloadBytesPerSecond)}");
    });

    private static Icon CreateIcon(LocalSnapshot value)
    {
        using var bitmap = new Bitmap(32, 32);
        using var graphics = Graphics.FromImage(bitmap);
        graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        DrawBar(graphics, 2, value.Cpu.UtilizationPct, value.Cpu.State);
        DrawBar(graphics, 12, value.Memory.UsedPct, value.Memory.State);
        DrawBar(graphics, 22, value.Thermal.StorageCelsius, StatusPresentation.StorageState(value.Thermal));
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = Icon.FromHandle(handle);
            return (Icon)temporary.Clone();
        }
        finally { DestroyIcon(handle); }
    }

    private static void DrawBar(Graphics graphics, int x, double? value, HealthState state)
    {
        using var background = new SolidBrush(Color.FromArgb(75, 128, 128, 128));
        using var foreground = new SolidBrush(StatusColor(state));
        graphics.FillRoundedRectangle(background, new Rectangle(x, 3, 8, 26), 3);
        var height = value is null ? 5 : Math.Max(5, (int)Math.Round(24 * Math.Clamp(value.Value, 0, 100) / 100));
        graphics.FillRoundedRectangle(foreground, new Rectangle(x, 28 - height, 8, height), 3);
    }

    private static Color StatusColor(HealthState state) => state switch
    {
        HealthState.Normal => Color.FromArgb(22, 163, 74),
        HealthState.Elevated => Color.FromArgb(234, 88, 12),
        HealthState.Critical => Color.FromArgb(239, 68, 68),
        HealthState.Collecting => Color.FromArgb(59, 130, 246),
        _ => Color.FromArgb(148, 163, 184)
    };

    private static string TrimTooltip(string value) => value.Length <= 63 ? value : value[..63];

    public void Dispose()
    {
        _runtime.LocalStore.Changed -= OnSnapshot;
        Localization.Changed -= OnLanguageChanged;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _icon?.Dispose();
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr handle);
}

internal static class GraphicsExtensions
{
    public static void FillRoundedRectangle(this Graphics graphics, Brush brush, Rectangle bounds, int radius)
    {
        using var path = new System.Drawing.Drawing2D.GraphicsPath();
        var diameter = radius * 2;
        path.AddArc(bounds.X, bounds.Y, diameter, diameter, 180, 90);
        path.AddArc(bounds.Right - diameter, bounds.Y, diameter, diameter, 270, 90);
        path.AddArc(bounds.Right - diameter, bounds.Bottom - diameter, diameter, diameter, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - diameter, diameter, diameter, 90, 90);
        path.CloseFigure();
        graphics.FillPath(brush, path);
    }
}
