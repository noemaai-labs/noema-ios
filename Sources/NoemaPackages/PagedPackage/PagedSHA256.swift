import CryptoKit
import Foundation

/// SHA-256 helpers for `.noema-paged` install-time verification. Record-level
/// hot-path verification uses XXH64; SHA-256 covers whole files and the
/// package fingerprint.
public enum PagedSHA256 {
    public static func hexDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streams a file through SHA-256 in bounded chunks.
    public static func hexDigest(ofFileAt url: URL, chunkSize: Int = 4 * 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
