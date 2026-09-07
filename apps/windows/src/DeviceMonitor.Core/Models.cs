namespace DeviceMonitor.Core;

public enum HealthState { Normal, Elevated, Critical, Collecting, Unavailable, Stale }
public enum SamplingMode { Balanced, LowPower, Responsive }

public sealed record SamplingSchedule(
    TimeSpan NetworkInterval,
    TimeSpan SystemInterval,
    TimeSpan ThermalInterval,
    TimeSpan DetailInterval)
{
    public static SamplingSchedule For(SamplingMode mode) => mode switch
    {
        SamplingMode.LowPower => new(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30), TimeSpan.FromSeconds(60)),
        SamplingMode.Responsive => new(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(15)),
        _ => new(TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(30))
    };
}

public sealed record CpuReading(
    HealthState State, DateTimeOffset? SampledAt, double? UtilizationPct, double? UserPct,
    double? SystemPct, double? IdlePct, int LogicalProcessors);

public sealed record MemoryReading(
    HealthState State, DateTimeOffset? SampledAt, long? UsedBytes, long? TotalBytes, double? UsedPct,
    long? CachedBytes = null, long? SwapUsedBytes = null, long? SwapTotalBytes = null);

public sealed record ThermalReading(
    HealthState State, DateTimeOffset? SampledAt, double? AverageCelsius,
    double? HottestCelsius, double? StorageCelsius, string OsState, double? GpuCelsius = null);

public sealed record NetworkReading(
    HealthState State, DateTimeOffset? SampledAt, double? UploadBytesPerSecond,
    double? DownloadBytesPerSecond, long SessionUploadBytes, long SessionDownloadBytes);

public sealed record ProcessReading(int ProcessId, string Name, double? CpuPct, long WorkingSetBytes);
public sealed record TrendPoint(DateTimeOffset SampledAt, double Value);

public sealed record LocalSnapshot(
    long Sequence, DateTimeOffset CapturedAt, CpuReading Cpu, MemoryReading Memory,
    ThermalReading Thermal, NetworkReading Network, IReadOnlyList<ProcessReading> TopProcesses);
