using System.Diagnostics;
using DeviceMonitor.Core;
using DeviceMonitor.Protocol;
using Xunit.Abstractions;

namespace DeviceMonitor.Tests;

public sealed class SamplerAndStoreTests
{
    private readonly ITestOutputHelper _output;
    public SamplerAndStoreTests(ITestOutputHelper output) => _output = output;

    [Fact] public void CpuCalculationUsesOverallNonIdlePercentage()
    {
        var now = DateTimeOffset.UtcNow;
        var value = CpuSampler.Calculate(new(100, 300, 200), new(140, 380, 220), now, 8);
        Assert.Equal(60d, value.UtilizationPct!.Value, 6); Assert.Equal(20d, value.UserPct!.Value, 6);
        Assert.Equal(40d, value.SystemPct!.Value, 6); Assert.Equal(40d, value.IdlePct!.Value, 6); Assert.Equal(HealthState.Normal, value.State);
    }

    [Theory] [InlineData(64.99, HealthState.Normal)] [InlineData(65, HealthState.Elevated)] [InlineData(90, HealthState.Critical)]
    public void CpuThresholdsMatchProductSpec(double value, HealthState expected) => Assert.Equal(expected, CpuSampler.EvaluateCpu(value));

    [Theory] [InlineData(74.99, HealthState.Normal)] [InlineData(75, HealthState.Elevated)] [InlineData(90, HealthState.Critical)]
    public void MemoryThresholdsMatchProductSpec(double value, HealthState expected) => Assert.Equal(expected, MemorySampler.EvaluateMemory(value));

    [Theory]
    [InlineData(74.9, 84.9, 69.9, HealthState.Normal)]
    [InlineData(75, 80, 60, HealthState.Elevated)]
    [InlineData(60, 100, 60, HealthState.Critical)]
    [InlineData(60, 70, 85, HealthState.Critical)]
    public void ThermalThresholdsMatchProtocol(double average, double hottest, double storage, HealthState expected) =>
        Assert.Equal(expected, ThermalSampler.EvaluateThermal(average, hottest, storage));

    [Fact] public void HardwareThermalSamplerReturnsAConsistentHonestReading()
    {
        using var sampler = new ThermalSampler(); var reading = sampler.Sample(DateTimeOffset.UtcNow);
        _output.WriteLine($"state={reading.State}, average={reading.AverageCelsius}, hottest={reading.HottestCelsius}, gpu={reading.GpuCelsius}, storage={reading.StorageCelsius}");
        if (reading.State == HealthState.Unavailable && reading.GpuCelsius is null)
        {
            Assert.Null(reading.AverageCelsius); Assert.Null(reading.HottestCelsius); Assert.Null(reading.GpuCelsius); Assert.Null(reading.StorageCelsius);
        }
        else
        {
            Assert.NotNull(reading.SampledAt);
            Assert.True(reading.AverageCelsius is not null || reading.HottestCelsius is not null || reading.GpuCelsius is not null || reading.StorageCelsius is not null);
        }
    }

    [Fact] public void NetworkCounterResetRebuildsBaselineWithoutSpike()
    {
        var previous = new NetworkCounters("a", 1000, 2000, Stopwatch.Frequency);
        var reset = new NetworkCounters("a", 10, 20, Stopwatch.Frequency * 2);
        var value = NetworkSampler.Calculate(previous, reset, DateTimeOffset.UtcNow, 50, 60);
        Assert.Equal(HealthState.Collecting, value.State); Assert.Null(value.UploadBytesPerSecond);
    }

    [Fact] public void NetworkRatesAndSessionTotalsUseBytesAndSeconds()
    {
        var previous = new NetworkCounters("a", 1000, 2000, Stopwatch.Frequency);
        var current = new NetworkCounters("a", 3000, 7000, Stopwatch.Frequency * 3);
        var value = NetworkSampler.Calculate(previous, current, DateTimeOffset.UtcNow, 50, 60);
        Assert.Equal(1000, value.UploadBytesPerSecond); Assert.Equal(2500, value.DownloadBytesPerSecond);
        Assert.Equal(2050, value.SessionUploadBytes); Assert.Equal(5060, value.SessionDownloadBytes);
    }

    [Fact] public void MemoryTrendKeepsOnlyFiveMinutesAndSkipsStale()
    {
        var now = DateTimeOffset.UtcNow; var store = new LocalMonitorStore(now.AddMinutes(-10));
        store.Update(now.AddMinutes(-6), memory: new(HealthState.Normal, now.AddMinutes(-6), 1, 2, 50));
        store.Update(now, memory: new(HealthState.Normal, now, 1, 2, 50));
        store.Update(now.AddSeconds(1), memory: new(HealthState.Stale, now, 1, 2, 50));
        Assert.Single(store.MemoryTrend); Assert.Equal(now, store.MemoryTrend[0].SampledAt);
    }

