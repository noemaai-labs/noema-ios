import Foundation
import XCTest
@testable import Noema

final class OverfitStorageCalibrationStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: OverfitStorageCalibrationStore!

    private let device = "iPhone17,1"
    private let volume = "volume-1"

    override func setUp() {
        super.setUp()
        suiteName = "overfit-storage-calibration-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = OverfitStorageCalibrationStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeRecord(
        nocacheMBps: Double,
        cachedMBps: Double?
    ) -> OverfitStorageCalibrationRecord {
        OverfitStorageCalibrationRecord(
            deviceModelIdentifier: device,
            volumeIdentifier: volume,
            alignedReadMBps: nocacheMBps,
            cachedReadMBps: cachedMBps,
            sampleBytes: 64 * 1024 * 1024,
            sampledAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
    }

    // MARK: - Round-trip

    func testRoundTripPreservesBothReadPathFields() {
        let record = makeRecord(nocacheMBps: 2450.5, cachedMBps: 1980.25)
        store.save(record)

        let loaded = store.record(device: device, volume: volume)
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded?.alignedReadMBps, 2450.5)
        XCTAssertEqual(loaded?.cachedReadMBps, 1980.25)

        // A second store over the same defaults sees the same bytes.
        let reopened = OverfitStorageCalibrationStore(defaults: defaults)
        XCTAssertEqual(reopened.record(device: device, volume: volume), record)
    }

    func testRoundTripWithoutCachedPassKeepsNilField() {
        let record = makeRecord(nocacheMBps: 1200, cachedMBps: nil)
        store.save(record)
        let loaded = store.record(device: device, volume: volume)
        XCTAssertEqual(loaded, record)
        XCTAssertNil(loaded?.cachedReadMBps)
    }

    // MARK: - Legacy record shape

    /// Records written before the dual-pass benchmark lack cachedReadMBps
    /// entirely. They must decode (alignedReadMBps was the F_NOCACHE number
    /// then too) instead of wiping the store.
    func testLegacyRecordShapeDecodesWithNilCachedField() throws {
        let key = OverfitStorageCalibrationRecord.key(device: device, volume: volume)
        // Numeric date: JSONDecoder's default strategy is deferredToDate
        // (seconds since the reference date), matching the store's coders.
        let legacyJSON = """
        {"\(key)":{"deviceModelIdentifier":"\(device)","volumeIdentifier":"\(volume)",\
        "alignedReadMBps":1234.5,"sampleBytes":67108864,"sampledAt":774000000}}
        """
        defaults.set(Data(legacyJSON.utf8), forKey: "overfitStorageCalibration.v1")

        let loaded = try XCTUnwrap(store.record(device: device, volume: volume))
        XCTAssertEqual(loaded.alignedReadMBps, 1234.5)
        XCTAssertNil(loaded.cachedReadMBps)
        XCTAssertEqual(loaded.sampleBytes, 67_108_864)

        // Legacy record alone can never justify the bypass: no cached pass,
        // no comparison, decision stays at the default (off).
        XCTAssertFalse(store.shouldUseNoCache(device: device, volume: volume))

        // Saving a dual record alongside keeps both decodable.
        let other = OverfitStorageCalibrationRecord(
            deviceModelIdentifier: device,
            volumeIdentifier: "volume-2",
            alignedReadMBps: 2000,
            cachedReadMBps: 1000,
            sampleBytes: 1,
            sampledAt: Date(timeIntervalSince1970: 1_780_000_100)
        )
        store.save(other)
        XCTAssertEqual(store.record(device: device, volume: volume)?.alignedReadMBps, 1234.5)
        XCTAssertEqual(store.record(device: device, volume: "volume-2"), other)
    }

    // MARK: - NOEMA_PAGED_NOCACHE decision hysteresis

    func testNoCacheDecisionDefaultsOffWithoutMeasurement() {
        XCTAssertFalse(store.shouldUseNoCache(device: device, volume: volume))
    }

    func testNoCacheDecisionEnablesOnlyAboveEnableRatio() {
        // 10% win: below the 15% enable threshold.
        store.save(makeRecord(nocacheMBps: 1100, cachedMBps: 1000))
        XCTAssertFalse(store.shouldUseNoCache(device: device, volume: volume))

        // 20% win: enables.
        store.save(makeRecord(nocacheMBps: 1200, cachedMBps: 1000))
        XCTAssertTrue(store.shouldUseNoCache(device: device, volume: volume))
    }

    func testNoCacheDecisionHysteresisNeverFlapsInTheBorderlineBand() {
        // Enable at a clear win…
        store.save(makeRecord(nocacheMBps: 1200, cachedMBps: 1000))
        XCTAssertTrue(store.shouldUseNoCache(device: device, volume: volume))

        // …then a borderline re-measurement (10% win — the band that would
        // flap without hysteresis) keeps it on…
        store.save(makeRecord(nocacheMBps: 1100, cachedMBps: 1000))
        XCTAssertTrue(store.shouldUseNoCache(device: device, volume: volume))

        // …exactly at the disable floor it still holds…
        store.save(makeRecord(nocacheMBps: 1050, cachedMBps: 1000))
        XCTAssertTrue(store.shouldUseNoCache(device: device, volume: volume))

        // …and only a clear loss of the advantage turns it off.
        store.save(makeRecord(nocacheMBps: 1000, cachedMBps: 1000))
        XCTAssertFalse(store.shouldUseNoCache(device: device, volume: volume))

        // Once off, the borderline band does not re-enable.
        store.save(makeRecord(nocacheMBps: 1100, cachedMBps: 1000))
        XCTAssertFalse(store.shouldUseNoCache(device: device, volume: volume))
    }

    func testNoCacheDecisionStickyAcrossStoreInstancesAndPartialData() {
        store.save(makeRecord(nocacheMBps: 1300, cachedMBps: 1000))
        XCTAssertTrue(store.shouldUseNoCache(device: device, volume: volume))

        // A fresh instance over the same defaults sees the persisted
        // decision, so the borderline band still cannot flap it.
        let reopened = OverfitStorageCalibrationStore(defaults: defaults)
        reopened.save(makeRecord(nocacheMBps: 1100, cachedMBps: 1000))
        XCTAssertTrue(reopened.shouldUseNoCache(device: device, volume: volume))

        // A record without a cached pass keeps the last decision instead of
        // re-deciding on partial data.
        reopened.save(makeRecord(nocacheMBps: 1100, cachedMBps: nil))
        XCTAssertTrue(reopened.shouldUseNoCache(device: device, volume: volume))
    }

    func testNoCacheDecisionIsPerVolume() {
        store.save(makeRecord(nocacheMBps: 1300, cachedMBps: 1000))
        XCTAssertTrue(store.shouldUseNoCache(device: device, volume: volume))
        XCTAssertFalse(store.shouldUseNoCache(device: device, volume: "volume-2"))
        XCTAssertFalse(store.shouldUseNoCache(device: "Mac16,1", volume: volume))
    }

    // MARK: - Microbenchmark passes

    func testDualSampleMeasuresBothPathsOverTheWholeFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-calib-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // 4 MiB of nonzero bytes: several 1 MiB chunks, so both passes take
        // multiple samples and the phase-shifted pass stays in range.
        try Data(repeating: 0xA7, count: 4 * 1024 * 1024).write(to: url)

        let dual = try OverfitStorageCalibrationStore.sampleAlignedReadDual(
            fileURL: url, sampleBytes: 4 * 1024 * 1024)
        XCTAssertGreaterThan(dual.nocache.megabytesPerSecond, 0)
        XCTAssertGreaterThan(dual.cached.megabytesPerSecond, 0)
        XCTAssertGreaterThan(dual.nocache.bytesRead, 0)
        XCTAssertGreaterThan(dual.cached.bytesRead, 0)
    }

    func testSampleAlignedReadPhaseShiftKeepsOffsetsInRange() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-calib-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        // Smaller than one benchmark chunk: single-sample edge case where a
        // shifted offset must clamp instead of reading past EOF.
        try Data(repeating: 0x5C, count: 256 * 1024).write(to: url)

        let sample = try OverfitStorageCalibrationStore.sampleAlignedRead(
            fileURL: url, bypassPageCache: false, offsetPhase: 0.5)
        XCTAssertEqual(sample.bytesRead, 256 * 1024)
    }
}
