using DeviceMonitor.Protocol;

namespace DeviceMonitor.Core;

public sealed class LocalMonitorStore
{
    private readonly object _gate = new();
    private readonly List<TrendPoint> _memoryTrend = [];
    private LocalSnapshot _snapshot;

    public LocalMonitorStore(DateTimeOffset startedAt)
    {
        _snapshot = new(0, startedAt,
            new(HealthState.Collecting, null, null, null, null, null, Environment.ProcessorCount),
            new(HealthState.Collecting, null, null, null, null), ThermalSampler.Unavailable,
            new(HealthState.Collecting, null, null, null, 0, 0), []);
    }

    public event Action<LocalSnapshot>? Changed;
    public LocalSnapshot Snapshot { get { lock (_gate) return _snapshot; } }
    public IReadOnlyList<TrendPoint> MemoryTrend { get { lock (_gate) return _memoryTrend.ToArray(); } }

    public void Update(DateTimeOffset now, CpuReading? cpu = null, MemoryReading? memory = null, ThermalReading? thermal = null,
        NetworkReading? network = null, IReadOnlyList<ProcessReading>? processes = null)
    {
        LocalSnapshot next;
        lock (_gate)
        {
            next = _snapshot with { Sequence = _snapshot.Sequence + 1, CapturedAt = now,
                Cpu = cpu ?? _snapshot.Cpu, Memory = memory ?? _snapshot.Memory, Thermal = thermal ?? _snapshot.Thermal,
                Network = network ?? _snapshot.Network, TopProcesses = processes ?? _snapshot.TopProcesses };
            _snapshot = next;
            if (memory is { SampledAt: { } sampledAt, UsedPct: { } usedPct } && memory.State is not HealthState.Stale)
            {
                _memoryTrend.Add(new(sampledAt, usedPct));
                TrimTrend(_memoryTrend, now);
            }
        }
        Changed?.Invoke(next);
    }

    public static void TrimTrend(List<TrendPoint> points, DateTimeOffset now)
    {
        var cutoff = now - TimeSpan.FromMinutes(5);
        points.RemoveAll(point => point.SampledAt < cutoff);
    }
}

public sealed class MonitoringService : IAsyncDisposable
{
    private readonly CpuSampler _cpu = new(); private readonly MemorySampler _memory = new();
    private readonly NetworkSampler _network = new(); private readonly ProcessSampler _processes = new(); private readonly ThermalSampler _thermal = new();
    private readonly CancellationTokenSource _cancellation = new(); private Task? _loop;
    private volatile SamplingMode _mode = SamplingMode.Balanced; private volatile bool _processDetailActive;
    public MonitoringService(LocalMonitorStore store) => Store = store;
    public LocalMonitorStore Store { get; }
    public SamplingMode Mode { get => _mode; set => _mode = value; }
    public bool ProcessDetailActive { get => _processDetailActive; set => _processDetailActive = value; }

    public void Start() => _loop ??= Task.Run(() => RunAsync(_cancellation.Token));

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var nextSystem = DateTimeOffset.MinValue; var nextNetwork = DateTimeOffset.MinValue;
        var nextThermal = DateTimeOffset.MinValue; var nextDetail = DateTimeOffset.MinValue;
        while (!cancellationToken.IsCancellationRequested)
        {
            var now = DateTimeOffset.UtcNow; var schedule = SamplingSchedule.For(_mode);
            if (now >= nextSystem) { Store.Update(now, cpu: _cpu.Sample(now), memory: _memory.Sample(now)); nextSystem = now + schedule.SystemInterval; }
            if (now >= nextNetwork) { Store.Update(now, network: _network.Sample(now)); nextNetwork = now + schedule.NetworkInterval; }
            if (now >= nextThermal) { Store.Update(now, thermal: _thermal.Sample(now)); nextThermal = now + schedule.ThermalInterval; }
            if (_processDetailActive && now >= nextDetail) { Store.Update(now, processes: _processes.Sample()); nextDetail = now + schedule.DetailInterval; }
            if (!_processDetailActive) nextDetail = now;
            await Task.Delay(200, cancellationToken).ConfigureAwait(false);
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation.Cancel();
        if (_loop is not null) try { await _loop.ConfigureAwait(false); } catch (OperationCanceledException) { }
        _thermal.Dispose(); _cancellation.Dispose();
    }
}

