import Foundation
import Testing
@testable import NoemaLLamaServer

// Native GGUF → .noema-paged converter (noema_paged_convert). The Python
// scripts/make_paged_package.py is the format authority: for every fixture the
// native converter must reproduce resident.gguf and experts-*.bin byte for
// byte and a semantically identical manifest (createdBy.tool differs).
// No server is started here, so these tests stay outside
// ServerStartSerializedTests.

@_silgen_name("noema_paged_validate_package_for_test")
private func noema_paged_validate_package_for_test(
    _ manifestPath: UnsafePointer<CChar>?
) -> UnsafePointer<CChar>?

private final class ConvertProbe {
    var stages: [String] = []
    var fractions: [Float] = []
    var cancelImmediately = false
}

private func runConvert(
    source: String,
    destination: String,
    alignment: Int32 = 0,
    probe: ConvertProbe = ConvertProbe()
) -> (code: Int32, error: String) {
    withExtendedLifetime(probe) {
        var error: UnsafePointer<CChar>? = nil
        let userData = Unmanaged.passUnretained(probe).toOpaque()
        let code = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                noema_paged_convert(sourcePointer, destinationPointer, alignment, { fraction, stage, userData in
                    let probe = Unmanaged<ConvertProbe>.fromOpaque(userData!).takeUnretainedValue()
                    if let stage {
                        let name = String(cString: stage)
                        if probe.stages.last != name {
                            probe.stages.append(name)
                        }
                    }
                    probe.fractions.append(fraction)
                    return probe.cancelImmediately ? 1 : 0
                }, userData, &error)
            }
        }
        return (code, error.map { String(cString: $0) } ?? "")
    }
}

private func makeScratchDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("noema-paged-convert-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Manifest comparison ignoring createdBy (tool/toolVersion legitimately
/// differ between the Python and native converters).
private func manifestJSON(at url: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: url)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func pagedConvertReproducesPythonPackagesByteForByte() throws {
    let fixtures = OverfitFixture.locateAll()
    try #require(!fixtures.isEmpty, "no .models/fixtures paged fixture pairs found")

    for fixture in fixtures {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let destination = scratch.appendingPathComponent("\(fixture.name).noema-paged")

        let probe = ConvertProbe()
        let result = runConvert(
            source: fixture.modelPath,
            destination: destination.path,
            probe: probe
        )
        #expect(result.code == 0, "\(fixture.name): \(result.error)")
        #expect(result.error.isEmpty)

        // Progress: canonical stage order, monotonic fractions ending at 1.
        #expect(probe.stages == ["preparing", "resident", "experts", "verifying", "finishing"])
        #expect(probe.fractions == probe.fractions.sorted())
        #expect(probe.fractions.last == 1.0)

        // Byte identity against the Python-built package.
        let pythonPackage = URL(fileURLWithPath: fixture.manifestPath).deletingLastPathComponent()
        for file in ["resident.gguf", "experts-000.bin"] {
            let nativeData = try Data(contentsOf: destination.appendingPathComponent(file))
            let pythonData = try Data(contentsOf: pythonPackage.appendingPathComponent(file))
            #expect(nativeData == pythonData, "\(fixture.name)/\(file) differs from the Python build")
        }

        // Manifest: semantically identical (createdBy.tool may differ).
        var nativeManifest = try manifestJSON(at: destination.appendingPathComponent("manifest.json"))
        var pythonManifest = try manifestJSON(at: pythonPackage.appendingPathComponent("manifest.json"))
        let nativeCreatedBy = try #require(nativeManifest.removeValue(forKey: "createdBy") as? [String: Any])
        pythonManifest.removeValue(forKey: "createdBy")
        #expect(nativeCreatedBy["tool"] as? String == "noema_paged_convert")
        #expect(nativeCreatedBy["nativeContractVersion"] as? Int == 4)
        #expect(NSDictionary(dictionary: nativeManifest) == NSDictionary(dictionary: pythonManifest),
                "\(fixture.name): manifest disagrees with the Python build")

        // The native fail-closed manifest validator must accept the package.
        let manifestPath = destination.appendingPathComponent("manifest.json").path
        let validation = manifestPath.withCString { noema_paged_validate_package_for_test($0) }
            .map { String(cString: $0) } ?? ""
        #expect(validation.isEmpty, "\(fixture.name): native validator rejected the package: \(validation)")

        // No staging residue next to the finished package.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        #expect(siblings == ["\(fixture.name).noema-paged"])
    }
}

@Test func pagedConvertCancelsCleanlyAndRemovesStaging() throws {
    let fixture = try #require(OverfitFixture.locate())
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let destination = scratch.appendingPathComponent("cancelled.noema-paged")

    let probe = ConvertProbe()
    probe.cancelImmediately = true
    let result = runConvert(source: fixture.modelPath, destination: destination.path, probe: probe)
    #expect(result.code == 2)
    #expect(result.error == "cancelled")

    // Neither the package nor any .building-<pid> staging directory survives.
    let residue = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
    #expect(residue.isEmpty, "cancellation left residue: \(residue)")
}

@Test func pagedConvertRefusesExistingOutput() throws {
    let fixture = try #require(OverfitFixture.locate())
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let destination = scratch.appendingPathComponent("existing.noema-paged")
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

    let result = runConvert(source: fixture.modelPath, destination: destination.path)
    #expect(result.code == 1)
    #expect(result.error.contains("output already exists"))
}

@Test func pagedConvertRefusesModelWithoutRoutedExperts() throws {
    // The fixture's own resident.gguf is a whitelisted-architecture GGUF with
    // every routed expert tensor stripped — exactly the refusal case.
    let fixture = try #require(OverfitFixture.locate())
    let scratch = try makeScratchDirectory()
    defer { try? FileManager.default.removeItem(at: scratch) }
    let destination = scratch.appendingPathComponent("dense.noema-paged")

    let result = runConvert(source: fixture.residentPath, destination: destination.path)
    #expect(result.code == 1)
    #expect(result.error.contains("no routed expert tensors"))
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}
