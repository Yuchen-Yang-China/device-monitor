using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace DeviceMonitor.Protocol;

public static class ProtocolConstants
{
    public const int ApiVersion = 1;
    public const int DefaultPort = 48621;
    public const string StatusPath = "/v1/status";
    public const int MaximumBodyBytes = 64 * 1024;
    public static readonly TimeSpan AuthenticationWindow = TimeSpan.FromSeconds(120);
    public static readonly TimeSpan NonceRetention = TimeSpan.FromMinutes(5);
    public static readonly TimeSpan NormalPollInterval = TimeSpan.FromSeconds(5);
    public static readonly TimeSpan OfflineAfter = TimeSpan.FromSeconds(15);
}

public static class MetricStates
{
    public const string Normal = "normal";
    public const string Elevated = "elevated";
    public const string Critical = "critical";
    public const string Collecting = "collecting";
    public const string Unavailable = "unavailable";
    public const string Stale = "stale";
    public static bool IsValid(string value) => value is Normal or Elevated or Critical or Collecting or Unavailable or Stale;
}

public sealed record PeerStatusDocument
{
    public required int ApiVersion { get; init; }
    public required long Sequence { get; init; }
    public required string CapturedAt { get; init; }
    public required PeerDevice Device { get; init; }
    public required PeerCapabilities Capabilities { get; init; }
    public required PeerMetrics Metrics { get; init; }
}

public sealed record PeerDevice
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Platform { get; init; }
    public required string OsVersion { get; init; }
    public required string AppVersion { get; init; }
    public required string StartedAt { get; init; }
}

public sealed record PeerCapabilities
{
    public required bool CpuBreakdown { get; init; }
    public required bool LoadAverage { get; init; }
    public required bool HybridCoreTopology { get; init; }
    public required bool MemoryBreakdown { get; init; }
    public required bool Swap { get; init; }
    public required bool TemperatureSensors { get; init; }
    public required bool OsThermalState { get; init; }
    public required bool WifiSignal { get; init; }
    public bool GpuTemperature { get; init; }
    public bool StorageTemperature { get; init; }
}

public sealed record PeerMetrics
{
    public required CpuMetric Cpu { get; init; }
    public required MemoryMetric Memory { get; init; }
    public required ThermalMetric Thermal { get; init; }
    public required NetworkMetric Network { get; init; }
}

public sealed record CpuMetric
{
    public required string State { get; init; }
    public required string? SampledAt { get; init; }
    public required double? UtilizationPct { get; init; }
    public required double? UserPct { get; init; }
    public required double? SystemPct { get; init; }
    public required double? IdlePct { get; init; }
    public required double? LoadAverage1 { get; init; }
    public required double? LoadAverage5 { get; init; }
    public required double? LoadAverage15 { get; init; }
    public required int PerformanceCores { get; init; }
    public required int EfficiencyCores { get; init; }
    public required bool HybridTopology { get; init; }
}

public sealed record MemoryMetric
{
    public required string State { get; init; }
    public required string? SampledAt { get; init; }
    public required long? UsedBytes { get; init; }
    public required long? TotalBytes { get; init; }
    public required double? UsedPct { get; init; }
    public required long? WiredBytes { get; init; }
    public required long? CompressedBytes { get; init; }
    public required long? CachedBytes { get; init; }
    public required long? SwapUsedBytes { get; init; }
    public required long? SwapTotalBytes { get; init; }
}

public sealed record ThermalMetric
{
    public required string State { get; init; }
    public required string? SampledAt { get; init; }
    public required string OsState { get; init; }
    public required double? AverageCelsius { get; init; }
    public required double? HottestCelsius { get; init; }
    public required double? StorageCelsius { get; init; }
    public double? GpuCelsius { get; init; }
}

public sealed record NetworkMetric
{
    public required string State { get; init; }
    public required string? SampledAt { get; init; }
    public required double? UploadBytesPerSecond { get; init; }
    public required double? DownloadBytesPerSecond { get; init; }
    public required long SessionUploadBytes { get; init; }
    public required long SessionDownloadBytes { get; init; }
}

public sealed class ProtocolException(string message) : Exception(message);

public static class PeerStatusCodec
{
    private static readonly Regex TimestampPattern = new(
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$",
        RegexOptions.CultureInvariant | RegexOptions.Compiled);

