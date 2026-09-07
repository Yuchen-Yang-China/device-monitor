using System.Text;
using System.Text.Json.Nodes;
using DeviceMonitor.Core;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.Tests;

public sealed class PeerStateTests
{
    private static PeerStatusDocument Fixture()
    {
        var bytes = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "status-v1.json"));
        return PeerStatusCodec.Decode(bytes);
    }

    [Fact] public void BackoffUsesFiveTenTwentyThirtySecondsAndResets()
    {
        var state = new PeerPollingStateMachine();
        state.RecordFailure(); Assert.Equal(TimeSpan.FromSeconds(5), state.NextDelay);
        state.RecordFailure(); Assert.Equal(TimeSpan.FromSeconds(10), state.NextDelay);
        state.RecordFailure(); Assert.Equal(TimeSpan.FromSeconds(20), state.NextDelay);
        state.RecordFailure(); Assert.Equal(TimeSpan.FromSeconds(30), state.NextDelay);
        state.RecordSuccess(TimeSpan.FromSeconds(100)); Assert.Equal(TimeSpan.FromSeconds(5), state.NextDelay);
    }

    [Fact] public void ThreeFiveSecondWindowsWithoutSuccessBecomeOffline()
    {
        var state = new PeerPollingStateMachine(); var fixture = Fixture(); var wall = PeerStatusCodec.ParseTimestamp(fixture.CapturedAt, "captured_at");
        state.RecordSuccess(TimeSpan.Zero);
        Assert.Equal(PeerAvailability.Online, state.Availability(TimeSpan.FromSeconds(14.999), fixture, wall));
        Assert.Equal(PeerAvailability.Offline, state.Availability(TimeSpan.FromSeconds(15), fixture, wall));
    }

    [Fact] public void CriticalOrStaleMetricIsDegraded()
    {
        var fixture = Fixture(); var captured = PeerStatusCodec.ParseTimestamp(fixture.CapturedAt, "captured_at");
        var state = new PeerPollingStateMachine(); state.RecordSuccess(TimeSpan.Zero);
        var critical = fixture with { Metrics = fixture.Metrics with { Cpu = fixture.Metrics.Cpu with { State = MetricStates.Critical } } };
        Assert.Equal(PeerAvailability.Degraded, state.Availability(TimeSpan.FromSeconds(1), critical, captured));
    }

    [Fact] public void SameSequenceDoesNotAppendTrendButRefreshesLastReceived()
    {
        var fixture = Fixture(); var store = new RemoteSnapshotStore(); var now = PeerStatusCodec.ParseTimestamp(fixture.CapturedAt, "captured_at");
        Assert.True(store.Accept(fixture, now)); Assert.False(store.Accept(fixture, now.AddSeconds(5)));
        Assert.Single(store.MemoryTrend); Assert.Equal(now.AddSeconds(5), store.LastReceivedAt);
    }

    [Fact] public void RestartClearsTrendAndAcceptsSequenceOne()
    {
        var first = Fixture(); var store = new RemoteSnapshotStore(); var now = PeerStatusCodec.ParseTimestamp(first.CapturedAt, "captured_at"); store.Accept(first, now);
        var restarted = first with { Sequence = 1, Device = first.Device with { StartedAt = "2026-09-06T08:01:00.000Z" } };
        Assert.True(store.Accept(restarted, now.AddSeconds(5))); Assert.Single(store.MemoryTrend); Assert.Equal(1, store.Snapshot!.Sequence);
    }
}
