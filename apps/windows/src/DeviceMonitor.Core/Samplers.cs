using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using LibreHardwareMonitor.Hardware;

namespace DeviceMonitor.Core;

public readonly record struct CpuTimes(ulong Idle, ulong Kernel, ulong User);

public sealed class CpuSampler
{
    private CpuTimes? _baseline;
    private CpuReading? _lastSuccess;

    public CpuReading Sample(DateTimeOffset now)
    {
        if (!GetSystemTimes(out var idle, out var kernel, out var user))
            return _lastSuccess is { } previous ? previous with { State = HealthState.Stale } :
                new(HealthState.Collecting, null, null, null, null, null, Environment.ProcessorCount);

        var current = new CpuTimes(ToUInt64(idle), ToUInt64(kernel), ToUInt64(user));
        if (_baseline is not { } baseline)
        {
            _baseline = current;
            return new(HealthState.Collecting, null, null, null, null, null, Environment.ProcessorCount);
        }

        _baseline = current;
        var reading = Calculate(baseline, current, now, Environment.ProcessorCount);
        if (reading.State != HealthState.Collecting) _lastSuccess = reading;
        return reading;
    }

    public static CpuReading Calculate(CpuTimes previous, CpuTimes current, DateTimeOffset sampledAt, int logicalProcessors)
    {
        if (current.Idle < previous.Idle || current.Kernel < previous.Kernel || current.User < previous.User)
            return new(HealthState.Collecting, null, null, null, null, null, logicalProcessors);
        var idle = current.Idle - previous.Idle;
        var kernel = current.Kernel - previous.Kernel;
        var user = current.User - previous.User;
        var total = kernel + user;
        if (total == 0 || kernel < idle) return new(HealthState.Collecting, null, null, null, null, null, logicalProcessors);
        var idlePct = idle * 100d / total;
        var userPct = user * 100d / total;
        var systemPct = (kernel - idle) * 100d / total;
        var utilization = Math.Clamp(100d - idlePct, 0d, 100d);
        return new(EvaluateCpu(utilization), sampledAt, utilization, userPct, systemPct, idlePct, logicalProcessors);
    }

    public static HealthState EvaluateCpu(double percentage) => percentage >= 90 ? HealthState.Critical : percentage >= 65 ? HealthState.Elevated : HealthState.Normal;

    private static ulong ToUInt64(FileTime value) => ((ulong)value.High << 32) | value.Low;

    [StructLayout(LayoutKind.Sequential)] private struct FileTime { public uint Low; public uint High; }
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemTimes(out FileTime idleTime, out FileTime kernelTime, out FileTime userTime);
}

public sealed class MemorySampler
{
    private MemoryReading? _lastSuccess;
    public MemoryReading Sample(DateTimeOffset now)
    {
        var status = new MemoryStatusEx { Length = (uint)Marshal.SizeOf<MemoryStatusEx>() };
        if (!GlobalMemoryStatusEx(ref status))
            return _lastSuccess is { } previous ? previous with { State = HealthState.Stale } :
                new(HealthState.Stale, null, null, null, null);
        var total = checked((long)status.TotalPhysical);
        var available = checked((long)status.AvailablePhysical);
        var used = Math.Max(0, total - available);
        var percentage = total == 0 ? 0 : used * 100d / total;
        var result = new MemoryReading(EvaluateMemory(percentage), now, used, total, percentage);
        _lastSuccess = result;
        return result;
    }

    public static HealthState EvaluateMemory(double percentage) => percentage >= 90 ? HealthState.Critical : percentage >= 75 ? HealthState.Elevated : HealthState.Normal;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct MemoryStatusEx
    {
        public uint Length; public uint MemoryLoad; public ulong TotalPhysical; public ulong AvailablePhysical;
        public ulong TotalPageFile; public ulong AvailablePageFile; public ulong TotalVirtual; public ulong AvailableVirtual; public ulong AvailableExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx buffer);
}

public readonly record struct NetworkCounters(string InterfaceId, long SentBytes, long ReceivedBytes, long StopwatchTicks);

public sealed class NetworkSampler
{
    private NetworkCounters? _baseline;
    private NetworkReading? _lastSuccess;
    private long _sessionUpload;
    private long _sessionDownload;

    public NetworkReading Sample(DateTimeOffset now)
    {
        try
        {
            var nic = FindDefaultPhysicalInterface();
            if (nic is null) return StaleOrCollecting();
            var statistics = nic.GetIPv4Statistics();
            var current = new NetworkCounters(nic.Id, statistics.BytesSent, statistics.BytesReceived, Stopwatch.GetTimestamp());
            if (_baseline is not { } baseline || baseline.InterfaceId != current.InterfaceId)
            {
                _baseline = current;
                return new(HealthState.Collecting, null, null, null, _sessionUpload, _sessionDownload);
            }
            _baseline = current;
            var result = Calculate(baseline, current, now, _sessionUpload, _sessionDownload);
            if (result.State == HealthState.Collecting) return result;
            _sessionUpload = result.SessionUploadBytes; _sessionDownload = result.SessionDownloadBytes; _lastSuccess = result;
            return result;
        }
        catch (Exception) { return StaleOrCollecting(); }
    }

