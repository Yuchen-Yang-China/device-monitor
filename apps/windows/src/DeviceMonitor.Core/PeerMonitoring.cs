using System.Diagnostics;
using DeviceMonitor.Protocol;

namespace DeviceMonitor.Core;

public enum PeerAvailability { Online, Degraded, Offline }

public sealed class PeerPollingStateMachine
{
    private TimeSpan? _lastSuccess; private int _failures;
    public int ConsecutiveFailures => _failures;
    public void RecordSuccess(TimeSpan monotonicNow) { _lastSuccess = monotonicNow; _failures = 0; }
    public void RecordFailure() => _failures++;
    public TimeSpan NextDelay => _failures switch { <= 1 => TimeSpan.FromSeconds(5), 2 => TimeSpan.FromSeconds(10), 3 => TimeSpan.FromSeconds(20), _ => TimeSpan.FromSeconds(30) };
    public PeerAvailability Availability(TimeSpan monotonicNow, PeerStatusDocument? snapshot, DateTimeOffset wallNow)
    {
        if (_lastSuccess is null || monotonicNow - _lastSuccess.Value >= ProtocolConstants.OfflineAfter) return PeerAvailability.Offline;
        if (snapshot is not null && IsDegraded(snapshot, wallNow)) return PeerAvailability.Degraded;
        return PeerAvailability.Online;
    }
    public TimeSpan? TimeUntilOffline(TimeSpan monotonicNow)
    {
        if (_lastSuccess is null) return null;
        var remaining = ProtocolConstants.OfflineAfter - (monotonicNow - _lastSuccess.Value);
        return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
    }

    public static bool IsDegraded(PeerStatusDocument value, DateTimeOffset now)
    {
        var states = new[] { value.Metrics.Cpu.State, value.Metrics.Memory.State, value.Metrics.Thermal.State, value.Metrics.Network.State };
        if (states.Any(state => state is MetricStates.Stale or MetricStates.Critical)) return true;
        return now - PeerStatusCodec.ParseTimestamp(value.CapturedAt, "captured_at") > ProtocolConstants.OfflineAfter;
    }
}

public sealed class RemoteSnapshotStore
{
    private readonly object _gate = new(); private readonly List<TrendPoint> _memoryTrend = [];
    public PeerStatusDocument? Snapshot { get; private set; }
    public DateTimeOffset? LastReceivedAt { get; private set; }
    public IReadOnlyList<TrendPoint> MemoryTrend { get { lock (_gate) return _memoryTrend.ToArray(); } }

    public bool Accept(PeerStatusDocument incoming, DateTimeOffset receivedAt)
    {
        lock (_gate)
        {
            LastReceivedAt = receivedAt;
            var restarted = Snapshot is not null && (Snapshot.Device.Id != incoming.Device.Id || Snapshot.Device.StartedAt != incoming.Device.StartedAt);
            if (restarted) _memoryTrend.Clear();
            if (!restarted && Snapshot is not null && incoming.Sequence <= Snapshot.Sequence) return false;
            Snapshot = incoming;
            if (incoming.Metrics.Memory is { SampledAt: { } sampled, UsedPct: { } used } && incoming.Metrics.Memory.State != MetricStates.Stale)
            {
                _memoryTrend.Add(new(PeerStatusCodec.ParseTimestamp(sampled, "sampled_at"), used));
                LocalMonitorStore.TrimTrend(_memoryTrend, receivedAt);
            }
            return true;
        }
    }
}

public sealed class PeerPoller : IAsyncDisposable
{
    private readonly PeerStatusClient _client; private readonly Uri _endpoint; private readonly string _localDeviceId;
    private readonly byte[] _secret; private readonly CancellationTokenSource _cancellation = new();
    private readonly Stopwatch _clock = Stopwatch.StartNew(); private readonly PeerPollingStateMachine _state = new();
    private readonly SemaphoreSlim _wake = new(0, 1);
    private Task? _loop;
    public PeerPoller(PeerStatusClient client, Uri endpoint, string localDeviceId, ReadOnlySpan<byte> secret, RemoteSnapshotStore store)
    { _client = client; _endpoint = endpoint; _localDeviceId = localDeviceId; _secret = secret.ToArray(); Store = store; }
    public RemoteSnapshotStore Store { get; }
    public PeerAvailability Availability => _state.Availability(_clock.Elapsed, Store.Snapshot, DateTimeOffset.UtcNow);
    public string? LastError { get; private set; }
    public event Action? Changed;
    public void Start() => _loop ??= Task.Run(() => RunAsync(_cancellation.Token));
    public void RequestImmediatePoll() { if (_wake.CurrentCount == 0) _wake.Release(); }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        var nextAttempt = TimeSpan.Zero;
        while (!cancellationToken.IsCancellationRequested)
        {
            var now = _clock.Elapsed;
            if (now < nextAttempt)
            {
                var wait = nextAttempt - now; var untilOffline = _state.TimeUntilOffline(now);
                if (untilOffline.HasValue && untilOffline.Value > TimeSpan.Zero && untilOffline.Value < wait) wait = untilOffline.Value;
                if (await _wake.WaitAsync(wait, cancellationToken).ConfigureAwait(false)) { nextAttempt = _clock.Elapsed; continue; }
                Changed?.Invoke(); continue;
            }
            try
            {
                var document = await _client.GetStatusAsync(_endpoint, _localDeviceId, _secret, cancellationToken).ConfigureAwait(false);
                Store.Accept(document, DateTimeOffset.UtcNow); _state.RecordSuccess(_clock.Elapsed); LastError = null;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                _state.RecordFailure(); LastError = exception is PeerTransportException transport ? transport.Error.ToString() : "Connection";
            }
            nextAttempt = _clock.Elapsed + _state.NextDelay; Changed?.Invoke();
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation.Cancel(); if (_loop is not null) try { await _loop.ConfigureAwait(false); } catch (OperationCanceledException) { }
        System.Security.Cryptography.CryptographicOperations.ZeroMemory(_secret); _wake.Dispose(); _cancellation.Dispose();
    }
}
