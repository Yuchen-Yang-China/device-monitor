import XCTest
@testable import DeviceMonitor

final class DeviceMonitorTests: XCTestCase {
    func testSamplingProfilesExposeTheirCadenceContract() {
        XCTAssertEqual(SamplingProfile.balanced.networkInterval, 1)
        XCTAssertEqual(SamplingProfile.balanced.systemInterval, 5)
        XCTAssertEqual(SamplingProfile.balanced.thermalInterval, 15)

        XCTAssertEqual(SamplingProfile.lowPower.networkInterval, 2)
        XCTAssertEqual(SamplingProfile.lowPower.systemInterval, 10)
        XCTAssertEqual(SamplingProfile.lowPower.thermalInterval, 30)

        XCTAssertEqual(SamplingProfile.responsive.networkInterval, 1)
        XCTAssertEqual(SamplingProfile.responsive.systemInterval, 2)
        XCTAssertEqual(SamplingProfile.responsive.thermalInterval, 10)
    }

    func testThermalStateRemainsVisibleWhenTemperatureSensorIsUnavailable() {
        let reading = thermal(state: .critical)

        XCTAssertEqual(reading.level, .critical)
        XCTAssertEqual(reading.primaryText, "Unavailable")
    }

    func testThermalStateAndSensorSeverityAreCombined() {
        XCTAssertEqual(thermal(state: .fair).level, .elevated)
        XCTAssertEqual(thermal(state: .serious).level, .elevated)
        XCTAssertEqual(thermal(state: .nominal, soc: 70, hottest: 100).level, .critical)
        XCTAssertEqual(thermal(state: .nominal, soc: 70, ssd: 85).level, .critical)
        XCTAssertEqual(thermal(state: .nominal, soc: 70, ssd: 75).level, .elevated)
    }

