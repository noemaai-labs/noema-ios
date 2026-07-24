import Foundation
import XCTest
@testable import NoemaPackages

final class SafetensorsFileValidatorTests: XCTestCase {
    func testValidHeaderIsAccepted() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let header = Data(#"{"tensor":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}"#.utf8)
        try safetensorsData(declaredLength: UInt64(header.count), header: header).write(to: url)

        XCTAssertTrue(SafetensorsFileValidator.isValidFile(at: url))
    }

    func testTruncatedHeaderIsRejectedEvenWhenRemainderIsValidJSON() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try safetensorsData(declaredLength: 100, header: Data("{}".utf8)).write(to: url)

        XCTAssertFalse(SafetensorsFileValidator.isValidFile(at: url))
    }

    func testOverflowingHeaderLengthIsRejected() throws {
        let url = temporaryFileURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try safetensorsData(declaredLength: .max, header: Data()).write(to: url)

        XCTAssertFalse(SafetensorsFileValidator.isValidFile(at: url))
    }

    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".safetensors")
    }

    private func safetensorsData(declaredLength: UInt64, header: Data) -> Data {
        var data = Data()
        var littleEndianLength = declaredLength.littleEndian
        withUnsafeBytes(of: &littleEndianLength) { data.append(contentsOf: $0) }
        data.append(header)
        return data
    }
}
