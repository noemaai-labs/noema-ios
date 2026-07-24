import Foundation

public enum SafetensorsFileValidator {
    private static let maximumHeaderLength: UInt64 = 100_000_000

    public static func isValidFile(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let lengthData = try? handle.read(upToCount: 8), lengthData.count == 8 else {
            return false
        }

        let rawLength = lengthData.withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }
        let headerLength = UInt64(littleEndian: rawLength)
        guard headerLength > 0,
              headerLength <= maximumHeaderLength,
              let headerByteCount = Int(exactly: headerLength) else {
            return false
        }

        guard let headerData = try? handle.read(upToCount: headerByteCount),
              headerData.count == headerByteCount,
              let header = try? JSONSerialization.jsonObject(with: headerData),
              header is [String: Any] else {
            return false
        }

        return true
    }
}
