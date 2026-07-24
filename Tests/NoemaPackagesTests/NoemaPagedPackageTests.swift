import XCTest
@testable import NoemaPackages

final class NoemaPagedPackageTests: XCTestCase {

    // MARK: - XXH64 known answers (must match native + Python implementations)

    func testXXH64KnownAnswers() {
        XCTAssertEqual(PagedXXH64.hash(Data()), 0xEF46_DB37_51D8_E999)
        XCTAssertEqual(PagedXXH64.hash(Data("abc".utf8)), 0x44BC_2CF5_AD77_0999)
        // Exercises the 32-byte stripe loop plus every tail branch.
        let long = Data("Noema Overfit paged expert record checksum self-test vector.".utf8)
        XCTAssertEqual(PagedXXH64.hash(long), PagedXXH64.hash(long))
        XCTAssertNotEqual(PagedXXH64.hash(long), PagedXXH64.hash(long.dropLast()))
        XCTAssertNotEqual(PagedXXH64.hash(long, seed: 1), PagedXXH64.hash(long, seed: 2))
    }

    // MARK: - Fixture builder

    private struct Fixture {
        var directory: URL
        var manifest: NoemaPagedPackageManifest
        var payload: Data
    }

    /// Builds a small valid package: 2 MoE layers × 4 experts × 3 families,
    /// alignment 8, one payload file with deterministic bytes.
    private func makeValidFixture(
        mutateManifest: (inout NoemaPagedPackageManifest) -> Void = { _ in },
        mutatePayload: (inout Data) -> Void = { _ in }
    ) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-fixture-\(UUID().uuidString).noema-paged")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        let alignment: UInt64 = 8
        let recordLength: UInt64 = 24
        var payload = Data()
        var records: [NoemaPagedPackageManifest.Record] = []
        var offset: UInt64 = 0
        for layer in UInt32(0)..<2 {
            for family in [NoemaPagedPackageManifest.Family.gate, .up, .down] {
                for expert in UInt32(0)..<4 {
                    var chunk = Data(capacity: Int(recordLength))
                    for i in 0..<recordLength {
                        chunk.append(UInt8((UInt64(layer) &* 131 &+ UInt64(expert) &* 17 &+ i) & 0xFF))
                    }
                    let hash = PagedXXH64.hash(chunk)
                    records.append(.init(
                        layer: layer, family: family, expert: expert, file: 0,
                        offset: offset, length: recordLength,
                        xxh64: String(format: "%016llx", hash),
                        ggmlType: 0, ne: [4, 3]))
                    payload.append(chunk)
                    offset += recordLength
                }
            }
        }
        mutatePayload(&payload)

        let residentURL = dir.appendingPathComponent("resident.gguf")
        let residentData = Data("not a real gguf; structural tests only".utf8)
        try residentData.write(to: residentURL)

        let payloadURL = dir.appendingPathComponent("experts-000.bin")
        try payload.write(to: payloadURL)