    func testTrendStatisticsHandleEmptyAndRepeatedValues() {
        let start = Date(timeIntervalSince1970: 1_000)
        let points = [
            TrendPoint(date: start, value: 10),
            TrendPoint(date: start.addingTimeInterval(1), value: 20),
            TrendPoint(date: start.addingTimeInterval(3), value: 20)
        ]

        XCTAssertNil(TrendMath.average([]))
        XCTAssertEqual(
            try XCTUnwrap(TrendMath.average(points, now: start.addingTimeInterval(3))),
            50.0 / 3.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(try XCTUnwrap(TrendMath.peak(points)), 20)
        XCTAssertEqual(try XCTUnwrap(TrendMath.minimum(points)), 10)
    }

    func testTrendCumulativeBytesUsesTheElapsedWindow() {
        let start = Date(timeIntervalSince1970: 2_000)
        let points = [
            TrendPoint(date: start, value: 100),
            TrendPoint(date: start.addingTimeInterval(60), value: 100)
        ]

        XCTAssertEqual(
            TrendMath.cumulativeBytes(points, now: start.addingTimeInterval(60)),
            6_000
        )
    }

    func testRateFormatterHasStableUnavailableAndUnitBoundaries() {
        XCTAssertEqual(ByteFormatter.rateShort(nil), "--")
        XCTAssertEqual(ByteFormatter.rateShort(0), "0")
        XCTAssertEqual(ByteFormatter.rateShort(-1), "0")
        XCTAssertEqual(ByteFormatter.rateShort(.nan), "--")
        XCTAssertEqual(ByteFormatter.rateShort(.infinity), "--")
        XCTAssertEqual(ByteFormatter.rateShort(-.infinity), "--")
        XCTAssertEqual(ByteFormatter.rateShort(1_000), "1.0K")
        XCTAssertEqual(ByteFormatter.rateShort(1_000_000), "1.0M")
        XCTAssertEqual(ByteFormatter.rateShort(1_000_000_000), "1.0G")
    }

    func testNetworkReadingRetainsFreshnessMetadata() {
        let capturedAt = Date(timeIntervalSince1970: 3_000)
        let reading = NetworkReading(
            uploadBytesPerSecond: 1_000,
            downloadBytesPerSecond: 2_000,
            sessionUploadBytes: 10,
            sessionDownloadBytes: 20,
            wifi: nil,
            capturedAt: capturedAt,
            isStale: true
        )

        XCTAssertTrue(reading.isStale)
        XCTAssertEqual(reading.capturedAt, capturedAt)
        XCTAssertEqual(reading.uploadShortText, "1.0K")
        XCTAssertEqual(reading.downloadShortText, "2.0K")
    }

    func testPeerRequestSignatureMatchesCrossPlatformVector() throws {
        let secret = try XCTUnwrap(Data(base64URLString: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        let canonical = PeerSecurity.requestCanonical(
            timestamp: 1_788_681_600_123,
            nonce: "AAECAwQFBgcICQoLDA0ODw"
        )

        XCTAssertEqual(
            PeerSecurity.signature(canonical: canonical, secret: secret),
            "ba66319222045ec9fde8f1aee9e39a378d77af5c3413c0b6306b05c62b83586f"
        )
    }

    func testPeerFixtureDecodesAndValidatesOptionalTemperatures() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = projectDirectory.appendingPathComponent("../../docs/examples/status-v1.json").standardizedFileURL
        let payload = try JSONDecoder().decode(PeerStatusPayload.self, from: Data(contentsOf: fixtureURL))

        try payload.validate()
        XCTAssertEqual(payload.apiVersion, 1)
        XCTAssertEqual(payload.metrics.thermal.storageCelsius, 42)
        XCTAssertNil(payload.metrics.thermal.gpuCelsius)
        XCTAssertEqual(payload.capabilities.gpuTemperature, false)
        XCTAssertEqual(payload.capabilities.storageTemperature, true)
    }

    func testPeerEncoderEmitsRequiredNullsAndDecoderRejectsMissingFields() throws {
        let payload = PeerStatusPayload.make(
            snapshot: .initial,
            sequence: 1,
            deviceID: "76848ab5-f9de-41cb-aa10-d9588b53ef53",
            deviceName: "Test Mac",
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let encoded = try JSONEncoder().encode(payload)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
        let cpu = try XCTUnwrap(metrics["cpu"] as? [String: Any])
        let network = try XCTUnwrap(metrics["network"] as? [String: Any])
        XCTAssertTrue(cpu["utilizationPct"] is NSNull)
        XCTAssertTrue(cpu["sampledAt"] is NSNull)
        XCTAssertTrue(network["uploadBytesPerSecond"] is NSNull)

        var changedMetrics = metrics
        var changedCPU = cpu
        changedCPU.removeValue(forKey: "utilizationPct")
        changedMetrics["cpu"] = changedCPU
        object["metrics"] = changedMetrics
        let missingField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(PeerStatusPayload.self, from: missingField))
    }

    func testPeerEndpointAcceptsHostAndRejectsCredentialsOrPaths() throws {
        XCTAssertEqual(
            try PeerEndpoint.parse("monitor-pc:48621"),
            PeerEndpoint(host: "monitor-pc", port: 48_621)
        )
        XCTAssertEqual(
            try PeerEndpoint.parse("http://100.64.0.2"),
            PeerEndpoint(host: "100.64.0.2", port: 48_621)
        )
        XCTAssertThrowsError(try PeerEndpoint.parse("https://monitor-pc"))
        XCTAssertThrowsError(try PeerEndpoint.parse("http://user:password@monitor-pc"))
        XCTAssertThrowsError(try PeerEndpoint.parse("http://monitor-pc/private"))
    }

    func testPeerHTTPServerAndClientRoundTripOnLoopback() async throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try Data(contentsOf: projectDirectory.appendingPathComponent("../../docs/examples/status-v1.json").standardizedFileURL)
        let secret = try XCTUnwrap(Data(base64URLString: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"))
        let payloadBox = PeerPayloadBox()
        payloadBox.set(fixture)
        let server = PeerHTTPServer(port: 49_621, secret: secret, payloadBox: payloadBox) { _ in }
        try server.start()
        defer { server.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)

        let payload = try await PeerHTTPClient.fetch(
            endpoint: PeerEndpoint(host: "127.0.0.1", port: 49_621),
            deviceID: "76848ab5-f9de-41cb-aa10-d9588b53ef53",
            secret: secret
        )

        XCTAssertEqual(payload.sequence, 42)
        XCTAssertEqual(payload.device.platform, "macos")
        XCTAssertEqual(payload.metrics.thermal.storageCelsius, 42)
    }

    @MainActor
    func testPeerStoreDoesNotDuplicateTrendForSameSequence() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let projectDirectory = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let fixtureURL = projectDirectory.appendingPathComponent("../../docs/examples/status-v1.json").standardizedFileURL
        let payload = try JSONDecoder().decode(PeerStatusPayload.self, from: Data(contentsOf: fixtureURL))
        let store = PeerStatusStore()

        store.beginConnecting(at: Date(timeIntervalSince1970: 1_000))
        store.apply(payload, receivedAt: Date(timeIntervalSince1970: 1_001))
        store.apply(payload, receivedAt: Date(timeIntervalSince1970: 1_006))

        XCTAssertEqual(store.cpuTrend.count, 1)
        XCTAssertEqual(store.memoryTrend.count, 1)
        XCTAssertEqual(store.storageTrend.count, 1)
        XCTAssertEqual(store.state, .online)
    }

    @MainActor
    func testMonitorStoreDoesNotChartStaleOrDuplicateNetworkSamples() {
        let firstDate = Date(timeIntervalSince1970: 4_000)
        var fresh = SystemSnapshot.initial
        fresh.capturedAt = firstDate
        fresh.network = NetworkReading(
            uploadBytesPerSecond: 100,
            downloadBytesPerSecond: 200,
            sessionUploadBytes: 100,
            sessionDownloadBytes: 200,
            wifi: nil,
            capturedAt: firstDate,
            isStale: false
        )

        let store = MonitorStore()
        store.apply(fresh)
        store.apply(fresh)
        XCTAssertEqual(store.uploadTrend.count, 1)
        XCTAssertEqual(store.downloadTrend.count, 1)

        var stale = fresh
        stale.capturedAt = firstDate.addingTimeInterval(1)
        stale.network.isStale = true
        store.apply(stale)
        XCTAssertEqual(store.uploadTrend.count, 1)
        XCTAssertEqual(store.downloadTrend.count, 1)

        var next = fresh
        next.capturedAt = firstDate.addingTimeInterval(2)
        next.network.capturedAt = next.capturedAt
        store.apply(next)
        XCTAssertEqual(store.uploadTrend.count, 2)
        XCTAssertEqual(store.downloadTrend.count, 2)
    }

    private func thermal(
        state: ThermalState,
        soc: Double? = nil,
        hottest: Double? = nil,
        ssd: Double? = nil
    ) -> ThermalReading {
        ThermalReading(
            state: state,
            socCelsius: soc,
            hottestSoCCelsius: hottest,
            ssdCelsius: ssd,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
    }
}
