import Foundation
import XCTest
@testable import Noema

final class OverfitCanaryStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: OverfitCanaryStore!

    override func setUp() {
        super.setUp()
        suiteName = "overfit-canary-store-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = OverfitCanaryStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeRecord(
        fingerprint: String = "fp-abc",
        device: String = "iPhone17,1",
        volume: String = "volume-1",
        contractVersion: Int = 4,
        appBuild: String = "421"
    ) -> OverfitCanaryRecord {
        OverfitCanaryRecord(
            packageFingerprint: fingerprint,
            deviceModelIdentifier: device,
            volumeIdentifier: volume,
            nativeContractVersion: contractVersion,
            appBuild: appBuild,
            completedAt: Date(timeIntervalSince1970: 1_780_000_000),
            storageAlignedReadMBps: 2450.5,
            promptRate: 180.0,
            generationRate: 22.5,
            timeToFirstToken: 0.8,
            latency: OverfitLatencySample(
                p50Ms: 45, p95Ms: 90, p99Ms: 130, stallsPer128Tokens: 0, tokenCount: 63
            ),
            bankHitRate: 1.0,
            missesPerToken: 0,
            peakMemoryBytes: 3_100_000_000,
            thermalStateRaw: 0,
            classification: .pagedInteractive
        )
    }

    private func lookup(
        fingerprint: String = "fp-abc",
        device: String = "iPhone17,1",
        volume: String = "volume-1",
        contractVersion: Int = 4,
        appBuild: String = "421"
    ) -> OverfitCanaryRecord? {
        store.record(
            fingerprint: fingerprint,
            device: device,
            volume: volume,
            contractVersion: contractVersion,
            appBuild: appBuild
        )
    }

    func testSaveThenLookupRoundTrips() {
        let record = makeRecord()
        store.save(record)
        XCTAssertEqual(lookup(), record)
    }

    func testStoreKeyJoinsEveryIdentityDimension() {
        XCTAssertEqual(makeRecord().storeKey, "fp-abc|iPhone17,1|volume-1|4|421")
    }

    /// Any drift in the environment identity must miss: a canary measured on
    /// different hardware, storage, native contract, or app build says nothing
    /// about this launch.
    func testEachIdentityDimensionInvalidatesLookup() {
        store.save(makeRecord())
        XCTAssertNotNil(lookup())
        XCTAssertNil(lookup(fingerprint: "fp-other"))
        XCTAssertNil(lookup(device: "iPad16,3"))
        XCTAssertNil(lookup(volume: "volume-2"))
        XCTAssertNil(lookup(contractVersion: 5))
        XCTAssertNil(lookup(appBuild: "422"))
    }

    func testSaveOverwritesSameIdentity() {
        store.save(makeRecord())
        let updated = OverfitCanaryRecord(
            packageFingerprint: "fp-abc",
            deviceModelIdentifier: "iPhone17,1",
            volumeIdentifier: "volume-1",
            nativeContractVersion: 4,
            appBuild: "421",
            completedAt: Date(timeIntervalSince1970: 1_780_000_500),
            storageAlignedReadMBps: 1000,
            promptRate: 90,
            generationRate: 4.0,
            timeToFirstToken: 3.5,
            latency: nil,
            bankHitRate: 0.9,
            missesPerToken: 1.5,
            peakMemoryBytes: 4_000_000_000,
            thermalStateRaw: 2,
            classification: .pagedSlow
        )
        store.save(updated)
        XCTAssertEqual(lookup(), updated)
        XCTAssertEqual(lookup()?.classification, .pagedSlow)
    }

    func testRemoveAllForFingerprintDropsEveryVariant() {
        store.save(makeRecord())
        store.save(makeRecord(volume: "volume-2"))
        store.save(makeRecord(fingerprint: "fp-keep"))

        store.removeAll(fingerprint: "fp-abc")

        XCTAssertNil(lookup())
        XCTAssertNil(lookup(volume: "volume-2"))
        XCTAssertNotNil(lookup(fingerprint: "fp-keep"))
    }

    func testCorruptPersistedPayloadReadsAsEmpty() {
        defaults.set(Data("not json".utf8), forKey: "overfitCanaryResults.v2")
        XCTAssertNil(lookup())
        // And the store recovers by overwriting on the next save.
        store.save(makeRecord())
        XCTAssertNotNil(lookup())
    }
}
