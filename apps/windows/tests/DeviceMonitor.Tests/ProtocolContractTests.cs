using System.Text;
using System.Text.Json.Nodes;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.Tests;

public sealed class ProtocolContractTests
{
    private static byte[] Fixture => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json"));

    [Fact] public void FixtureDecodesAndPreservesNulls()
    {
        var document = PeerStatusCodec.Decode(Fixture);
        Assert.Equal(1, document.ApiVersion); Assert.Equal(42, document.Sequence);
        Assert.Equal("macos", document.Device.Platform); Assert.Equal(1.21, document.Metrics.Cpu.LoadAverage1);
        Assert.Null(document.Metrics.Thermal.GpuCelsius);
        Assert.False(document.Capabilities.GpuTemperature); Assert.True(document.Capabilities.StorageTemperature);
    }

    [Fact] public void UnknownFieldsAreIgnored()
    {
        var node = JsonNode.Parse(Fixture)!.AsObject(); node["futureField"] = new JsonObject { ["nested"] = true };
        Assert.Equal(42, PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString())).Sequence);
    }

    [Fact] public void MacMayOmitGpuTemperatureWithoutCausingAProtocolError()
    {
        var node = JsonNode.Parse(Fixture)!.AsObject();
        node["metrics"]!["thermal"]!.AsObject().Remove("gpuCelsius");
        node["capabilities"]!.AsObject().Remove("gpuTemperature");
        var document = PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString()));
        Assert.Null(document.Metrics.Thermal.GpuCelsius); Assert.False(document.Capabilities.GpuTemperature);
    }

    [Fact] public void MissingStorageCapabilityIsInferredFromCanonicalStorageValue()
    {
        var node = JsonNode.Parse(Fixture)!.AsObject();
        node["capabilities"]!.AsObject().Remove("storageTemperature");
        Assert.True(PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString())).Capabilities.StorageTemperature);
    }

    [Theory]
    [InlineData("cpu", "loadAverage1")]
    [InlineData("memory", "wiredBytes")]
    [InlineData("thermal", "storageCelsius")]
    [InlineData("network", "uploadBytesPerSecond")]
    public void MissingCoreOptionalMetricFieldIsRejected(string metric, string field)
    {
        var node = JsonNode.Parse(Fixture)!.AsObject(); node["metrics"]![metric]!.AsObject().Remove(field);
        Assert.Throws<ProtocolException>(() => PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString())));
    }

    [Fact] public void CoreOptionalMetricFieldsAcceptExplicitJsonNull()
    {
        var node = JsonNode.Parse(Fixture)!.AsObject();
        node["metrics"]!["cpu"]!["loadAverage1"] = null;
        node["metrics"]!["memory"]!["wiredBytes"] = null;
        node["metrics"]!["thermal"]!["storageCelsius"] = null;
        node["metrics"]!["network"]!["uploadBytesPerSecond"] = null;
        var document = PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString()));
        Assert.Null(document.Metrics.Cpu.LoadAverage1); Assert.Null(document.Metrics.Memory.WiredBytes);
        Assert.Null(document.Metrics.Thermal.StorageCelsius); Assert.Null(document.Metrics.Network.UploadBytesPerSecond);
    }

    [Theory] [InlineData("apiVersion")] [InlineData("device")] [InlineData("metrics")]
    public void MissingRequiredTopLevelFieldIsRejected(string field)
    {
        var node = JsonNode.Parse(Fixture)!.AsObject(); node.Remove(field);
        Assert.ThrowsAny<Exception>(() => PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString())));
    }

    [Fact] public void WrongVersionIsRejected()
    {
        var node = JsonNode.Parse(Fixture)!.AsObject(); node["apiVersion"] = 2;
        Assert.Equal("incompatible_version", Assert.Throws<ProtocolException>(() => PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString()))).Message);
    }

    [Fact] public void NegativeBytesAreRejected()
    {
        var node = JsonNode.Parse(Fixture)!.AsObject(); node["metrics"]!["memory"]!["usedBytes"] = -1;
        Assert.Throws<ProtocolException>(() => PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(node.ToJsonString())));
    }

    [Theory] [InlineData("NaN")] [InlineData("Infinity")]
    public void NonFiniteNumbersAreRejected(string token)
    {
        var json = Encoding.UTF8.GetString(Fixture).Replace("23.4", token, StringComparison.Ordinal);
        Assert.Throws<ProtocolException>(() => PeerStatusCodec.Decode(Encoding.UTF8.GetBytes(json)));
    }
}
