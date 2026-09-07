using System.Windows.Media;
using DeviceMonitor.Core;
using MediaColor = System.Windows.Media.Color;

namespace DeviceMonitor.App;

internal static class StatusPresentation
{
    public static string CompactRate(double? value) => value switch
    {
        null => "--",
        < 1024 => $"{value:0} B/s",
        < 1048576 => $"{value / 1024:0} KB/s",
        _ => $"{value / 1048576:0.0} MB/s"
    };

    public static string Rate(double? value) => value switch
    {
        null => "--",
        < 1024 => $"{value:0} B/s",
        < 1048576 => $"{value / 1024:0.0} KB/s",
        _ => $"{value / 1048576:0.0} MB/s"
    };

    public static string Percent(double? value) => value is null ? "--" : $"{value:0}%";
    public static string Temperature(double? value) => value is null ? "--" : $"{value:0.0} °C";

    public static string CpuSummary(LocalSnapshot value)
    {
        var utilization = Percent(value.Cpu.UtilizationPct);
        return value.Thermal.AverageCelsius is { } temperature ? $"{utilization} · {temperature:0}°" : utilization;
    }

    public static HealthState StorageState(ThermalReading thermal)
    {
        if (thermal.StorageCelsius is null)
            return thermal.State is HealthState.Collecting or HealthState.Stale ? thermal.State : HealthState.Unavailable;
        return thermal.StorageCelsius.Value switch
        {
            >= 85 => HealthState.Critical,
            >= 70 => HealthState.Elevated,
            _ => HealthState.Normal
        };
    }

    public static System.Windows.Media.Brush Brush(HealthState state) => state switch
    {
        HealthState.Normal => new SolidColorBrush(MediaColor.FromRgb(22, 163, 74)),
        HealthState.Elevated => new SolidColorBrush(MediaColor.FromRgb(234, 88, 12)),
        HealthState.Critical => new SolidColorBrush(MediaColor.FromRgb(239, 68, 68)),
        HealthState.Collecting => new SolidColorBrush(MediaColor.FromRgb(59, 130, 246)),
        _ => new SolidColorBrush(MediaColor.FromRgb(148, 163, 184))
    };
}