        let residentSha = PagedSHA256.hexDigest(of: residentData)
        let payloadSha = PagedSHA256.hexDigest(of: payload)
        var manifest = NoemaPagedPackageManifest(
            formatVersion: 1,
            createdBy: .init(tool: "fixture", toolVersion: "1", nativeContractVersion: 3),
            source: .init(fileName: "source.gguf", ggufSizeBytes: 123, ggufSha256: "00"),
            model: .init(architecture: "qwen3moe", expertCount: 4, expertsUsedDefault: 2,
                         moeLayerCount: 2, totalLayerCount: 2, fusedGateUp: false),
            alignment: alignment,
            resident: .init(path: "resident.gguf", sizeBytes: UInt64(residentData.count), sha256: residentSha),
            expertFiles: [.init(path: "experts-000.bin", sizeBytes: UInt64(payload.count), sha256: payloadSha)],
            records: records,
            fingerprint: NoemaPagedPackageManifest.computeFingerprint(
                residentSha256: residentSha, expertFileSha256s: [payloadSha]))
        mutateManifest(&manifest)

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        return Fixture(directory: dir, manifest: manifest, payload: payload)
    }

    private func replaceManifest(_ fixture: Fixture, _ mutate: (inout NoemaPagedPackageManifest) -> Void) throws {
        var manifest = fixture.manifest
        mutate(&manifest)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: fixture.directory.appendingPathComponent("manifest.json"))
    }

    private func assertLoadFails(
        _ fixture: Fixture,
        _ check: (PagedPackageError) -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try NoemaPagedPackage.load(at: fixture.directory), file: file, line: line) { error in
            guard let paged = error as? PagedPackageError else {
                XCTFail("unexpected error type: \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(check(paged), "unexpected failure: \(paged)", file: file, line: line)
        }
    }

    // MARK: - Happy path

    func testValidPackageLoadsAndFullyValidates() throws {
        let fixture = try makeValidFixture()
        let package = try NoemaPagedPackage.load(at: fixture.directory)
        XCTAssertTrue(package.isArchitectureSupported)
        XCTAssertEqual(package.manifest.records.count, 2 * 3 * 4)
        try package.validate(level: .structural)
        try package.validate(level: .spotCheck)
        try package.validate(level: .full)
        XCTAssertEqual(package.residentGGUFURL.lastPathComponent, "resident.gguf")
        XCTAssertGreaterThan(package.totalSizeBytes, 0)
    }

    func testGemma4ArchitectureIsSupported() throws {
        let fixture = try makeValidFixture(mutateManifest: { manifest in
            manifest = self.withArchitecture(manifest, "gemma4")
        })
        let package = try NoemaPagedPackage.load(at: fixture.directory)
        XCTAssertTrue(package.isArchitectureSupported)
    }

    func testUnsupportedArchitectureLoadsButIsFlagged() throws {
        let fixture = try makeValidFixture(mutateManifest: { manifest in
            manifest = self.withArchitecture(manifest, "mixtral")
        })
        let package = try NoemaPagedPackage.load(at: fixture.directory)
        XCTAssertFalse(package.isArchitectureSupported)
    }

    private func withArchitecture(_ m: NoemaPagedPackageManifest, _ arch: String) -> NoemaPagedPackageManifest {
        NoemaPagedPackageManifest(
            formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
            model: .init(architecture: arch, expertCount: m.model.expertCount,
                         expertsUsedDefault: m.model.expertsUsedDefault,
                         moeLayerCount: m.model.moeLayerCount,
                         totalLayerCount: m.model.totalLayerCount,
                         fusedGateUp: m.model.fusedGateUp),
            alignment: m.alignment, resident: m.resident, expertFiles: m.expertFiles,
            records: m.records, fingerprint: m.fingerprint)
    }

    // MARK: - Fail-closed cases

    func testUnknownFormatVersionIsRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            m = NoemaPagedPackageManifest(
                formatVersion: 2, createdBy: m.createdBy, source: m.source, model: m.model,
                alignment: m.alignment, resident: m.resident, expertFiles: m.expertFiles,
                records: m.records, fingerprint: m.fingerprint)
        }
        var updated = fixture
        updated.manifest = try JSONDecoder().decode(
            NoemaPagedPackageManifest.self,
            from: Data(contentsOf: fixture.directory.appendingPathComponent("manifest.json")))
        assertLoadFails(updated) {
            if case .unsupportedFormatVersion(2) = $0 { return true }
            return false
        }
    }

    func testMissingManifestIsRejected() throws {
        let fixture = try makeValidFixture()
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("manifest.json"))
        assertLoadFails(fixture) { $0 == .manifestMissing }
    }

    func testTruncatedPayloadIsRejected() throws {
        let fixture = try makeValidFixture()
        let payloadURL = fixture.directory.appendingPathComponent("experts-000.bin")
        try fixture.payload.dropLast(4).write(to: payloadURL)
        assertLoadFails(fixture) {
            if case .fileSizeMismatch = $0 { return true }
            return false
        }
    }

    func testPayloadBitFlipFailsContentValidation() throws {
        let fixture = try makeValidFixture(mutatePayload: { payload in
            payload[payload.count / 2] ^= 0x01
        })
        // Structure is intact (sizes match), so load succeeds…
        let package = try NoemaPagedPackage.load(at: fixture.directory)
        // …but content verification catches the flip.
        XCTAssertThrowsError(try package.validate(level: .full)) { error in
            guard case .checksumMismatch = error as? PagedPackageError else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testOverlappingRecordsAreRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            var records = m.records
            let first = records[0]
            records[1] = .init(layer: first.layer, family: first.family, expert: 1,
                               file: first.file, offset: first.offset + 8,
                               length: first.length, xxh64: first.xxh64,
                               ggmlType: first.ggmlType, ne: first.ne)
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: m.model, alignment: m.alignment, resident: m.resident,
                expertFiles: m.expertFiles, records: records, fingerprint: m.fingerprint)
        }
        assertLoadFails(fixture) {
            if case .recordsOverlap = $0 { return true }
            if case .inconsistentFamilies = $0 { return true } // uniformity may trip first
            return false
        }
    }

    func testOutOfRangeOffsetIsRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            var records = m.records
            let last = records.removeLast()
            records.append(.init(layer: last.layer, family: last.family, expert: last.expert,
                                 file: last.file, offset: 1 << 40, length: last.length,
                                 xxh64: last.xxh64, ggmlType: last.ggmlType, ne: last.ne))
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: m.model, alignment: m.alignment, resident: m.resident,
                expertFiles: m.expertFiles, records: records, fingerprint: m.fingerprint)
        }
        assertLoadFails(fixture) {
            if case .recordOutOfBounds = $0 { return true }
            return false
        }
    }

    func testPathTraversalIsRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: m.model, alignment: m.alignment,
                resident: .init(path: "../evil.gguf", sizeBytes: m.resident.sizeBytes, sha256: m.resident.sha256),
                expertFiles: m.expertFiles, records: m.records, fingerprint: m.fingerprint)
        }
        assertLoadFails(fixture) {
            if case .unsafeFileName = $0 { return true }
            return false
        }
    }

    func testMissingExpertRecordIsRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: m.model, alignment: m.alignment, resident: m.resident,
                expertFiles: m.expertFiles, records: Array(m.records.dropLast()),
                fingerprint: m.fingerprint)
        }
        assertLoadFails(fixture) {
            if case .incompleteCoverage = $0 { return true }
            return false
        }
    }

    func testDuplicateRecordIsRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: m.model, alignment: m.alignment, resident: m.resident,
                expertFiles: m.expertFiles, records: m.records + [m.records[0]],
                fingerprint: m.fingerprint)
        }
        assertLoadFails(fixture) {
            if case .duplicateRecord = $0 { return true }
            return false
        }
    }

    func testFusedFlagMismatchIsRejected() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: .init(architecture: m.model.architecture, expertCount: m.model.expertCount,
                             expertsUsedDefault: m.model.expertsUsedDefault,
                             moeLayerCount: m.model.moeLayerCount,
                             totalLayerCount: m.model.totalLayerCount, fusedGateUp: true),
                alignment: m.alignment, resident: m.resident, expertFiles: m.expertFiles,
                records: m.records, fingerprint: m.fingerprint)
        }
        assertLoadFails(fixture) {
            if case .inconsistentFamilies = $0 { return true }
            return false
        }
    }

    func testFingerprintMismatchFailsFullValidation() throws {
        let fixture = try makeValidFixture()
        try replaceManifest(fixture) { m in
            m = NoemaPagedPackageManifest(
                formatVersion: m.formatVersion, createdBy: m.createdBy, source: m.source,
                model: m.model, alignment: m.alignment, resident: m.resident,
                expertFiles: m.expertFiles, records: m.records,
                fingerprint: String(repeating: "ab", count: 32))
        }
        let package = try NoemaPagedPackage.load(at: fixture.directory)
        XCTAssertThrowsError(try package.validate(level: .full)) { error in
            XCTAssertEqual(error as? PagedPackageError, .fingerprintMismatch)
        }
    }

    // MARK: - Atomic builder

    func testAtomicBuilderCommitsOnlyValidPackages() throws {
        let fixture = try makeValidFixture()
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-final-\(UUID().uuidString).noema-paged")
        addTeardownBlock { try? FileManager.default.removeItem(at: finalURL) }

        let builder = try AtomicPackageBuilder(finalURL: finalURL)
        for name in ["manifest.json", "resident.gguf", "experts-000.bin"] {
            try FileManager.default.copyItem(
                at: fixture.directory.appendingPathComponent(name),
                to: builder.stagedFileURL(for: name))
        }
        let committed = try builder.commit(validating: .full)
        XCTAssertEqual(committed.directoryURL.path, finalURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: builder.stagingURL.path))
    }

    func testAtomicBuilderNeverExposesInvalidPackage() throws {
        let finalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("overfit-final-\(UUID().uuidString).noema-paged")
        addTeardownBlock { try? FileManager.default.removeItem(at: finalURL) }

        let builder = try AtomicPackageBuilder(finalURL: finalURL)
        try Data("junk".utf8).write(to: builder.stagedFileURL(for: "manifest.json"))
        XCTAssertThrowsError(try builder.commit())
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        builder.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: builder.stagingURL.path))
    }
}
