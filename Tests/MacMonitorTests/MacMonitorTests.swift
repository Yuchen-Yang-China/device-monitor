import XCTest
@testable import MacMonitor

final class MacMonitorTests: XCTestCase {
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
