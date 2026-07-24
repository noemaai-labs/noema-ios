import Foundation

/// Strictly decoded manifest of a `.noema-paged` package. Unlike Noema's
/// tolerant settings Codables, any missing or malformed field must fail the
/// decode: an unreadable manifest means an unusable package.
public struct NoemaPagedPackageManifest: Codable, Equatable, Sendable {
    public struct CreatedBy: Codable, Equatable, Sendable {
        public let tool: String
        public let toolVersion: String
        public let nativeContractVersion: Int

        public init(tool: String, toolVersion: String, nativeContractVersion: Int) {
            self.tool = tool
            self.toolVersion = toolVersion
            self.nativeContractVersion = nativeContractVersion
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let fileName: String
        public let ggufSizeBytes: UInt64
        public let ggufSha256: String

        public init(fileName: String, ggufSizeBytes: UInt64, ggufSha256: String) {
            self.fileName = fileName
            self.ggufSizeBytes = ggufSizeBytes
            self.ggufSha256 = ggufSha256
        }
    }

    public struct Model: Codable, Equatable, Sendable {
        public let architecture: String
        public let expertCount: UInt32
        public let expertsUsedDefault: UInt32
        public let moeLayerCount: UInt32
        public let totalLayerCount: UInt32
        public let fusedGateUp: Bool

        public init(architecture: String,
                    expertCount: UInt32,
                    expertsUsedDefault: UInt32,
                    moeLayerCount: UInt32,
                    totalLayerCount: UInt32,
                    fusedGateUp: Bool) {
            self.architecture = architecture
            self.expertCount = expertCount
            self.expertsUsedDefault = expertsUsedDefault
            self.moeLayerCount = moeLayerCount
            self.totalLayerCount = totalLayerCount
            self.fusedGateUp = fusedGateUp
        }
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        public let path: String
        public let sizeBytes: UInt64
        public let sha256: String

        public init(path: String, sizeBytes: UInt64, sha256: String) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.sha256 = sha256
        }
    }

    public enum Family: String, Codable, Equatable, Sendable, CaseIterable {
        case gate
        case up
        case down
        case gateUp = "gate_up"
    }

    public struct Record: Codable, Equatable, Sendable {
        public let layer: UInt32
        public let family: Family
        public let expert: UInt32
        public let file: UInt32
        public let offset: UInt64
        public let length: UInt64
        /// XXH64 of the record payload, lowercase hex (JSON numbers cannot
        /// carry 64-bit values losslessly).
        public let xxh64: String
        public let ggmlType: Int32
        /// Per-expert 2D slice dimensions.
        public let ne: [Int64]

        public init(layer: UInt32,
                    family: Family,
                    expert: UInt32,
                    file: UInt32,
                    offset: UInt64,
                    length: UInt64,
                    xxh64: String,
                    ggmlType: Int32,
                    ne: [Int64]) {
            self.layer = layer
            self.family = family
            self.expert = expert
            self.file = file
            self.offset = offset
            self.length = length
            self.xxh64 = xxh64
            self.ggmlType = ggmlType
            self.ne = ne
        }
    }

    public let formatVersion: Int
    public let createdBy: CreatedBy?
    public let source: Source
    public let model: Model
    public let alignment: UInt64
    public let resident: FileEntry
    public let expertFiles: [FileEntry]
    public let records: [Record]
    /// Package identity: SHA-256 (lowercase hex) over the resident file's
    /// sha256 followed by every expert file's sha256, joined by newlines.
    /// Content-derived and independently recomputable by the converter, the
    /// app, and tests.
    public let fingerprint: String

    public init(formatVersion: Int,
                createdBy: CreatedBy?,
                source: Source,
                model: Model,
                alignment: UInt64,
                resident: FileEntry,
                expertFiles: [FileEntry],
                records: [Record],
                fingerprint: String) {
        self.formatVersion = formatVersion
        self.createdBy = createdBy
        self.source = source
        self.model = model
        self.alignment = alignment
        self.resident = resident
        self.expertFiles = expertFiles
        self.records = records
        self.fingerprint = fingerprint
    }

    public static let currentFormatVersion = 1
    public static let manifestFileName = "manifest.json"
    public static let packageDirectoryExtension = "noema-paged"

    /// Recomputes the content-derived package fingerprint from file hashes.
    public static func computeFingerprint(residentSha256: String, expertFileSha256s: [String]) -> String {
        let joined = ([residentSha256] + expertFileSha256s).joined(separator: "\n")
        return PagedSHA256.hexDigest(of: Data(joined.utf8))
    }
}
