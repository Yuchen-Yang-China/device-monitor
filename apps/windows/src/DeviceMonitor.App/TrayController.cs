using System.Drawing;
using System.Runtime.InteropServices;
using DeviceMonitor.Core;
using Forms = System.Windows.Forms;

namespace DeviceMonitor.App;

public sealed class TrayController : IDisposable
{
    private readonly AppRuntime _runtime; private readonly Forms.NotifyIcon _notifyIcon; private Icon? _icon;
    private readonly Forms.ToolStripItem _openItem; private readonly Forms.ToolStripItem _quitItem;
    public TrayController(AppRuntime runtime, Action toggleWindow, Action quit)
    {
        _runtime = runtime; var menu = new Forms.ContextMenuStrip();
        _openItem = menu.Items.Add(Localization.Text("MenuOpen"), null, (_, _) => toggleWindow());
        _quitItem = menu.Items.Add(Localization.Text("MenuQuit"), null, (_, _) => quit());
        _notifyIcon = new Forms.NotifyIcon { Visible = true, ContextMenuStrip = menu, Text = $"{Localization.Text("AppTitle")} — {Localization.Text("StateCollecting")}" };
        _notifyIcon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) toggleWindow(); };
        runtime.LocalStore.Changed += OnSnapshot; Localization.Changed += OnLanguageChanged; OnSnapshot(runtime.LocalStore.Snapshot);
    }
    private void OnLanguageChanged() { _openItem.Text = Localization.Text("MenuOpen"); _quitItem.Text = Localization.Text("MenuQuit"); OnSnapshot(_runtime.LocalStore.Snapshot); }
    private void OnSnapshot(LocalSnapshot value) => System.Windows.Application.Current.Dispatcher.BeginInvoke(() =>
    {
        var next = CreateIcon(value); var old = _icon; _icon = next; _notifyIcon.Icon = next; old?.Dispose();
        _notifyIcon.Text = TrimTooltip($"{Localization.Text("AppTitle")} | CPU {Format(value.Cpu.UtilizationPct)} | {Localization.Text("LabelMemory")} {Format(value.Memory.UsedPct)} | ↑{Rate(value.Network.UploadBytesPerSecond)} ↓{Rate(value.Network.DownloadBytesPerSecond)}");
    });
    private static Icon CreateIcon(LocalSnapshot value)
    {
        using var bitmap = new Bitmap(32, 32); using var graphics = Graphics.FromImage(bitmap); graphics.Clear(Color.Transparent);
        graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        DrawBar(graphics, 3, value.Cpu.UtilizationPct, value.Cpu.State); DrawBar(graphics, 12, value.Memory.UsedPct, value.Memory.State);
        DrawBar(graphics, 21, value.Thermal.AverageCelsius is { } t ? Math.Clamp(t, 0, 100) : null, value.Thermal.State);
        var handle = bitmap.GetHicon(); try { using var temporary = Icon.FromHandle(handle); return (Icon)temporary.Clone(); } finally { DestroyIcon(handle); }
    }
    private static void DrawBar(Graphics graphics, int x, double? value, HealthState state)
    {
        using var background = new SolidBrush(Color.FromArgb(85, 128, 128, 128)); using var foreground = new SolidBrush(StateColor(state));
        graphics.FillRoundedRectangle(background, new Rectangle(x, 3, 7, 26), 2);
        var height = value is null ? 4 : Math.Max(3, (int)Math.Round(24 * Math.Clamp(value.Value, 0, 100) / 100));
        graphics.FillRoundedRectangle(foreground, new Rectangle(x, 28 - height, 7, height), 2);
    }
    private static Color StateColor(HealthState value) => value switch { HealthState.Normal => Color.FromArgb(34, 197, 94), HealthState.Elevated => Color.FromArgb(245, 158, 11), HealthState.Critical => Color.FromArgb(239, 68, 68), _ => Color.FromArgb(148, 163, 184) };
    private static string Format(double? value) => value is null ? "--" : $"{value:0}%";
    private static string Rate(double? value) => value switch { null => "--", < 1024 => $"{value:0}B/s", < 1048576 => $"{value / 1024:0}K/s", _ => $"{value / 1048576:0.0}M/s" };
    private static string TrimTooltip(string value) => value.Length <= 63 ? value : value[..63];
    public void Dispose() { _runtime.LocalStore.Changed -= OnSnapshot; Localization.Changed -= OnLanguageChanged; _notifyIcon.Visible = false; _notifyIcon.Dispose(); _icon?.Dispose(); }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool DestroyIcon(IntPtr handle);
}

internal static class GraphicsExtensions
{
    public static void FillRoundedRectangle(this Graphics graphics, Brush brush, Rectangle bounds, int radius)
    {
        using var path = new System.Drawing.Drawing2D.GraphicsPath(); var d = radius * 2;
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90); path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90); path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90); path.CloseFigure(); graphics.FillPath(brush, path);
    }
}