    public static NetworkReading Calculate(NetworkCounters previous, NetworkCounters current, DateTimeOffset sampledAt, long sessionUpload, long sessionDownload)
    {
        if (current.InterfaceId != previous.InterfaceId || current.SentBytes < previous.SentBytes || current.ReceivedBytes < previous.ReceivedBytes || current.StopwatchTicks <= previous.StopwatchTicks)
            return new(HealthState.Collecting, null, null, null, sessionUpload, sessionDownload);
        var elapsed = (current.StopwatchTicks - previous.StopwatchTicks) / (double)Stopwatch.Frequency;
        if (elapsed <= 0) return new(HealthState.Collecting, null, null, null, sessionUpload, sessionDownload);
        var sent = current.SentBytes - previous.SentBytes; var received = current.ReceivedBytes - previous.ReceivedBytes;
        return new(HealthState.Normal, sampledAt, sent / elapsed, received / elapsed, checked(sessionUpload + sent), checked(sessionDownload + received));
    }

    private NetworkReading StaleOrCollecting() => _lastSuccess is { } previous ? previous with { State = HealthState.Stale } : new(HealthState.Collecting, null, null, null, _sessionUpload, _sessionDownload);

    private static NetworkInterface? FindDefaultPhysicalInterface()
    {
        var candidates = NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up &&
            n.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211 &&
            n.GetIPProperties().UnicastAddresses.Any(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)).ToArray();
        if (GetBestInterface(BitConverter.ToUInt32(IPAddress.Parse("1.1.1.1").GetAddressBytes()), out var index) == 0)
        {
            var match = candidates.FirstOrDefault(n => n.GetIPProperties().GetIPv4Properties()?.Index == index);
            if (match is not null) return match;
        }
        return candidates.FirstOrDefault(n => n.GetIPProperties().GatewayAddresses.Any(g => !g.Address.Equals(IPAddress.Any)));
    }

    [DllImport("iphlpapi.dll", SetLastError = true)] private static extern int GetBestInterface(uint destinationAddress, out uint bestInterfaceIndex);
}

public sealed class ThermalSampler : IDisposable
{
    private readonly object _gate = new();
    private Computer? _computer;
    private ThermalReading? _lastSuccess;

    public ThermalReading Sample(DateTimeOffset now)
    {
        lock (_gate)
        {
            try
            {
                _computer ??= OpenComputer();
                var cpuTemperatures = new List<(string Name, double Value)>();
                var storageTemperatures = new List<(string HardwareId, string SensorName, double Value)>();
                var gpuTemperatures = new List<(string Name, double Value)>();
                foreach (var hardware in _computer.Hardware)
                    CollectTemperatures(hardware, cpuTemperatures, storageTemperatures, gpuTemperatures);

                var validCpu = cpuTemperatures.Where(item => IsPlausible(item.Value)).ToArray();
                var validStorage = storageTemperatures.Where(item => IsPlausible(item.Value)).ToArray();
                var validGpu = gpuTemperatures.Where(item => IsPlausible(item.Value)).ToArray();
                if (validCpu.Length == 0 && validStorage.Length == 0 && validGpu.Length == 0) return Unavailable;

                var average = SelectRepresentativeAverage(validCpu);
                double? hottest = validCpu.Length == 0 ? null : validCpu.Max(item => item.Value);
                var storage = SelectPrimaryStorageTemperature(validStorage);
                var gpu = SelectGpuTemperature(validGpu);
                var protocolSensorAvailable = average is not null || hottest is not null || storage is not null;
                var state = protocolSensorAvailable ? EvaluateThermal(average, hottest, storage) : HealthState.Unavailable;
                var result = new ThermalReading(state, now, average, hottest, storage, "unavailable", gpu);
                _lastSuccess = result;
                return result;
            }
            catch (Exception)
            {
                CloseComputer();
                return _lastSuccess is { } previous ? previous with { State = HealthState.Stale } : Unavailable;
            }
        }
    }

    public static ThermalReading Unavailable { get; } = new(HealthState.Unavailable, null, null, null, null, "unavailable");

    public static HealthState EvaluateThermal(double? average, double? hottest, double? storage)
    {
        var state = HealthState.Normal;
        state = MoreSevere(state, Threshold(average, 75, 90));
        state = MoreSevere(state, Threshold(hottest, 85, 100));
        state = MoreSevere(state, Threshold(storage, 70, 85));
        return state;
    }

    private static Computer OpenComputer()
    {
        var computer = new Computer { IsCpuEnabled = true, IsStorageEnabled = true, IsGpuEnabled = true };
        computer.Open();
        return computer;
    }