    public static JsonSerializerOptions JsonOptions { get; } = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = false,
        NumberHandling = JsonNumberHandling.Strict,
        DefaultIgnoreCondition = JsonIgnoreCondition.Never,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Skip
    };

    public static PeerStatusDocument Decode(ReadOnlySpan<byte> body)
    {
        if (body.Length > ProtocolConstants.MaximumBodyBytes) throw new ProtocolException("body_too_large");
        PeerStatusDocument document;
        try
        {
            using var json = JsonDocument.Parse(body.ToArray());
            document = json.RootElement.Deserialize<PeerStatusDocument>(JsonOptions)
                ?? throw new ProtocolException("invalid_json");
            Validate(document);

            // storageTemperature was added as an optional v1 capability. Older peers
            // omitted it, so infer it only when the canonical storage value is present.
            var capabilities = json.RootElement.GetProperty("capabilities");
            if (!capabilities.TryGetProperty("storageTemperature", out _) && document.Metrics.Thermal.StorageCelsius is not null)
                document = document with { Capabilities = document.Capabilities with { StorageTemperature = true } };
        }
        catch (JsonException exception)
        {
            throw new ProtocolException($"invalid_json: {exception.Message}");
        }
        return document;
    }

    public static byte[] Encode(PeerStatusDocument document)
    {
        Validate(document);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(document, JsonOptions);
        if (bytes.Length > ProtocolConstants.MaximumBodyBytes) throw new ProtocolException("body_too_large");
        return bytes;
    }

    public static string FormatTimestamp(DateTimeOffset value) =>
        value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);

    public static DateTimeOffset ParseTimestamp(string value, string field)
    {
        if (!TimestampPattern.IsMatch(value) ||
            !DateTimeOffset.TryParseExact(value, "yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var result))
            throw new ProtocolException($"invalid_{field}");
        return result;
    }

    public static void Validate(PeerStatusDocument value)
    {
        if (value.ApiVersion != ProtocolConstants.ApiVersion) throw new ProtocolException("incompatible_version");
        if (value.Sequence < 0) throw new ProtocolException("invalid_sequence");
        ParseTimestamp(value.CapturedAt, "captured_at");
        ValidateDevice(value.Device);
        ArgumentNullException.ThrowIfNull(value.Capabilities);
        ArgumentNullException.ThrowIfNull(value.Metrics);
        ValidateCpu(value.Metrics.Cpu);
        ValidateMemory(value.Metrics.Memory);
        ValidateThermal(value.Metrics.Thermal);
        ValidateNetwork(value.Metrics.Network);
    }

    private static void ValidateDevice(PeerDevice value)
    {
        ArgumentNullException.ThrowIfNull(value);
        if (!Guid.TryParseExact(value.Id, "D", out var id) || id == Guid.Empty || value.Id != value.Id.ToLowerInvariant())
            throw new ProtocolException("invalid_device_id");
        if (string.IsNullOrWhiteSpace(value.Name) || value.Name.Length > 80) throw new ProtocolException("invalid_device_name");
        if (value.Platform is not ("macos" or "windows")) throw new ProtocolException("invalid_platform");
        if (string.IsNullOrEmpty(value.OsVersion) || value.OsVersion.Length > 80) throw new ProtocolException("invalid_os_version");
        if (string.IsNullOrEmpty(value.AppVersion) || value.AppVersion.Length > 40) throw new ProtocolException("invalid_app_version");
        ParseTimestamp(value.StartedAt, "started_at");
    }

    private static void ValidateCpu(CpuMetric value)
    {
        ArgumentNullException.ThrowIfNull(value);
        ValidateState(value.State); ValidateOptionalTimestamp(value.SampledAt);
        Percentage(value.UtilizationPct, "cpu_utilization"); Percentage(value.UserPct, "cpu_user");
        Percentage(value.SystemPct, "cpu_system"); Percentage(value.IdlePct, "cpu_idle");
        NonNegative(value.LoadAverage1, "load_1"); NonNegative(value.LoadAverage5, "load_5"); NonNegative(value.LoadAverage15, "load_15");
        if (value.PerformanceCores < 0 || value.EfficiencyCores < 0) throw new ProtocolException("invalid_core_count");
    }

    private static void ValidateMemory(MemoryMetric value)
    {
        ArgumentNullException.ThrowIfNull(value);
        ValidateState(value.State); ValidateOptionalTimestamp(value.SampledAt);
        Bytes(value.UsedBytes, "memory_used"); Bytes(value.TotalBytes, "memory_total"); Percentage(value.UsedPct, "memory_percentage");
        Bytes(value.WiredBytes, "memory_wired"); Bytes(value.CompressedBytes, "memory_compressed"); Bytes(value.CachedBytes, "memory_cached");
        Bytes(value.SwapUsedBytes, "swap_used"); Bytes(value.SwapTotalBytes, "swap_total");
    }

    private static void ValidateThermal(ThermalMetric value)
    {
        ArgumentNullException.ThrowIfNull(value);
        ValidateState(value.State); ValidateOptionalTimestamp(value.SampledAt);
        if (value.OsState is not ("nominal" or "fair" or "serious" or "critical" or "unavailable")) throw new ProtocolException("invalid_thermal_os_state");
        Finite(value.AverageCelsius, "thermal_average"); Finite(value.HottestCelsius, "thermal_hottest");
        Finite(value.StorageCelsius, "thermal_storage"); Finite(value.GpuCelsius, "thermal_gpu");
    }

    private static void ValidateNetwork(NetworkMetric value)
    {
        ArgumentNullException.ThrowIfNull(value);
        ValidateState(value.State); ValidateOptionalTimestamp(value.SampledAt);
        NonNegative(value.UploadBytesPerSecond, "network_upload"); NonNegative(value.DownloadBytesPerSecond, "network_download");
        if (value.SessionUploadBytes < 0 || value.SessionDownloadBytes < 0) throw new ProtocolException("invalid_network_session_bytes");
    }

    private static void ValidateState(string value) { if (!MetricStates.IsValid(value)) throw new ProtocolException("invalid_metric_state"); }
    private static void ValidateOptionalTimestamp(string? value) { if (value is not null) ParseTimestamp(value, "sampled_at"); }
    private static void Percentage(double? value, string field) { Finite(value, field); if (value is < 0 or > 100) throw new ProtocolException($"invalid_{field}"); }
    private static void NonNegative(double? value, string field) { Finite(value, field); if (value < 0) throw new ProtocolException($"invalid_{field}"); }
    private static void Bytes(long? value, string field) { if (value < 0) throw new ProtocolException($"invalid_{field}"); }
    private static void Finite(double? value, string field) { if (value is { } number && !double.IsFinite(number)) throw new ProtocolException($"invalid_{field}"); }
}