public sealed record DeviceIdentity(string Id, string Name, string OsVersion, string AppVersion, DateTimeOffset StartedAt);

public static class ProtocolMapper
{
    public static PeerStatusDocument ToProtocol(LocalSnapshot source, DeviceIdentity device) => new()
    {
        ApiVersion = ProtocolConstants.ApiVersion, Sequence = source.Sequence, CapturedAt = PeerStatusCodec.FormatTimestamp(source.CapturedAt),
        Device = new() { Id = device.Id, Name = device.Name, Platform = "windows", OsVersion = device.OsVersion,
            AppVersion = device.AppVersion, StartedAt = PeerStatusCodec.FormatTimestamp(device.StartedAt) },
        Capabilities = new() { CpuBreakdown = true, LoadAverage = false, HybridCoreTopology = false, MemoryBreakdown = false,
            Swap = false, TemperatureSensors = source.Thermal.AverageCelsius is not null || source.Thermal.HottestCelsius is not null || source.Thermal.StorageCelsius is not null,
            OsThermalState = false, WifiSignal = false, GpuTemperature = source.Thermal.GpuCelsius is not null,
            StorageTemperature = source.Thermal.StorageCelsius is not null },
        Metrics = new()
        {
            Cpu = new() { State = State(source.Cpu.State), SampledAt = Timestamp(source.Cpu.SampledAt), UtilizationPct = source.Cpu.UtilizationPct,
                UserPct = source.Cpu.UserPct, SystemPct = source.Cpu.SystemPct, IdlePct = source.Cpu.IdlePct,
                LoadAverage1 = null, LoadAverage5 = null, LoadAverage15 = null, PerformanceCores = source.Cpu.LogicalProcessors,
                EfficiencyCores = 0, HybridTopology = false },
            Memory = new() { State = State(source.Memory.State), SampledAt = Timestamp(source.Memory.SampledAt), UsedBytes = source.Memory.UsedBytes,
                TotalBytes = source.Memory.TotalBytes, UsedPct = source.Memory.UsedPct, WiredBytes = null, CompressedBytes = null,
                CachedBytes = source.Memory.CachedBytes, SwapUsedBytes = source.Memory.SwapUsedBytes, SwapTotalBytes = source.Memory.SwapTotalBytes },
            Thermal = new() { State = ProtocolThermalState(source.Thermal), SampledAt = ProtocolThermalTimestamp(source.Thermal), OsState = source.Thermal.OsState,
                AverageCelsius = source.Thermal.AverageCelsius, HottestCelsius = source.Thermal.HottestCelsius,
                StorageCelsius = source.Thermal.StorageCelsius, GpuCelsius = source.Thermal.GpuCelsius },
            Network = new() { State = State(source.Network.State), SampledAt = Timestamp(source.Network.SampledAt),
                UploadBytesPerSecond = source.Network.UploadBytesPerSecond, DownloadBytesPerSecond = source.Network.DownloadBytesPerSecond,
                SessionUploadBytes = source.Network.SessionUploadBytes, SessionDownloadBytes = source.Network.SessionDownloadBytes }
        }
    };

    private static string? Timestamp(DateTimeOffset? value) => value is null ? null : PeerStatusCodec.FormatTimestamp(value.Value);
    private static bool HasProtocolThermalValue(ThermalReading value) => value.AverageCelsius is not null || value.HottestCelsius is not null || value.StorageCelsius is not null;
    private static string ProtocolThermalState(ThermalReading value) => HasProtocolThermalValue(value) ? State(value.State) : MetricStates.Unavailable;
    private static string? ProtocolThermalTimestamp(ThermalReading value) => HasProtocolThermalValue(value) ? Timestamp(value.SampledAt) : null;
    private static string State(HealthState value) => value switch
    {
        HealthState.Normal => MetricStates.Normal, HealthState.Elevated => MetricStates.Elevated, HealthState.Critical => MetricStates.Critical,
        HealthState.Collecting => MetricStates.Collecting, HealthState.Unavailable => MetricStates.Unavailable, _ => MetricStates.Stale
    };
}