    [Fact] public void SamplingSchedulesMatchContract()
    {
        Assert.Equal(TimeSpan.FromSeconds(5), SamplingSchedule.For(SamplingMode.Balanced).SystemInterval);
        Assert.Equal(TimeSpan.FromSeconds(10), SamplingSchedule.For(SamplingMode.LowPower).SystemInterval);
        Assert.Equal(TimeSpan.FromSeconds(2), SamplingSchedule.For(SamplingMode.Responsive).SystemInterval);
    }

    [Fact] public void WindowsProtocolMappingUsesNullForUnavailableConceptsAndOmitsPrivateDetails()
    {
        var now = DateTimeOffset.UtcNow;
        var snapshot = new LocalSnapshot(7, now,
            new(HealthState.Normal, now, 25, 15, 10, 75, 8),
            new(HealthState.Normal, now, 8_000_000, 16_000_000, 50),
            ThermalSampler.Unavailable, new(HealthState.Normal, now, 100, 200, 300, 400),
            [new(123, "private-process-name", 1, 1000)]);
        var identity = new DeviceIdentity(Guid.NewGuid().ToString("D"), "Windows PC", "Windows", "0.1.0", now);
        var protocol = ProtocolMapper.ToProtocol(snapshot, identity); var json = System.Text.Encoding.UTF8.GetString(PeerStatusCodec.Encode(protocol));
        Assert.Null(protocol.Metrics.Cpu.LoadAverage1); Assert.False(protocol.Capabilities.LoadAverage);
        Assert.Equal(MetricStates.Unavailable, protocol.Metrics.Thermal.State); Assert.Null(protocol.Metrics.Thermal.AverageCelsius);
        Assert.DoesNotContain("private-process-name", json); Assert.DoesNotContain("ssid", json, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("username", json, StringComparison.OrdinalIgnoreCase);
        var metrics = System.Text.Json.Nodes.JsonNode.Parse(json)!["metrics"]!;
        static void AssertFields(System.Text.Json.Nodes.JsonObject metric, params string[] names)
        { foreach (var name in names) Assert.True(metric.ContainsKey(name), $"Missing required metric field: {name}"); }
        AssertFields(metrics["cpu"]!.AsObject(), "sampledAt", "utilizationPct", "userPct", "systemPct", "idlePct", "loadAverage1", "loadAverage5", "loadAverage15");
        AssertFields(metrics["memory"]!.AsObject(), "sampledAt", "usedBytes", "totalBytes", "usedPct", "wiredBytes", "compressedBytes", "cachedBytes", "swapUsedBytes", "swapTotalBytes");
        AssertFields(metrics["thermal"]!.AsObject(), "sampledAt", "averageCelsius", "hottestCelsius", "storageCelsius", "gpuCelsius");
        AssertFields(metrics["network"]!.AsObject(), "sampledAt", "uploadBytesPerSecond", "downloadBytesPerSecond");
    }

    [Fact] public void WindowsUsesCanonicalGpuAndStorageTemperatureFields()
    {
        var now = DateTimeOffset.UtcNow;
        var snapshot = new LocalSnapshot(1, now, new(HealthState.Collecting, null, null, null, null, null, 8),
            new(HealthState.Normal, now, 1, 2, 50), new(HealthState.Normal, now, null, null, null, "unavailable", 55),
            new(HealthState.Collecting, null, null, null, 0, 0), []);
        var protocol = ProtocolMapper.ToProtocol(snapshot, new(Guid.NewGuid().ToString("D"), "PC", "Windows", "0.1.0", now));
        Assert.Equal(MetricStates.Unavailable, protocol.Metrics.Thermal.State);
        Assert.Null(protocol.Metrics.Thermal.SampledAt); Assert.Null(protocol.Metrics.Thermal.AverageCelsius);
        Assert.Equal(55, protocol.Metrics.Thermal.GpuCelsius);
        Assert.True(protocol.Capabilities.GpuTemperature); Assert.False(protocol.Capabilities.StorageTemperature);
        Assert.False(protocol.Capabilities.TemperatureSensors);
        var json = System.Text.Encoding.UTF8.GetString(PeerStatusCodec.Encode(protocol));
        Assert.Contains("\"gpuCelsius\":55", json); Assert.Contains("\"storageCelsius\":null", json);
        Assert.Contains("\"gpuTemperature\":true", json); Assert.Contains("\"storageTemperature\":false", json);
        Assert.DoesNotContain("ssdCelsius", json); Assert.DoesNotContain("ssdTemperature", json);
    }
}
