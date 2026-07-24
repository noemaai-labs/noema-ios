import Foundation
import NoemaPackages
import SwiftUI

public enum ModelFormat: String, CaseIterable, Hashable, Sendable {
    case gguf = "GGUF"
    case mlx = "MLX"
    case et  = "ET"
    case ane = "ANE"
    case afm = "AFM"
    case coreai = "CoreAI"
}

extension ModelFormat: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if let format = ModelFormat(compatibleRawValue: raw) {
            self = format
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported model format value: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ETBackend: String, Codable, CaseIterable, Hashable, Sendable {
    case xnnpack = "XNNPACK"
    case coreml = "CoreML"
    case mps = "MPS"
}

extension ETBackend {
    var displayName: String { rawValue }

    var tagGradient: LinearGradient {
        switch self {
        case .xnnpack:
            return LinearGradient(colors: [Color.indigo, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .coreml:
            return LinearGradient(colors: [Color.green, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .mps:
            return LinearGradient(colors: [Color.orange, Color.red], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var supportedOnCurrentDevice: Bool {
        switch self {
        case .xnnpack:
            return true
        case .coreml, .mps:
            return DeviceGPUInfo.supportsGPUOffload
        }
    }
}

struct MoEInfo: Codable, Hashable, Sendable {
    /// Indicates whether the model advertises mixture-of-experts metadata.
    var isMoE: Bool
    /// Total experts available in each MoE layer.
    var expertCount: Int
    /// Recommended number of experts to use per token, if provided by metadata.
    var defaultUsed: Int?
    /// Count of transformer blocks that contain MoE experts.
    var moeLayerCount: Int?
    /// Total transformer block count reported by the model.
    var totalLayerCount: Int?
    /// Reported hidden dimension (embedding length).
    var hiddenSize: Int?
    /// Reported feed-forward dimension.
    var feedForwardSize: Int?
    /// Reported vocabulary size.
    var vocabSize: Int?
    /// Number of attention heads (`*.attention.head_count`).
    var headCount: Int? = nil
    /// Number of key/value heads (`*.attention.head_count_kv`). Equals `headCount`
    /// for multi-head attention and is smaller for grouped-query attention (GQA);
    /// this is the term that actually drives KV-cache size.
    var headCountKV: Int? = nil
    /// Per-head key dimension (`*.attention.key_length`). When absent, head dim is
    /// derived as `hiddenSize / headCount`.
    var keyLength: Int? = nil
    /// Per-head value dimension (`*.attention.value_length`). When absent, falls back to `keyLength`.
    var valueLength: Int? = nil
    /// GGUF architecture identifier (`general.architecture`), when available.
    /// This lets memory planning distinguish dense attention from hybrid/recurrent stacks.
    var architecture: String? = nil
    /// Number of transformer blocks that allocate a conventional KV cache. Hybrid models
    /// such as Qwen3.5/3.6 use full attention in only part of the stack.
    var attentionLayerCount: Int? = nil
    /// Number of recurrent/linear-attention blocks that keep fixed-size state instead of
    /// a context-length-dependent KV cache.
    var recurrentLayerCount: Int? = nil
    /// Recurrent-state dimensions exposed by GGUF metadata.
    var ssmConvKernel: Int? = nil
    var ssmInnerSize: Int? = nil
    var ssmStateSize: Int? = nil
    var ssmGroupCount: Int? = nil
}

extension MoEInfo {
    /// Default metadata used when a scan fails. Treated as dense/unknown.
    static var denseFallback: MoEInfo {
        MoEInfo(
            isMoE: false,
            expertCount: 0,
            defaultUsed: nil,
            moeLayerCount: nil,
            totalLayerCount: nil,
            hiddenSize: nil,
            feedForwardSize: nil,
            vocabSize: nil
        )
    }
}

struct PagedModelCompatibility: Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        case supported
        case unsupportedArchitecture
        case noRoutedExperts
        case incompatibleSidecarScales
        case unknown
    }
    let status: Status
    let architecture: String?
    let routingWidthK: Int?          // experts used per token (MoEInfo.defaultUsed)
    let expertCount: Int?
    let moeLayerCount: Int?
    let bytesPerExpertPerLayer: UInt64?  // sum of per-expert slice bytes across families for one layer (uniform-layer assumption; use layer 0's families)
    let minBankBytes: UInt64?        // (K + 2) slots × bytesPerExpertPerLayer × moeLayerCount
}

extension PagedModelCompatibility {
    static func assess(moeInfo: MoEInfo?, inventory: GGUFMetadata.ExpertTensorInventory?) -> PagedModelCompatibility {
        let architecture = moeInfo?.architecture?.lowercased()
        guard let architecture, NoemaPagedPackage.supportedArchitectures.contains(architecture) else {
            return PagedModelCompatibility(
                status: .unsupportedArchitecture,
                architecture: architecture,
                routingWidthK: nil,
                expertCount: nil,
                moeLayerCount: nil,
                bytesPerExpertPerLayer: nil,
                minBankBytes: nil
            )
        }
        guard let inventory, !inventory.isEmpty else {
            return PagedModelCompatibility(
                status: .noRoutedExperts,
                architecture: architecture,
                routingWidthK: nil,
                expertCount: nil,
                moeLayerCount: nil,
                bytesPerExpertPerLayer: nil,
                minBankBytes: nil
            )
        }
        guard inventory.unsupportedSidecarCount == 0 else {
            return PagedModelCompatibility(
                status: .incompatibleSidecarScales,
                architecture: architecture,
                routingWidthK: nil,
                expertCount: nil,
                moeLayerCount: nil,
                bytesPerExpertPerLayer: nil,
                minBankBytes: nil
            )
        }

        let routingWidthK = moeInfo?.defaultUsed
        let moeLayerCount = Set(inventory.records.map(\.layer)).count

        // Some MoE stacks lead with dense blocks, so the lowest routed layer
        // stands in for "layer 0" of the uniform-layer assumption.
        let referenceLayer = inventory.records.map(\.layer).min()
        let referenceRecords = inventory.records.filter { $0.layer == referenceLayer }

        var expertCount = moeInfo.flatMap { $0.expertCount > 0 ? $0.expertCount : nil }
        if expertCount == nil,
           let dim = referenceRecords.first(where: { $0.ne.count >= 3 })?.ne[2],
           let value = Int(exactly: dim), value > 0 {
            expertCount = value
        }

        // nil (not a guess) when any family uses a quant type outside the local
        // table — the manifest is the authority for those later.
        let bytesPerExpertPerLayer: UInt64? = {
            var total: UInt64 = 0
            for record in referenceRecords {
                guard let bytes = perExpertSliceBytes(of: record) else { return nil }
                let (sum, overflow) = total.addingReportingOverflow(bytes)
                guard !overflow else { return nil }
                total = sum
            }
            return total > 0 ? total : nil
        }()

        let minBankBytes: UInt64? = {
            guard let bytes = bytesPerExpertPerLayer, let k = routingWidthK, k > 0, moeLayerCount > 0 else { return nil }
            let (perLayer, slotOverflow) = UInt64(k + 2).multipliedReportingOverflow(by: bytes)
            guard !slotOverflow else { return nil }
            let (bank, bankOverflow) = perLayer.multipliedReportingOverflow(by: UInt64(moeLayerCount))
            guard !bankOverflow else { return nil }
            return bank
        }()

        return PagedModelCompatibility(
            status: .supported,
            architecture: architecture,
            routingWidthK: routingWidthK,
            expertCount: expertCount,
            moeLayerCount: moeLayerCount,
            bytesPerExpertPerLayer: bytesPerExpertPerLayer,
            minBankBytes: minBankBytes
        )
    }

    private static func perExpertSliceBytes(of record: GGUFMetadata.ExpertTensorRecord) -> UInt64? {
        guard record.ne.count >= 2,
              record.ne[0] > 0, record.ne[1] > 0,
              let layout = ggmlBlockLayout(record.ggmlType) else { return nil }
        let ne0 = UInt64(record.ne[0])
        let ne1 = UInt64(record.ne[1])
        guard ne0 % layout.blockSize == 0 else { return nil }
        let rowBytes = ne0 / layout.blockSize * layout.typeSize
        let (slice, overflow) = rowBytes.multipliedReportingOverflow(by: ne1)
        return overflow ? nil : slice
    }

    /// (blockSize, typeSize) for the ggml tensor types the paged rewriter can size.
    private static func ggmlBlockLayout(_ type: Int32) -> (blockSize: UInt64, typeSize: UInt64)? {
        switch type {
        case 0: return (1, 4)      // F32
        case 1: return (1, 2)      // F16
        case 2: return (32, 18)    // Q4_0
        case 3: return (32, 20)    // Q4_1
        case 6: return (32, 22)    // Q5_0
        case 7: return (32, 24)    // Q5_1
        case 8: return (32, 34)    // Q8_0
        case 10: return (256, 84)  // Q2_K
        case 11: return (256, 110) // Q3_K
        case 12: return (256, 144) // Q4_K
        case 13: return (256, 176) // Q5_K
        case 14: return (256, 210) // Q6_K
        case 15: return (256, 292) // Q8_K
        case 20: return (32, 18)   // IQ4_NL
        case 23: return (256, 136) // IQ4_XS
        case 30: return (1, 2)     // BF16
        case 39: return (32, 17)   // MXFP4
        default: return nil
        }
    }
}

extension ModelFormat {
    /// CoreAI (Apple on-device foundation-model bundles) require iOS/macOS/visionOS 27+.
    /// The app is built against the 27 SDK, but the runtime can't load these on older
    /// OS versions, so CoreAI models must be hidden from users below 27 everywhere they
    /// could otherwise be browsed, listed, selected, or downloaded.
    static var isCoreAIRuntimeAvailable: Bool {
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return true
        }
        return false
    }

    var displayName: String {
        switch self {
        case .ane:
            return "CML"
        case .coreai:
            return "Core AI"
        default:
            return rawValue
        }
    }

    init?(compatibleRawValue raw: String) {
        switch raw.uppercased() {
        case "APPLE", "CML":
            self = .ane
        default:
            self.init(rawValue: raw)
        }
    }

    var tagGradient: LinearGradient {
        switch self {
        case .mlx:
            return LinearGradient(colors: [Color.orange, Color.pink], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .gguf:
            return LinearGradient(colors: [Color.blue, Color.purple], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .et:
            return LinearGradient(colors: [Color.cyan, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ane:
            return LinearGradient(colors: [Color.green, Color.teal], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .afm:
            return LinearGradient(colors: [Color.indigo, Color.blue], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .coreai:
            return LinearGradient(colors: [Color.purple, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// Attempts to infer the format from a model file URL.
    /// Unknown extensions default to GGUF for backwards compatibility with GGML.
    static func detect(from url: URL) -> ModelFormat {
        if url.scheme?.lowercased() == "afm" {
            return .afm
        }
        if url.scheme?.lowercased() == "coreai" {
            return .coreai
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "afm":
            return .afm
        case "aimodel", "aimodelc":
            return .coreai
        case "mlx":
            return .mlx
        case "bundle", "pte":
            return .et
        case "mlmodel", "mlpackage", "mlmodelc":
            return .ane
        case "gguf", "ggml", "bin":
            return .gguf
        default:
            return .gguf
        }
    }
}

public struct QuantInfo: Identifiable, Hashable, Codable, Sendable {
    public var id: String { label }

    public struct DownloadPart: Hashable, Codable, Sendable {
        public let path: String
        public let sizeBytes: Int64
        public let sha256: String?
        public let downloadURL: URL
    }

    public struct AuxiliaryFile: Hashable, Codable, Sendable {
        public let path: String
        public let sizeBytes: Int64
        public let sha256: String?
        public let downloadURL: URL
    }

    public let label: String
    public let format: ModelFormat
    public let sizeBytes: Int64
    public let downloadURL: URL
    public let sha256: String?
    /// Optional URL to a configuration JSON accompanying the model
    public let configURL: URL?
    /// Optional multipart metadata for split GGUFs. Nil means single-file quant.
    public let downloadParts: [DownloadPart]?
    /// Optional repo-advertised importance matrix (iMatrix) companion for IQ GGUF quants.
    public let importanceMatrix: AuxiliaryFile?
    /// Optional repo-advertised MTP draft-head companion for GGUF quants.
    public let mtp: AuxiliaryFile?

    public init(
        label: String,
        format: ModelFormat,
        sizeBytes: Int64,
        downloadURL: URL,
        sha256: String?,
        configURL: URL?,
        downloadParts: [DownloadPart]? = nil,
        importanceMatrix: AuxiliaryFile? = nil,
        mtp: AuxiliaryFile? = nil
    ) {
        self.label = label
        self.format = format
        self.sizeBytes = sizeBytes
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.configURL = configURL
        self.downloadParts = downloadParts
        self.importanceMatrix = importanceMatrix
        self.mtp = mtp
    }
}

extension QuantInfo {
    /// Relative directory that encloses a Hub-hosted `.noema-paged` package.
    /// The manifest is deliberately the primary download part, but discovery
    /// remains order-independent so hand-authored catalog entries are safe.
    var pagedPackageRelativeDirectory: String? {
        for part in allDownloadParts {
            let path = Self.relativeDownloadPath(path: part.path, fallbackURL: part.downloadURL)
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else { continue }
            for index in components.indices.dropLast()
            where components[index].lowercased().hasSuffix(".noema-paged") {
                return components[components.startIndex...index].map(String.init).joined(separator: "/")
            }
        }
        return nil
    }

    var pagedManifestDownloadPart: DownloadPart? {
        guard let root = pagedPackageRelativeDirectory else { return nil }
        let manifestPath = root + "/" + NoemaPagedPackageManifest.manifestFileName
        return allDownloadParts.first { part in
            Self.relativeDownloadPath(path: part.path, fallbackURL: part.downloadURL)
                .caseInsensitiveCompare(manifestPath) == .orderedSame
        }
    }

    var isPagedPackage: Bool {
        pagedManifestDownloadPart != nil
    }

    /// Model identity encoded by the enclosing `.noema-paged` directory.
    /// Paged Hub repositories are catalogs of model packages, not one model
    /// with a conventional quantization ladder.
    var pagedModelDisplayName: String? {
        guard let root = pagedPackageRelativeDirectory else { return nil }
        let directory = root.split(separator: "/").last.map(String.init) ?? root
        guard directory.lowercased().hasSuffix(".noema-paged") else { return nil }
        let stem = String(directory.dropLast(".noema-paged".count))
        guard let quant = pagedQuantDisplayLabel else { return stem }

        var suffixCandidates = [quant]
        if quant.uppercased().hasPrefix("UD_") {
            suffixCandidates.append("UD-" + String(quant.dropFirst(3)))
        }
        for candidate in suffixCandidates {
            let suffix = "-\(candidate)"
            if stem.lowercased().hasSuffix(suffix.lowercased()) {
                let modelName = String(stem.dropLast(suffix.count))
                if !modelName.isEmpty { return modelName }
            }
        }
        return stem
    }

    /// Quantization remains useful package metadata, but it is secondary to
    /// the model name for paged catalogs.
    var pagedQuantDisplayLabel: String? {
        guard isPagedPackage else { return nil }
        let component = label.components(separatedBy: " · ").first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return component?.isEmpty == false ? component : nil
    }

    private static func normalizedRelativePath(raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallback : trimmed
        let components = candidate
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .filter { component in
                component != "." && component != ".."
            }
            .map(String.init)
        if components.isEmpty {
            return fallback
        }
        return components.joined(separator: "/")
    }

    static func relativeDownloadPath(path: String, fallbackURL: URL) -> String {
        normalizedRelativePath(raw: path, fallback: fallbackURL.lastPathComponent)
    }

    var allRelativeDownloadPaths: [String] {
        allDownloadParts.map { part in
            Self.relativeDownloadPath(path: part.path, fallbackURL: part.downloadURL)
        }
    }

    var primaryDownloadRelativePath: String {
        if let first = allDownloadParts.first {
            return Self.relativeDownloadPath(path: first.path, fallbackURL: first.downloadURL)
        }
        return Self.relativeDownloadPath(path: downloadURL.lastPathComponent, fallbackURL: downloadURL)
    }

    var isMultipart: Bool {
        guard let downloadParts else { return false }
        return downloadParts.count > 1
    }

    var partCount: Int {
        if let downloadParts { return max(downloadParts.count, 1) }
        return 1
    }

    var allDownloadParts: [DownloadPart] {
        if let downloadParts, !downloadParts.isEmpty { return downloadParts }
        return [
            DownloadPart(
                path: downloadURL.lastPathComponent,
                sizeBytes: sizeBytes,
                sha256: sha256,
                downloadURL: downloadURL
            )
        ]
    }

    var primaryDownloadPart: DownloadPart {
        if let first = allDownloadParts.first { return first }
        return DownloadPart(
            path: downloadURL.lastPathComponent,
            sizeBytes: sizeBytes,
            sha256: sha256,
            downloadURL: downloadURL
        )
    }

    func copying(
        label: String? = nil,
        format: ModelFormat? = nil,
        sizeBytes: Int64? = nil,
        downloadURL: URL? = nil,
        sha256: String?? = nil,
        configURL: URL?? = nil,
        downloadParts: [DownloadPart]?? = nil,
        importanceMatrix: AuxiliaryFile?? = nil,
        mtp: AuxiliaryFile?? = nil
    ) -> QuantInfo {
        QuantInfo(
            label: label ?? self.label,
            format: format ?? self.format,
            sizeBytes: sizeBytes ?? self.sizeBytes,
            downloadURL: downloadURL ?? self.downloadURL,
            sha256: sha256 ?? self.sha256,
            configURL: configURL ?? self.configURL,
            downloadParts: downloadParts ?? self.downloadParts,
            importanceMatrix: importanceMatrix ?? self.importanceMatrix,
            mtp: mtp ?? self.mtp
        )
    }

    /// Attempts to infer the quantization bit-width from the label (e.g. Q4_K_M → 4, "MLX 4bit" → 4).
    var inferredBitWidth: Int? {
        if let range = label.range(of: #"(\d{1,2})(?:\s*bit)?"#, options: .regularExpression) {
            let digits = label[range].replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            if let value = Int(digits) {
                return value
            }
        }
        return nil
    }

    /// Returns true when the quant is at least Q3 (or equivalent, e.g. IQ4, 4bit, FP16).
    var isHighBitQuant: Bool {
        if let bits = inferredBitWidth {
            return bits >= 3
        }

        let lowered = label.lowercased()
        // If we could not infer bit-width, fall back to catching explicit low-bit tokens.
        let disallowedTokens = ["q1", "q2", "iq1", "iq2"]
        return !disallowedTokens.contains { lowered.contains($0) }
    }

    var isLowBitQuant: Bool {
        // Core AI repos publish verified per-platform bundles, not a bit-width
        // quality ladder — stem tokens like "hc0"/"int8v3" are not quant grades.
        if format == .coreai { return false }
        if let bits = inferredBitWidth {
            return bits <= 2
        }

        let lowered = label.lowercased()
        let lowBitTokens = ["q1", "q2", "iq1", "iq2"]
        return lowBitTokens.contains { lowered.contains($0) }
    }

    var isIQQuant: Bool {
        quantTypeDescriptor.family == .iq
    }

    var requiresImportanceMatrix: Bool {
        format == .gguf && isIQQuant && importanceMatrix != nil
    }

    struct QuantTypeDescriptor: Hashable, Sendable {
        enum Family: String, Hashable, Sendable {
            case fullPrecision
            case mxfp
            case iq
            case kQuant
            case legacy
            case q8_0
            case generic
        }

        let family: Family
        let isUD: Bool
        let nominalBits: Int?
        let tier: String?
        let chipLabel: String
        let title: String
        let body: String
    }

    var quantTypeDescriptor: QuantTypeDescriptor {
        if format == .coreai {
            return Self.coreAIQuantTypeDescriptor(label: label)
        }
        let upper = label.uppercased()
        let isUD = upper.hasPrefix("UD-") || upper.hasPrefix("UD_")
        let normalized: String = {
            guard isUD else { return upper }
            return String(upper.dropFirst(3))
        }()
        let bits = inferredBitWidth

        let isFullPrecision: Bool = {
            if normalized == "BF16" || normalized == "F16" || normalized == "FP16" || normalized == "F32" || normalized == "FP32" {
                return true
            }
            if let range = normalized.range(of: #"(?i)(?:^|_)(bf16|f16|fp16|f32|fp32)(?:_|$)"#, options: .regularExpression) {
                return !range.isEmpty
            }
            return false
        }()

        let isMXFP: Bool = {
            if normalized.hasPrefix("MXFP") { return true }
            if let range = normalized.range(of: #"(?i)(?:^|_)mxfp\d+(?:_|$)"#, options: .regularExpression) {
                return !range.isEmpty
            }
            return false
        }()

        let family: QuantTypeDescriptor.Family = {
            if isFullPrecision { return .fullPrecision }
            if isMXFP { return .mxfp }
            if normalized.hasPrefix("IQ"), normalized.dropFirst(2).first?.isNumber == true { return .iq }
            if normalized.hasPrefix("Q8_0") { return .q8_0 }
            if normalized.hasPrefix("Q"), normalized.contains("_K") { return .kQuant }
            if normalized.hasPrefix("Q"), (normalized.contains("_0") || normalized.contains("_1")) { return .legacy }
            return .generic
        }()

        let tier: String? = {
            let tokens = ["XXS", "XS", "XL", "NL", "S", "M", "L"]
            for token in tokens where normalized.contains("_\(token)") {
                return token
            }
            return nil
        }()

        let chipBase: String = {
            switch family {
            case .fullPrecision:
                return "Full Precision"
            case .mxfp:
                if let bits { return "MXFP\(bits)" }
                return "MXFP"
            case .iq: return "IQ"
            case .kQuant: return "K-Quant"
            case .legacy: return "Legacy"
            case .q8_0: return "Q8_0"
            case .generic:
                switch format {
                case .mlx:
                    if let bits { return "INT\(bits)" }
                    return "MLX"
                case .et: return "ET"
                case .ane: return "CML"
                case .afm: return "AFM"
                case .coreai: return "Core AI"
                case .gguf: return "Quant"
                }
            }
        }()

        let chipLabel = isUD ? "UD \(chipBase)" : chipBase

        let titleBase: String = {
            switch family {
            case .fullPrecision: return "Full Precision"
            case .mxfp: return "MXFP Quant"
            case .iq: return "IQ Quant"
            case .kQuant: return "K-Quant"
            case .legacy: return "Legacy Quant"
            case .q8_0: return "Q8_0 Quant"
            case .generic:
                switch format {
                case .mlx:
                    if let bits { return "MLX INT\(bits)" }
                    return "MLX Quant"
                case .afm:
                    return "AFM System Model"
                case .gguf: return "Quantization"
                default: return "\(format.displayName) Quant"
                }
            }
        }()

        var paragraphs: [String] = []

        switch family {
        case .fullPrecision:
            paragraphs.append("This file is full precision (for example BF16/FP16/FP32), not a low-bit quantized variant.")
            paragraphs.append("Expect higher memory and storage usage than quantized files, with quality closest to the source weights.")
        case .mxfp:
            paragraphs.append("MXFP files use mixed floating-point quantization (commonly MXFP4) designed for efficient inference with better quality retention than many integer low-bit schemes.")
            if let bits {
                paragraphs.append("This is nominally MXFP\(bits), so it targets lower memory usage than full precision while preserving more fidelity than very aggressive quants.")
            }
            if normalized.contains("_MOE") {
                paragraphs.append("The MOE suffix indicates a variant intended for mixture-of-experts architectures.")
            }
        case .iq:
            paragraphs.append("IQ quants are importance-aware GGUF quantizations that try to preserve quality better at very low bitrates (especially 2–3 bit).")
            if let bits {
                paragraphs.append("This is nominally a \(bits)-bit IQ quant, so it trades memory and speed for fidelity relative to higher-bit options.")
            }
            if let tier {
                paragraphs.append("The \(tier) suffix is a variant tier. Larger tiers usually keep more information and improve quality, with a larger file.")
            }
        case .kQuant:
            paragraphs.append("K-quants are modern GGUF quant formats that usually offer better quality-per-size than older _0/_1 quants at the same nominal bit width.")
            if let bits {
                paragraphs.append("This is nominally a \(bits)-bit K-quant. Higher bit widths typically improve quality and increase size.")
            }
            if let tier {
                paragraphs.append("The \(tier) suffix is a K-quant variant tier. S is usually smaller/faster, M is balanced, and L/XL tend to preserve more quality.")
            }
        case .legacy:
            paragraphs.append("This is a legacy GGUF quant family (_0/_1). These are still usable, but modern K-quants or IQ-quants are often better quality-per-size.")
            if normalized.contains("_1") {
                paragraphs.append("The _1 variant is a legacy refinement that can improve quality over _0, depending on the model.")
            } else if normalized.contains("_0") {
                paragraphs.append("The _0 variant is the simpler legacy scheme for this bit width.")
            }
        case .q8_0:
            paragraphs.append("Q8_0 is a legacy-style GGUF quant, but it is commonly used as a high-quality compressed option with behavior close to higher-precision weights.")
            paragraphs.append("It is larger than 4–6 bit quants, but often reduces quantization artifacts noticeably.")
        case .generic:
            if format == .mlx {
                if let bits {
                    paragraphs.append("This MLX variant uses INT\(bits) quantization.")
                    paragraphs.append("For MLX, the bit width is the key quality/speed indicator: lower INT bits are smaller/faster, higher INT bits preserve more quality.")
                } else {
                    paragraphs.append("This is an MLX quantized variant. For MLX builds, the INT bit width (for example INT4/INT8) is the main quality/speed signal.")
                }
            } else {
                paragraphs.append("This quant label does not match the common GGUF IQ / K-Quant / legacy naming families. It may be backend-specific or model-release-specific.")
                paragraphs.append("Treat speed and quality as empirical for this variant on your hardware/runtime.")
            }
        }

        if isUD {
            paragraphs.append("UD means Unsloth Dynamic quantization. It uses model-aware calibration and often improves quality-per-size versus a non-UD file with a similar nominal label.")
        }

        if family == .iq && importanceMatrix != nil {
            paragraphs.append("This repo advertises an importance matrix (iMatrix) companion for IQ quants. Noema downloads it alongside the weights so the intended IQ quantization is applied.")
        }

        paragraphs.append("Quant labels are conventions, not a universal standard across all backends. Exact quality and speed can vary by runtime and release.")

        return QuantTypeDescriptor(
            family: family,
            isUD: isUD,
            nominalBits: bits,
            tier: tier,
            chipLabel: chipLabel,
            title: isUD && !titleBase.hasPrefix("UD ") ? "UD \(titleBase)" : titleBase,
            body: paragraphs.joined(separator: "\n\n")
        )
    }

    /// Core AI repos publish one verified bundle per platform × compute unit
    /// rather than a quality ladder, so the chip names the target instead of a
    /// bit width and the explainer says which bundle fits this device.
    private static func coreAIQuantTypeDescriptor(label: String) -> QuantTypeDescriptor {
        guard let family = CoreAIBundleFamily.detect(from: label) else {
            return QuantTypeDescriptor(
                family: .generic,
                isUD: false,
                nominalBits: nil,
                tier: nil,
                chipLabel: "Core AI",
                title: "Core AI Bundle",
                body: "A Core AI .aimodel bundle. Published Core AI repos ship one verified bundle per platform and compute unit — when several variants are listed, pick the one matching your device."
            )
        }

        var paragraphs: [String] = [
            "Core AI repos publish one verified bundle per platform and compute unit instead of a quality ladder — the variants decode equivalently and differ in where they run and how fast. Pick by device, not by name."
        ]
        switch family {
        case .iosANE:
            paragraphs.append("This bundle prefers the Neural Engine on iPhone (GPU on a Mac) and is the most battery-friendly option. Temperature/top-k/top-p sampling fully applies. New prompt tokens are processed one per pass, but the chat history is cached across turns so only your newest message is processed each time. It is usually the same file content as the repo's Mac bundle.")
        case .macOSGPU:
            paragraphs.append("This bundle runs on the GPU with full temperature/top-k/top-p sampling. New prompt tokens are processed one per pass, but the chat history is cached across turns so only your newest message is processed each time. It is usually the same file content as the repo's iPhone Neural Engine bundle.")
        case .gpuPipelined:
            paragraphs.append("A decode-only graph for Apple's pipelined engine — the fastest generation speed, with temperature/top-k sampling. The trade-off: it re-processes the whole chat history one token per pass before every reply, so the wait before the first token grows as the conversation gets longer.")
        case .iosGPU:
            paragraphs.append("A static build with fused Metal kernels that picks the most likely token inside the graph. It runs on the GPU only and always decodes greedily — temperature/top-k/top-p settings don't apply. Prompts are processed in fast 16-token blocks via the bundled prefill companion, and the chat history is cached across turns, so replies start quickly even in long conversations. Recommended for chat on iPhone.")
        }

        return QuantTypeDescriptor(
            family: .generic,
            isUD: false,
            nominalBits: nil,
            tier: nil,
            chipLabel: family.displayName,
            title: "Core AI · \(family.displayName)",
            body: paragraphs.joined(separator: "\n\n")
        )
    }
}

/// Platform / compute-unit family of a Core AI `.aimodel` bundle, derived from
/// the repo's top-level folder, which the quant label keeps as its prefix
/// (e.g. "ios-ane/decode_int8"). Mirrors the published Core AI export layout
/// (one bundle per platform × compute unit, see coreai-model-zoo).
public enum CoreAIBundleFamily: String, CaseIterable, Sendable {
    case iosANE = "ios-ane"
    case iosGPU = "ios-gpu"
    case gpuPipelined = "gpu-pipelined"
    case macOSGPU = "macos"

    public static func detect(from label: String) -> CoreAIBundleFamily? {
        let lowered = label.lowercased()
        let head = lowered.split(separator: "/").first.map(String.init) ?? lowered
        return CoreAIBundleFamily(rawValue: head)
    }

    public var displayName: String {
        switch self {
        case .iosANE: return "iPhone · Neural Engine"
        case .iosGPU: return "iPhone · GPU"
        case .gpuPipelined: return "iPhone & Mac · GPU"
        case .macOSGPU: return "Mac · GPU"
        }
    }

    /// Preference order on the current platform; 0 sorts first and earns the
    /// "Recommended" badge. On iPhone the host-cache `ios-gpu` bundles win for
    /// chat: their chunked-prefill companion processes prompts in 16-token
    /// blocks (~147 vs ~27-45 tok/s) and their host-owned state caches the
    /// chat history across turns, so the time to first token stays flat as the
    /// conversation grows. Pipelined bundles decode fastest but re-process the
    /// full history one token per pass every message. On a Mac the GPU is fast
    /// enough that the pipelined engine's decode advantage dominates.
    public var sortRank: Int {
        #if os(macOS)
        switch self {
        case .gpuPipelined: return 0
        case .macOSGPU: return 1
        case .iosANE: return 2
        case .iosGPU: return 3
        }
        #else
        switch self {
        case .iosGPU: return 0
        case .gpuPipelined: return 1
        case .iosANE: return 2
        case .macOSGPU: return 3
        }
        #endif
    }

    public var isRecommendedOnThisDevice: Bool { sortRank == 0 }

    /// One-line note shown under the quant row.
    public var caption: String {
        switch self {
        case .iosANE:
            #if os(macOS)
            return "Usually identical to the Mac build"
            #else
            return "Battery-friendly; chat cached across turns"
            #endif
        case .macOSGPU:
            #if os(macOS)
            return "Full sampling on the GPU; chat cached across turns"
            #else
            return "Usually identical to the iPhone Neural Engine build"
            #endif
        case .gpuPipelined:
            return "Fastest decode; re-processes the chat each turn"
        case .iosGPU:
            return "Fast prompts, chat cached across turns; greedy decoding"
        }
    }
}

public struct ModelRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let publisher: String
    /// One line summary shown in lists and detail headers
    public let summary: String?
    public let parameterCountLabel: String?
    public let hasInstallableQuant: Bool
    public let formats: Set<ModelFormat>
    public let installed: Bool
    public let tags: [String]?
    public let pipeline_tag: String?
    public let minRAMBytes: Int64?
    /// Optional curated fit hints per runtime. Falls back to `minRAMBytes` when
    /// a format-specific estimate is unavailable.
    public let minRAMBytesByFormat: [ModelFormat: Int64]?
    public let recommendedETBackend: ETBackend?
    public let supportsVision: Bool

    public init(
        id: String,
        displayName: String,
        publisher: String,
        summary: String?,
        parameterCountLabel: String? = nil,
        hasInstallableQuant: Bool,
        formats: Set<ModelFormat>,
        installed: Bool,
        tags: [String]?,
        pipeline_tag: String?,
        minRAMBytes: Int64? = nil,
        minRAMBytesByFormat: [ModelFormat: Int64]? = nil,
        recommendedETBackend: ETBackend? = nil,
        supportsVision: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.publisher = publisher
        self.summary = summary
        self.parameterCountLabel = parameterCountLabel
        self.hasInstallableQuant = hasInstallableQuant
        self.formats = formats
        self.installed = installed
        self.tags = tags
        self.pipeline_tag = pipeline_tag
        self.minRAMBytes = minRAMBytes
        self.minRAMBytesByFormat = minRAMBytesByFormat
        self.recommendedETBackend = recommendedETBackend
        self.supportsVision = supportsVision
    }

    public func minimumRAMBytes(for format: ModelFormat?) -> Int64? {
        guard let format else { return minRAMBytes }
        return minRAMBytesByFormat?[format] ?? minRAMBytes
    }
}

public struct ModelDetails: Identifiable, Hashable, Codable, Equatable, Sendable {
    public let id: String
    /// Canonical one line summary for the model
    public let summary: String?
    public let parameterCountLabel: String?
    public let quants: [QuantInfo]
    public let promptTemplate: String?
    /// Optional conservative RAM requirement (bytes) for the lowest quant we ship for this model.
    /// Hidden/internal hint used to gate installs on devices with limited memory.
    public let minRAMBytes: Int64?

    public init(id: String,
                summary: String?,
                parameterCountLabel: String? = nil,
                quants: [QuantInfo],
                promptTemplate: String?,
                minRAMBytes: Int64? = nil) {
        self.id = id
        self.summary = summary
        self.parameterCountLabel = parameterCountLabel
        self.quants = quants
        self.promptTemplate = promptTemplate
        self.minRAMBytes = minRAMBytes
    }
}

extension ModelDetails {
    /// Returns true if this model is vision-capable according to cached Hub metadata
    /// or local GGUF heuristics (first available GGUF quant).
    var isVision: Bool {
        if let meta = HuggingFaceMetadataCache.cached(repoId: id), meta.isVision {
            return true
        }
        if ProjectorLocator.hasProjectorForModelID(id) {
            return true
        }
        return false
    }

    /// Returns true if the Hub metadata indicates a Mixture-of-Experts architecture.
    /// Detection rule: treat as MoE when `gguf.architecture` contains "moe" (case-insensitive).
    var isMoE: Bool {
        if let arch = HuggingFaceMetadataCache.cached(repoId: id)?.gguf?.architecture?.lowercased() {
            return arch.contains("moe")
        }
        return false
    }
}

enum ModelSource: String, Codable, CaseIterable, Hashable, Sendable {
    case huggingFace = "HF"
    case appleFoundation = "AFM"
}

/// Common metadata for any downloadable model entry.
protocol DownloadableModel: Identifiable {
    var id: String { get }
    var name: String { get }
    var sizeMB: Double { get }
    var minRAM: Int { get }
    var remoteURL: URL { get }
    var localPath: URL? { get }
    var about: String? { get }
    var format: ModelFormat { get }
    var source: ModelSource { get }
}

extension QuantInfo: DownloadableModel {
    var name: String { label }
    var sizeMB: Double { Double(sizeBytes) / 1_048_576.0 }
    var minRAM: Int { 0 }
    var remoteURL: URL { downloadURL }
    var localPath: URL? { nil }
    var about: String? { nil }
    var source: ModelSource {
        switch format {
        case .afm:
            return .appleFoundation
        case .gguf, .mlx, .et, .ane, .coreai:
            return .huggingFace
        }
    }
}

// MARK: - Dataset support

/// High-level category for curated Knowledge Packs. Used to group and badge
/// packs in Explore. `nil` on a record means it is an ordinary HF/OTL dataset,
/// not a curated pack.
public enum DatasetCategory: String, Codable, Sendable, Hashable, CaseIterable {
    case survival
    case medical
    case preparedness
    case travel
    case reference

    /// Localized, user-facing label.
    public var displayName: String {
        let locale = LocalizationManager.preferredLocale()
        switch self {
        case .survival: return String(localized: "Survival", locale: locale)
        case .medical: return String(localized: "First Aid & Medical", locale: locale)
        case .preparedness: return String(localized: "Preparedness", locale: locale)
        case .travel: return String(localized: "Travel", locale: locale)
        case .reference: return String(localized: "Reference", locale: locale)
        }
    }

    /// SF Symbol used on category headers and pack cards.
    public var systemImage: String {
        switch self {
        case .survival: return "tent"
        case .medical: return "cross.case"
        case .preparedness: return "shield.lefthalf.filled"
        case .travel: return "globe"
        case .reference: return "books.vertical"
        }
    }
}

/// Lightweight metadata used when listing available datasets.
public struct DatasetRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let publisher: String
    public let summary: String?
    public let installed: Bool
    /// Curated Knowledge Pack metadata. `nil` for ordinary HF/OTL records.
    public var category: DatasetCategory?
    /// Human-readable license label (e.g. "Public Domain (U.S. Gov)").
    public var license: String?
    /// Estimated chunk count once indexed; drives the on-device setup-time estimate.
    public var chunkCount: Int?
}

/// Represents a file that belongs to a dataset.
public struct DatasetFile: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let sizeBytes: Int64
    public let downloadURL: URL
}

/// Detailed metadata about a dataset including its file list.
public struct DatasetDetails: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let summary: String?
    public let files: [DatasetFile]
    /// Optional human-readable display name (e.g., OTL title). When present, it will be persisted alongside the dataset.
    public let displayName: String?
    /// Curated Knowledge Pack metadata (nil for ordinary HF/OTL details).
    public var category: DatasetCategory?
    public var license: String?
    public var attribution: String?
    public var chunkCount: Int?
    public var snapshotDate: String?
}

/// Installed dataset stored on disk.
struct LocalDataset: Identifiable, Hashable, Sendable {
    // Use stable identifier derived from datasetID to prevent List re-creation and scroll jumps
    var id: String { datasetID }
    let datasetID: String
    let name: String
    let url: URL
    /// Size of the dataset in megabytes.
    let sizeMB: Double
    let source: String
    let downloadDate: Date
    var lastUsedDate: Date?
    var isSelected: Bool = false
    var isIndexed: Bool = false
    var requiresReindex: Bool = false
    /// Index is valid and usable, but was built by an older RAG pipeline revision
    /// — re-embedding is recommended (not required) to pick up the improvements.
    var ragIndexOutdated: Bool = false
}

// MARK: - Dataset processing / indexing status (UI + pipeline)

/// Stages for dataset preparation and embedding.
public enum DatasetProcessingStage: String, Codable, Sendable {
    case extracting
    case compressing
    case embedding
    case completed
    case failed
}

/// Progress payload published while preparing a dataset.
public struct DatasetProcessingStatus: Codable, Sendable, Equatable {
    public let stage: DatasetProcessingStage
    /// 0.0 ... 1.0 where 1.0 means finished for the current stage
    public let progress: Double
    /// Optional human-readable status string for the UI
    public let message: String?
    /// Estimated seconds remaining for the current stage (if available)
    public let etaSeconds: Double?

    public init(stage: DatasetProcessingStage, progress: Double, message: String? = nil, etaSeconds: Double? = nil) {
        self.stage = stage
        self.progress = progress
        self.message = message
        self.etaSeconds = etaSeconds
    }
}