    private static void CollectTemperatures(IHardware hardware, List<(string Name, double Value)> cpu,
        List<(string HardwareId, string SensorName, double Value)> storage,
        List<(string Name, double Value)> gpu)
    {
        hardware.Update();
        foreach (var sensor in hardware.Sensors)
        {
            if (sensor.SensorType != SensorType.Temperature || sensor.Value is not { } value) continue;
            if (hardware.HardwareType == HardwareType.Cpu) cpu.Add((sensor.Name, value));
            else if (hardware.HardwareType == HardwareType.Storage) storage.Add((hardware.Identifier.ToString(), sensor.Name, value));
            else if (hardware.HardwareType is HardwareType.GpuNvidia or HardwareType.GpuAmd or HardwareType.GpuIntel) gpu.Add((sensor.Name, value));
        }
        foreach (var child in hardware.SubHardware) CollectTemperatures(child, cpu, storage, gpu);
    }

    private static double? SelectRepresentativeAverage(IReadOnlyList<(string Name, double Value)> sensors)
    {
        if (sensors.Count == 0) return null;
        var bestRank = sensors.Min(sensor => RepresentativeRank(sensor.Name));
        var representatives = sensors.Where(sensor => RepresentativeRank(sensor.Name) == bestRank).Select(sensor => sensor.Value);
        return representatives.Average();
    }

    private static double? SelectGpuTemperature(IReadOnlyList<(string Name, double Value)> sensors)
    {
        if (sensors.Count == 0) return null;
        var core = sensors.FirstOrDefault(sensor => sensor.Name.Contains("Core", StringComparison.OrdinalIgnoreCase));
        return core == default ? sensors.Max(sensor => sensor.Value) : core.Value;
    }

    private static double? SelectPrimaryStorageTemperature(
        IReadOnlyList<(string HardwareId, string SensorName, double Value)> sensors)
    {
        if (sensors.Count == 0) return null;
        var primaryDevice = sensors.GroupBy(sensor => sensor.HardwareId, StringComparer.Ordinal)
            .OrderBy(group => group.Key, StringComparer.Ordinal).First().ToArray();
        var composite = primaryDevice.FirstOrDefault(sensor => sensor.SensorName.Contains("Composite", StringComparison.OrdinalIgnoreCase));
        return composite == default ? primaryDevice.Max(sensor => sensor.Value) : composite.Value;
    }

    private static int RepresentativeRank(string name)
    {
        if (name.Contains("Package", StringComparison.OrdinalIgnoreCase)) return 0;
        if (name.Contains("Tctl", StringComparison.OrdinalIgnoreCase) || name.Contains("Tdie", StringComparison.OrdinalIgnoreCase)) return 1;
        if (name.Contains("Core Average", StringComparison.OrdinalIgnoreCase)) return 2;
        if (name.Contains("CPU", StringComparison.OrdinalIgnoreCase)) return 3;
        return 4;
    }

    private static bool IsPlausible(double value) => double.IsFinite(value) && value is > -20 and < 150;
    private static HealthState Threshold(double? value, double elevated, double critical)
    {
        if (value is null) return HealthState.Normal;
        if (value.Value >= critical) return HealthState.Critical;
        return value.Value >= elevated ? HealthState.Elevated : HealthState.Normal;
    }
    private static HealthState MoreSevere(HealthState left, HealthState right) => (HealthState)Math.Max((int)left, (int)right);

    private void CloseComputer()
    {
        try { _computer?.Close(); } catch (Exception) { }
        _computer = null;
    }

    public void Dispose() { lock (_gate) CloseComputer(); }
}

public sealed class ProcessSampler
{
    private Dictionary<(int Id, long Start), TimeSpan> _cpuBaseline = [];
    private long _lastTimestamp;

    public IReadOnlyList<ProcessReading> Sample()
    {
        var nowTicks = Stopwatch.GetTimestamp();
        var elapsed = _lastTimestamp == 0 ? 0 : (nowTicks - _lastTimestamp) / (double)Stopwatch.Frequency;
        var next = new Dictionary<(int, long), TimeSpan>(); var values = new List<ProcessReading>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try
                {
                    var key = (process.Id, process.StartTime.ToUniversalTime().Ticks);
                    var cpu = process.TotalProcessorTime; next[key] = cpu;
                    double? cpuPct = elapsed > 0 && _cpuBaseline.TryGetValue(key, out var old)
                        ? Math.Clamp((cpu - old).TotalSeconds / elapsed / Environment.ProcessorCount * 100d, 0, 100) : null;
                    values.Add(new(process.Id, process.ProcessName, cpuPct, process.WorkingSet64));
                }
                catch (Exception) { }
            }
        }
        _cpuBaseline = next; _lastTimestamp = nowTicks;
        return values.OrderByDescending(v => v.CpuPct ?? -1).Take(3)
            .Concat(values.OrderByDescending(v => v.WorkingSetBytes).Take(3))
            .DistinctBy(v => v.ProcessId).ToArray();
    }
}
