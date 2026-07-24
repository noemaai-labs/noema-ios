import Foundation

enum GGUFMetadata {
    enum MTPCapability: Equatable {
        case unavailable
        case declaredButUnsupported
        case sidecarRequired
        case embeddedValidated
        case sidecarValidated(URL)
    }

    fileprivate struct MTPInspection {
        var architecture: String?
        var nextNLayers = 0
        var hiddenSize: Int?
        var vocabularySize: Int?
        var tokenizerFingerprint: UInt64?
        var tensorCounts: [String: Int] = [:]

        var hasRequiredTensors: Bool {
            guard nextNLayers > 0 else { return false }
            return ["nextn.eh_proj", "nextn.enorm", "nextn.hnorm"].allSatisfy {
                tensorCounts[$0, default: 0] >= nextNLayers
            }
        }
    }

    struct ExpertTensorRecord: Codable, Hashable, Sendable {
        let name: String
        let layer: Int
        let family: String   // "gate" | "up" | "down" | "gate_up"
        let ggmlType: Int32  // raw GGUF tensor type id
        let ne: [Int64]      // dims as stored (per-tensor, full 3D incl. expert dim)
        let offset: UInt64   // data offset relative to the tensor-data section
    }

    struct ExpertTensorInventory: Codable, Hashable, Sendable {
        let records: [ExpertTensorRecord]
        let tensorDataOffset: UInt64  // absolute file offset where tensor data begins
        /// Tiny per-expert `.scale` vectors remain resident and are gathered
        /// with real expert ids; `.input_scale` and `.bias` variants remain
        /// unsupported until their graph contracts are explicit.
        let residentExpertScaleCount: Int
        let unsupportedSidecarCount: Int
        var isEmpty: Bool { records.isEmpty }
    }

    private static let executableMTPArchitectures: Set<String> = [
        "qwen35", "qwen35moe", "cohere2moe", "hy_v3", "step35"
    ]

    fileprivate static func computeArchitectureInfo(at url: URL) -> (architecture: String, name: String?)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            if length < 0 { return false }
            return offset <= data.count - length
        }

        func skipBytes(_ length: Int) -> Bool {
            guard ensureCapacity(length) else { return false }
            offset += length
            return true
        }

        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: value)
        }

        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let sub = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: sub, encoding: .utf8)
        }

        func skipScalar(ofType type: UInt32) -> Bool {
            let size: Int
            switch type {
            case 0, 1, 7: size = 1
            case 2, 3: size = 2
            case 4, 5, 6: size = 4
            case 10, 11, 12: size = 8
            default: size = 0
            }
            guard size > 0 else { return false }
            return skipBytes(size)
        }

        func skipArray(elementType: UInt32, count: UInt64) -> Bool {
            if elementType == 8 {
                guard count <= UInt64(Int.max) else { return false }
                for _ in 0..<Int(count) {
                    guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                    guard skipBytes(len) else { return false }
                }
                return true
            }

            let elementSize: Int
            switch elementType {
            case 0, 1, 7: elementSize = 1
            case 2, 3: elementSize = 2
            case 4, 5, 6: elementSize = 4
            case 10, 11, 12: elementSize = 8
            default: elementSize = 4
            }
            guard elementSize > 0 else { return false }
            let maxElements = UInt64(Int.max) / UInt64(elementSize)
            guard count <= maxElements else { return false }
            return skipBytes(Int(count) * elementSize)
        }

        func architectureSpecificity(of string: String) -> Int {
            var score = string.count
            if string.contains("/") { score += 25 }
            if string.contains("-") { score += 10 }
            if string.rangeOfCharacter(from: .decimalDigits) != nil { score += 5 }
            return score
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil }
        guard readU64() != nil else { return nil }
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return nil }

        var architecture: String?
        var name: String?

        for _ in 0..<kvCount {
            guard let keyLen = readU64().flatMap({ Int(exactly: $0) }), let key = readString(len: keyLen) else { return nil }
            guard let type = readU32() else { return nil }

            switch type {
            case 8:
                guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
                guard let value = readString(len: len)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
                if key == "general.architecture", !value.isEmpty {
                    architecture = value
                } else if key == "general.name", !value.isEmpty {
                    name = value
                }
            case 9:
                guard let elemType = readU32(), let count = readU64() else { return nil }
                if key == "general.architectures", elemType == 8 {
                    guard count <= UInt64(Int.max) else { return nil }
                    var candidate: (value: String, score: Int)?
                    for _ in 0..<Int(count) {
                        guard let len = readU64().flatMap({ Int(exactly: $0) }), let value = readString(len: len) else { return nil }
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            let score = architectureSpecificity(of: trimmed)
                            if let current = candidate {
                                if score > current.score { candidate = (trimmed, score) }
                            } else {
                                candidate = (trimmed, score)
                            }
                        }
                    }
                    if let candidate {
                        if let current = architecture {
                            if candidate.score > architectureSpecificity(of: current) {
                                architecture = candidate.value
                            }
                        } else {
                            architecture = candidate.value
                        }
                    }
                } else {
                    guard skipArray(elementType: elemType, count: count) else { return nil }
                }
            default:
                guard skipScalar(ofType: type) else { return nil }
            }

            if architecture != nil && name != nil {
                break
            }
        }

        guard let architecture else { return nil }
        return (architecture, name)
    }

    fileprivate static func computeLayerCount(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            length >= 0 && offset <= data.count - length
        }

        func skipBytes(_ length: Int) -> Bool {
            guard ensureCapacity(length) else { return false }
            offset += length
            return true
        }

        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: value)
        }

        func readString(len: Int) -> String? {
            guard len >= 0, offset <= data.count - len else { return nil }
            let sub = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: sub, encoding: .utf8)
        }

        func skipValue(ofType type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:
                return skipBytes(1)
            case 2, 3:
                return skipBytes(2)
            case 4, 5, 6:
                return skipBytes(4)
            case 10, 11, 12:
                return skipBytes(8)
            case 8:
                guard let length = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                return skipBytes(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                if elementType == 8 {
                    guard count <= UInt64(Int.max) else { return false }
                    for _ in 0..<Int(count) {
                        guard let length = readU64().flatMap({ Int(exactly: $0) }),
                              skipBytes(length) else { return false }
                    }
                    return true
                }
                let elementSize: Int
                switch elementType {
                case 0, 1, 7: elementSize = 1
                case 2, 3: elementSize = 2
                case 4, 5, 6: elementSize = 4
                case 10, 11, 12: elementSize = 8
                default: return false
                }
                guard count <= UInt64(Int.max / elementSize),
                      let elementCount = Int(exactly: count) else { return false }
                return skipBytes(elementCount * elementSize)
            default:
                return false
            }
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil } // version
        guard readU64() != nil else { return nil } // tensor count
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
        for _ in 0..<kvCount {
            guard let klen = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
            guard let key = readString(len: klen) else { return nil }
            guard let type = readU32() else { return nil }
            switch type {
            case 4: // uint32
                guard let raw = readU32(), let val = Int(exactly: raw) else { return nil }
                if key.contains("block_count") || key.contains("n_layer") ||
                    key.contains("num_hidden_layers") || key.contains("layer_count") {
                    return val
                }
            case 10: // uint64
                guard let raw = readU64(), let val = Int(exactly: raw) else { return nil }
                if key.contains("block_count") || key.contains("n_layer") ||
                    key.contains("num_hidden_layers") || key.contains("layer_count") {
                    return val
                }
            default:
                guard skipValue(ofType: type) else { return nil }
            }
        }
        return nil
    }

    fileprivate static func computeContextLength(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            length >= 0 && offset <= data.count - length
        }

        func skipBytes(_ length: Int) -> Bool {
            guard ensureCapacity(length) else { return false }
            offset += length
            return true
        }

        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }
        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: value)
        }
        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let sub = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: sub, encoding: .utf8)
        }

        func skipValue(ofType type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:
                return skipBytes(1)
            case 2, 3:
                return skipBytes(2)
            case 4, 5, 6:
                return skipBytes(4)
            case 10, 11, 12:
                return skipBytes(8)
            case 8:
                guard let length = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                return skipBytes(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                if elementType == 8 {
                    guard count <= UInt64(Int.max) else { return false }
                    for _ in 0..<Int(count) {
                        guard let length = readU64().flatMap({ Int(exactly: $0) }),
                              skipBytes(length) else { return false }
                    }
                    return true
                }
                let elementSize: Int
                switch elementType {
                case 0, 1, 7: elementSize = 1
                case 2, 3: elementSize = 2
                case 4, 5, 6: elementSize = 4
                case 10, 11, 12: elementSize = 8
                default: return false
                }
                guard count <= UInt64(Int.max / elementSize),
                      let elementCount = Int(exactly: count) else { return false }
                return skipBytes(elementCount * elementSize)
            default:
                return false
            }
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil }
        guard readU64() != nil else { return nil }
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
        for _ in 0..<kvCount {
            guard let klen = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
            guard let key = readString(len: klen) else { return nil }
            guard let type = readU32() else { return nil }
            switch type {
            case 4:
                guard let raw = readU32(), let value = Int(exactly: raw) else { return nil }
                if key.contains("n_ctx") || key.contains("context_length") { return value }
            case 10:
                guard let raw = readU64(), let value = Int(exactly: raw) else { return nil }
                if key.contains("n_ctx") || key.contains("context_length") { return value }
            default:
                guard skipValue(ofType: type) else { return nil }
            }
        }
        return nil
    }

    /// Attention shape needed to size the KV cache exactly. Read with architecture-agnostic
    /// substring matching, so it works for `llama.*`, `qwen3.*`, `gemma.*`, etc. — unlike the
    /// C scanner, which only knows the `llama.` prefix.
    struct ArchAttentionFields {
        var architecture: String?
        var blockCount: Int?
        var embeddingLength: Int?
        var feedForwardLength: Int?
        var vocabSize: Int?
        var headCount: Int?
        var headCountKV: Int?
        var keyLength: Int?
        var valueLength: Int?
        var fullAttentionInterval: Int?
        var nextNPredictLayers: Int?
        var recurrentLayerCount: Int?
        var ssmConvKernel: Int?
        var ssmInnerSize: Int?
        var ssmStateSize: Int?
        var ssmGroupCount: Int?
    }

    /// Walk the GGUF KV header once and pull the attention-shape scalars used by the
    /// memory estimator. Returns `nil` only when the header can't be parsed at all.
    fileprivate static func computeAttentionFields(at url: URL) -> ArchAttentionFields? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool { length >= 0 && offset <= data.count - length }
        func skipBytes(_ length: Int) -> Bool {
            guard ensureCapacity(length) else { return false }
            offset += length
            return true
        }
        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }
        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: value)
        }
        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let sub = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: sub, encoding: .utf8)
        }
        func readU8() -> UInt8? {
            guard ensureCapacity(1) else { return nil }
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt8.self) }
            offset += 1
            return value
        }
        func readU16() -> UInt16? {
            guard ensureCapacity(2) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
            offset += 2
            return UInt16(littleEndian: value)
        }
        /// Reads a scalar integer value, fully consuming the bytes. Returns nil (without
        /// consuming) for non-integer scalar types so the caller can skip them.
        func readScalarInt(ofType type: UInt32) -> Int? {
            switch type {
            case 0: return readU8().map { Int($0) }                       // uint8
            case 1: return readU8().map { Int(Int8(bitPattern: $0)) }     // int8
            case 7: return readU8().map { $0 == 0 ? 0 : 1 }               // bool
            case 2: return readU16().map { Int($0) }                      // uint16
            case 3: return readU16().map { Int(Int16(bitPattern: $0)) }   // int16
            case 4: return readU32().flatMap { Int(exactly: $0) }         // uint32
            case 5: return readU32().map { Int(Int32(bitPattern: $0)) }   // int32
            case 10: return readU64().flatMap { Int(exactly: $0) }        // uint64
            case 11: return readU64().map { Int(Int64(bitPattern: $0)) }  // int64
            default: return nil
            }
        }
        func skipValue(ofType type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7: return skipBytes(1)
            case 2, 3: return skipBytes(2)
            case 4, 5, 6: return skipBytes(4)
            case 10, 11, 12: return skipBytes(8)
            case 8:
                guard let length = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                return skipBytes(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                if elementType == 8 {
                    guard count <= UInt64(Int.max) else { return false }
                    for _ in 0..<Int(count) {
                        guard let length = readU64().flatMap({ Int(exactly: $0) }), skipBytes(length) else { return false }
                    }
                    return true
                }
                let elementSize: Int
                switch elementType {
                case 0, 1, 7: elementSize = 1
                case 2, 3: elementSize = 2
                case 4, 5, 6: elementSize = 4
                case 10, 11, 12: elementSize = 8
                default: return false
                }
                guard count <= UInt64(Int.max / elementSize), let elementCount = Int(exactly: count) else { return false }
                return skipBytes(elementCount * elementSize)
            default:
                return false
            }
        }
        /// For `head_count_kv`, which some hybrid architectures store as a per-layer array:
        /// take the max element (conservative — sizes the cache to the widest layer).
        func readArrayMaxInt(elementType: UInt32, count: UInt64) -> Int? {
            guard elementType != 8, elementType != 9, count <= UInt64(Int.max) else { return nil }
            var maxValue: Int?
            for _ in 0..<Int(count) {
                guard let value = readScalarInt(ofType: elementType) else { return nil }
                if maxValue == nil || value > maxValue! { maxValue = value }
            }
            return maxValue
        }
        func readArrayPositiveCount(elementType: UInt32, count: UInt64) -> Int? {
            guard elementType != 8, elementType != 9, count <= UInt64(Int.max) else { return nil }
            var positiveCount = 0
            for _ in 0..<Int(count) {
                guard let value = readScalarInt(ofType: elementType) else { return nil }
                if value > 0 { positiveCount += 1 }
            }
            return positiveCount
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil }      // version
        guard readU64() != nil else { return nil }      // tensor count
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return nil }

        var fields = ArchAttentionFields()
        for _ in 0..<kvCount {
            guard let klen = readU64().flatMap({ Int(exactly: $0) }), let key = readString(len: klen), let type = readU32() else { return nil }
            let lower = key.lowercased()
            var consumed = false

            // Skip vision/audio/projector sub-towers so their attention shape can't be mistaken
            // for the text model's. Their keys carry these markers (e.g. "clip.vision.*").
            let isAuxModule = lower.contains("vision") || lower.contains("clip") ||
                lower.contains("audio") || lower.contains("mm_") || lower.contains("projector")

            if isAuxModule {
                guard skipValue(ofType: type) else { return nil }
                continue
            }

            if lower == "general.architecture", type == 8 {
                if let length = readU64().flatMap({ Int(exactly: $0) }),
                   let value = readString(len: length), !value.isEmpty {
                    fields.architecture = value.lowercased()
                    consumed = true
                }
            } else if lower.contains(".attention.recurrent_layers"), type == 9 {
                guard let elem = readU32(), let count = readU64() else { return nil }
                guard let value = readArrayPositiveCount(elementType: elem, count: count) else { return fields }
                fields.recurrentLayerCount = value
                consumed = true
            } else if lower.contains(".full_attention_interval") {
                if let value = readScalarInt(ofType: type), value > 0 {
                    fields.fullAttentionInterval = value
                    consumed = true
                }
            } else if lower.contains(".nextn_predict_layers") {
                if let value = readScalarInt(ofType: type), value > 0 {
                    fields.nextNPredictLayers = value
                    consumed = true
                }
            } else if lower.contains(".ssm.conv_kernel") {
                if let value = readScalarInt(ofType: type), value > 0 { fields.ssmConvKernel = value; consumed = true }
            } else if lower.contains(".ssm.inner_size") {
                if let value = readScalarInt(ofType: type), value > 0 { fields.ssmInnerSize = value; consumed = true }
            } else if lower.contains(".ssm.state_size") {
                if let value = readScalarInt(ofType: type), value > 0 { fields.ssmStateSize = value; consumed = true }
            } else if lower.contains(".ssm.group_count") {
                if let value = readScalarInt(ofType: type), value > 0 { fields.ssmGroupCount = value; consumed = true }
            } else if lower.contains(".attention.head_count_kv") {
                // head_count_kv may be a per-layer array; take the widest.
                if type == 9 {
                    guard let elem = readU32(), let count = readU64() else { return nil }
                    // The array element + count headers are now consumed. If the body can't be
                    // read (non-integer element type), the reader is desynced — stop and return
                    // whatever fields were gathered before this key rather than misreading on.
                    guard let v = readArrayMaxInt(elementType: elem, count: count) else { return fields }
                    if v > 0 { fields.headCountKV = v }
                    consumed = true
                } else if let v = readScalarInt(ofType: type), v > 0 {
                    fields.headCountKV = v
                    consumed = true
                }
            } else if lower.contains(".attention.head_count") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.headCount = v; consumed = true }
            } else if lower.contains(".attention.key_length") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.keyLength = v; consumed = true }
            } else if lower.contains(".attention.value_length") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.valueLength = v; consumed = true }
            } else if lower.contains(".embedding_length") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.embeddingLength = v; consumed = true }
            } else if lower.contains(".feed_forward_length") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.feedForwardLength = v; consumed = true }
            } else if lower.contains(".vocab_size") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.vocabSize = v; consumed = true }
            } else if lower.contains("block_count") || lower.contains("n_layer") || lower.contains("num_hidden_layers") {
                if let v = readScalarInt(ofType: type), v > 0 { fields.blockCount = v; consumed = true }
            }

            if !consumed {
                guard skipValue(ofType: type) else { return nil }
            }
        }
        return fields
    }

    private static func applying(_ attention: ArchAttentionFields, to info: MoEInfo) -> MoEInfo {
        var merged = info
        if merged.totalLayerCount == nil { merged.totalLayerCount = attention.blockCount }
        if merged.hiddenSize == nil { merged.hiddenSize = attention.embeddingLength }
        if merged.feedForwardSize == nil { merged.feedForwardSize = attention.feedForwardLength }
        if merged.vocabSize == nil { merged.vocabSize = attention.vocabSize }
        merged.headCount = attention.headCount
        merged.headCountKV = attention.headCountKV
        merged.keyLength = attention.keyLength
        merged.valueLength = attention.valueLength
        merged.architecture = attention.architecture
        merged.ssmConvKernel = attention.ssmConvKernel
        merged.ssmInnerSize = attention.ssmInnerSize
        merged.ssmStateSize = attention.ssmStateSize
        merged.ssmGroupCount = attention.ssmGroupCount

        let layers = merged.totalLayerCount ?? attention.blockCount
        let recurrentLayers: Int? = {
            if let explicit = attention.recurrentLayerCount { return explicit }
            guard let layers, let interval = attention.fullAttentionInterval, interval > 0 else { return nil }
            // NextN/MTP blocks are appended after the main Qwen trunk and are always
            // dense-attention blocks. Apply the interval only to the trunk.
            let trunkLayers = max(0, layers - (attention.nextNPredictLayers ?? 0))
            return max(0, trunkLayers - (trunkLayers / interval))
        }()
        merged.recurrentLayerCount = recurrentLayers
        if let layers, let recurrentLayers {
            merged.attentionLayerCount = max(0, layers - recurrentLayers)
        }
        return merged
    }

    fileprivate static func computeMoeInfo(at url: URL) -> MoEInfo? {
        var target = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
            if let fallback = try? FileManager.default
                .contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                target = fallback
            }
        }

        // Architecture-agnostic attention shape, overlaid onto whichever MoE scan succeeds.
        let attention = computeAttentionFields(at: target)

        var scan = gguf_moe_scan_result()
        let status = target.path.withCString { gguf_moe_scan($0, &scan) }
        if status == 0 && scan.status == 0 {
            let expertCount = max(Int(scan.expert_count), 0)
            let defaultUsed = scan.expert_used_count > 0 ? Int(scan.expert_used_count) : nil
            let moeLayers = scan.moe_layer_count > 0 ? Int(scan.moe_layer_count) : nil
            let totalLayers = scan.total_layer_count > 0 ? Int(scan.total_layer_count) : nil
            let hidden = scan.hidden_size > 0 ? Int(scan.hidden_size) : nil
            let feedForward = scan.feed_forward_size > 0 ? Int(scan.feed_forward_size) : nil
            let vocab = scan.vocab_size > 0 ? Int(scan.vocab_size) : nil
            let isMoE = scan.is_moe != 0 || scan.expert_count > 0 || scan.expert_used_count > 0 || scan.moe_layer_count > 0

            let base = MoEInfo(
                isMoE: isMoE,
                expertCount: expertCount,
                defaultUsed: defaultUsed,
                moeLayerCount: moeLayers,
                totalLayerCount: totalLayers,
                hiddenSize: hidden,
                feedForwardSize: feedForward,
                vocabSize: vocab
            )
            return attention.map { applying($0, to: base) } ?? base
        }

        if let fallback = fallbackMoEInfo(at: target) {
            print("[MoEDetect] using Swift fallback scanner for \(target.lastPathComponent)")
            return attention.map { applying($0, to: fallback) } ?? fallback
        }

        // No MoE scan succeeded, but if we recovered the attention shape we can still
        // surface a dense descriptor so the memory estimator gets exact KV-cache sizing.
        if let attention {
            return applying(attention, to: .denseFallback)
        }

        print("[MoEDetect] MoE scan failed for \(target.lastPathComponent)")
        return nil
    }

    private static func fallbackMoEInfo(at url: URL) -> MoEInfo? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            if length < 0 { return false }
            return offset <= data.count - length
        }

        func readInteger<T: FixedWidthInteger>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard ensureCapacity(size) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
            offset += size
            return T(littleEndian: value)
        }

        func readU8() -> UInt8? { readInteger(UInt8.self) }
        func readU16() -> UInt16? { readInteger(UInt16.self) }
        func readU32() -> UInt32? { readInteger(UInt32.self) }
        func readU64() -> UInt64? { readInteger(UInt64.self) }

        func readF32() -> Float? {
            guard let bits = readU32() else { return nil }
            return Float(bitPattern: bits)
        }

        func readF64() -> Double? {
            guard let bits = readU64() else { return nil }
            return Double(bitPattern: bits)
        }

        func roundedInt(from value: Double) -> Int? {
            guard value.isFinite else { return nil }
            let rounded = value.rounded()
            guard rounded >= Double(Int.min), rounded <= Double(Int.max) else { return nil }
            return Int(rounded)
        }

        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let slice = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: slice, encoding: .utf8)
        }

        func skipBytes(_ count: Int) -> Bool {
            guard ensureCapacity(count) else { return false }
            offset += count
            return true
        }

        func readScalarInt(for type: UInt32) -> Int? {
            switch type {
            case 0: // uint8
                return readU8().map { Int($0) }
            case 1: // int8
                return readU8().map { Int(Int8(bitPattern: $0)) }
            case 2: // uint16
                return readU16().map { Int($0) }
            case 3: // int16
                return readU16().map { Int(Int16(bitPattern: $0)) }
            case 4: // uint32
                return readU32().flatMap { Int(exactly: $0) }
            case 5: // int32
                return readU32().map { Int(Int32(bitPattern: $0)) }
            case 6: // float32
                return readF32().flatMap { roundedInt(from: Double($0)) }
            case 7: // bool
                return readU8().map { $0 == 0 ? 0 : 1 }
            case 10: // uint64
                return readU64().flatMap { Int(exactly: $0) }
            case 11: // int64
                return readU64().map { Int(Int64(bitPattern: $0)) }
            case 12: // float64
                return readF64().flatMap { roundedInt(from: $0) }
            default:
                return nil
            }
        }

        func readArrayMaxInt(elementType: UInt32, count: UInt64) -> Int? {
            guard count <= UInt64(Int.max) else { return nil }
            var maxValue: Int?
            for _ in 0..<Int(count) {
                guard let value = readScalarInt(for: elementType) else { return nil }
                if let current = maxValue {
                    if value > current { maxValue = value }
                } else {
                    maxValue = value
                }
            }
            return maxValue
        }

        func readIntOrArrayMax(for type: UInt32) -> Int? {
            switch type {
            case 9: // array
                guard let elementType = readU32(), let count = readU64() else { return nil }
                return readArrayMaxInt(elementType: elementType, count: count)
            default:
                return readScalarInt(for: type)
            }
        }

        func isExpertCountKey(_ key: String) -> Bool {
            let lower = key.lowercased()
            return lower.hasSuffix("expert_count") ||
                lower.contains("num_experts") ||
                lower.contains("n_expert")
        }

        func isExpertUsedCountKey(_ key: String) -> Bool {
            let lower = key.lowercased()
            return lower.hasSuffix("expert_used_count") ||
                lower.contains("active_experts") ||
                lower.contains("experts_per_token") ||
                lower.contains("n_expert_used")
        }

        func isMoEIndicatorKey(_ key: String) -> Bool {
            let lower = key.lowercased()
            return lower.contains("expert_") ||
                lower.contains("experts_per_") ||
                lower.contains("num_experts") ||
                lower.contains("n_expert")
        }

        func skipValue(ofType type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:
                return skipBytes(1)
            case 2, 3:
                return skipBytes(2)
            case 4, 5, 6:
                return skipBytes(4)
            case 10, 11, 12:
                return skipBytes(8)
            case 8:
                guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                return skipBytes(len)
            case 9:
                guard let elemType = readU32(), let count = readU64() else { return false }
                if elemType == 8 {
                    for _ in 0..<count {
                        guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                        guard skipBytes(len) else { return false }
                    }
                    return true
                }
                let elementSize: Int
                switch elemType {
                case 0, 1, 7: elementSize = 1
                case 2, 3: elementSize = 2
                case 4, 5, 6: elementSize = 4
                case 10, 11, 12: elementSize = 8
                default: elementSize = 4
                }
                guard elementSize > 0 else { return false }
                let maxElements = UInt64(Int.max) / UInt64(elementSize)
                guard count <= maxElements else { return false }
                return skipBytes(Int(count) * elementSize)
            default:
                return false
            }
        }

        func parseBlockIndex(from name: String) -> Int {
            let prefixes = ["blk.", "layers."]
            guard let prefix = prefixes.first(where: { name.hasPrefix($0) }) else { return -1 }
            let rest = name.dropFirst(prefix.count)
            var digits = ""
            for ch in rest {
                if ch.isNumber {
                    digits.append(ch)
                } else {
                    break
                }
            }
            return Int(digits) ?? -1
        }

        func isMoETensorName(_ name: String) -> Bool {
            let suffixes = [
                ".ffn_gate_inp.weight",
                ".ffn_gate_inp_shexp.weight",
                ".ffn_gate_exps.weight",
                ".ffn_up_exps.weight",
                ".ffn_down_exps.weight",
                ".ffn_norm_exps.weight",
                ".ffn_gate_chexps.weight",
                ".ffn_up_chexps.weight",
                ".ffn_down_chexps.weight"
            ]
            return suffixes.contains { name.hasSuffix($0) }
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil } // version
        guard let tensorCount64 = readU64(), tensorCount64 <= UInt64(Int.max) else { return nil }
        guard let kvCount64 = readU64(), kvCount64 <= UInt64(Int.max) else { return nil }

        let tensorCount = Int(tensorCount64)
        let kvCount = Int(kvCount64)

        var isMoE = false
        var expertCount = 0
        var defaultUsed: Int?
        var moeLayerCount: Int?
        var totalLayerCount: Int?
        var hiddenSize: Int?
        var feedForwardSize: Int?
        var vocabSize: Int?
        var maxBlockIndex = -1

        for _ in 0..<kvCount {
            guard let keyLen = readU64().flatMap({ Int(exactly: $0) }), let key = readString(len: keyLen), let type = readU32() else {
                return nil
            }
            var consumed = false

            switch key {
            case "llama.expert_count":
                if let value = readIntOrArrayMax(for: type) {
                    expertCount = max(expertCount, max(value, 0))
                    if value > 0 { isMoE = true }
                    consumed = true
                }
            case "llama.expert_used_count":
                if let value = readIntOrArrayMax(for: type), value > 0 {
                    defaultUsed = value
                    consumed = true
                }
            case "llama.block_count", "llama.n_layer", "hparams.n_layer":
                if let value = readScalarInt(for: type), value > 0 {
                    totalLayerCount = value
                    consumed = true
                }
            case "llama.embedding_length":
                if let value = readScalarInt(for: type), value > 0 {
                    hiddenSize = value
                    consumed = true
                }
            case "llama.feed_forward_length":
                if let value = readScalarInt(for: type), value > 0 {
                    feedForwardSize = value
                    consumed = true
                }
            case "llama.vocab_size":
                if let value = readScalarInt(for: type), value > 0 {
                    vocabSize = value
                    consumed = true
                }
            default:
                if isExpertCountKey(key) {
                    if let value = readIntOrArrayMax(for: type) {
                        expertCount = max(expertCount, max(value, 0))
                        if value > 0 { isMoE = true }
                        consumed = true
                    }
                } else if isExpertUsedCountKey(key) {
                    if let value = readIntOrArrayMax(for: type), value > 0 {
                        defaultUsed = value
                        consumed = true
                    }
                } else if isMoEIndicatorKey(key) {
                    // Some GGUF converters omit standard expert count keys but include other MoE-specific
                    // metadata such as expert grouping or gating parameters.
                    if type == 8 {
                        isMoE = true
                    } else if let value = readIntOrArrayMax(for: type), value > 0 {
                        isMoE = true
                        consumed = true
                    }
                }
            }

            if !consumed {
                guard skipValue(ofType: type) else { return nil }
            }
        }

        var moeBlockIndices = Set<Int>()
        for _ in 0..<tensorCount {
            guard let nameLen = readU64().flatMap({ Int(exactly: $0) }), let name = readString(len: nameLen) else { return nil }
            guard let dimCount = readU32().map(Int.init) else { return nil }
            for _ in 0..<dimCount {
                guard readU64() != nil else { return nil }
            }
            guard readU32() != nil else { return nil }
            guard readU64() != nil else { return nil }

            let blockIndex = parseBlockIndex(from: name)
            if blockIndex >= 0 && blockIndex > maxBlockIndex {
                maxBlockIndex = blockIndex
            }

            if blockIndex >= 0 && isMoETensorName(name) {
                moeBlockIndices.insert(blockIndex)
            }
        }

        let moeLayers = moeBlockIndices.count
        if moeLayers > 0 {
            moeLayerCount = moeLayers
            isMoE = true
        }

        if totalLayerCount == nil && maxBlockIndex >= 0 {
            totalLayerCount = maxBlockIndex + 1
        }

        return MoEInfo(
            isMoE: isMoE,
            expertCount: expertCount,
            defaultUsed: defaultUsed,
            moeLayerCount: moeLayerCount,
            totalLayerCount: totalLayerCount,
            hiddenSize: hiddenSize,
            feedForwardSize: feedForwardSize,
            vocabSize: vocabSize
        )
    }

    fileprivate static func computeChatTemplate(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            length >= 0 && offset <= data.count - length
        }

        func skipBytes(_ length: Int) -> Bool {
            guard ensureCapacity(length) else { return false }
            offset += length
            return true
        }

        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: value)
        }

        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let sub = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: sub, encoding: .utf8)
        }

        func skipValue(ofType type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:
                return skipBytes(1)
            case 2, 3:
                return skipBytes(2)
            case 4, 5, 6:
                return skipBytes(4)
            case 10, 11, 12:
                return skipBytes(8)
            case 8:
                guard let length = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                return skipBytes(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                if elementType == 8 {
                    guard count <= UInt64(Int.max) else { return false }
                    for _ in 0..<Int(count) {
                        guard let length = readU64().flatMap({ Int(exactly: $0) }),
                              skipBytes(length) else { return false }
                    }
                    return true
                }
                let elementSize: Int
                switch elementType {
                case 0, 1, 7: elementSize = 1
                case 2, 3: elementSize = 2
                case 4, 5, 6: elementSize = 4
                case 10, 11, 12: elementSize = 8
                default: return false
                }
                guard count <= UInt64(Int.max / elementSize),
                      let elementCount = Int(exactly: count) else { return false }
                return skipBytes(elementCount * elementSize)
            default:
                return false
            }
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil }
        guard readU64() != nil else { return nil }
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
        for _ in 0..<kvCount {
            guard let klen = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
            guard let key = readString(len: klen) else { return nil }
            guard let type = readU32() else { return nil }
            switch type {
            case 8: // string
                guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
                if key.contains("chat_template") {
                    return readString(len: len)
                }
                guard skipBytes(len) else { return nil }
            default:
                guard skipValue(ofType: type) else { return nil }
            }
        }
        return nil
    }

    /// Scan GGUF header/kv for tool-related markers (chat_template hints or added tokens)
    fileprivate static func computeSuggestsTools(at url: URL) -> Bool {
        // Attempt to read a limited header where GGUF metadata lives for speed
        let maxScanBytes = 8 * 1024 * 1024 // 8 MB
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: maxScanBytes), head.count > 0 else { return false }

        // Strong markers commonly present in tool-capable chat templates or token lists
        let indicators: [String] = [
            "tools", "tool_call", "tool_calls", "function_call", "function_calls",
            "tool_result", "tool_response", "function_response",
            "<tool_call>", "</tool_call>", "<tools>", "</tools>",
            #""role":\s*"tool"#,
            "<|tool_call|>", "<|tool_response|>",
            "assistant_tools", "tool_call_id"
        ]
        for key in indicators {
            if let needle = key.data(using: .utf8), head.range(of: needle) != nil { return true }
        }
        // Fallback: if explicit chat_template is present, try to parse it and re-check
        if let tmpl = chatTemplate(at: url), !tmpl.isEmpty {
            let lower = tmpl.lowercased()
            for k in indicators where lower.contains(k.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)) {
                return true
            }
        }
        return false
    }

    /// Heuristic detection for vision-capable GGUF models.
    /// Scans the header/kv section for vision-related keys to avoid loading the entire file.
    fileprivate static func computeIsVisionLikely(at url: URL) -> Bool {
        // Attempt to read only the first few megabytes where GGUF metadata resides
        let maxScanBytes = 8 * 1024 * 1024 // 8 MB
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: maxScanBytes), head.count > 0 else { return false }

        // Common indicators of VLM/vision support present in GGUF kv keys or text
        let indicators: [String] = [
            "mm_projector", "mm_vision", "vision_tower", "vision", "visual",
            "clip", "siglip", "image_token", "image_grid", "image_size",
            "llava", "qwen-vl", "internvl", "phi-3-vision", "glm-4v", "pixtral",
            "multimodal", "vlm"
        ]
        for key in indicators {
            if let needle = key.data(using: .utf8), head.range(of: needle) != nil { return true }
        }
        return false
    }

    /// Stronger check for merged vision models: verify projector-related metadata/tensors exist.
    /// Returns true only when the GGUF contains definitive projector indicators such as
    /// keys like `llava.projector_type`, or tensor/kv names containing `mmproj`, `mm_projector`, or `vision_tower`.
    fileprivate static func computeHasMultimodalProjector(at url: URL) -> Bool {
        // Read the first chunk where GGUF header + kvs live
        let maxScanBytes = 16 * 1024 * 1024 // 16 MB
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: maxScanBytes), head.count > 0 else { return false }

        let data = head
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            length >= 0 && offset <= data.count - length
        }

        func skipBytes(_ length: Int) -> Bool {
            guard ensureCapacity(length) else { return false }
            offset += length
            return true
        }

        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            offset += 4
            return UInt32(littleEndian: value)
        }

        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            offset += 8
            return UInt64(littleEndian: value)
        }

        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let sub = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: sub, encoding: .utf8)
        }

        func skipValue(ofType type: UInt32) -> Bool {
            switch type {
            case 0, 1, 7:
                return skipBytes(1)
            case 2, 3:
                return skipBytes(2)
            case 4, 5, 6:
                return skipBytes(4)
            case 10, 11, 12:
                return skipBytes(8)
            case 8:
                guard let length = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                return skipBytes(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                if elementType == 8 {
                    guard count <= UInt64(Int.max) else { return false }
                    for _ in 0..<Int(count) {
                        guard let length = readU64().flatMap({ Int(exactly: $0) }),
                              skipBytes(length) else { return false }
                    }
                    return true
                }
                let elementSize: Int
                switch elementType {
                case 0, 1, 7: elementSize = 1
                case 2, 3: elementSize = 2
                case 4, 5, 6: elementSize = 4
                case 10, 11, 12: elementSize = 8
                default: return false
                }
                guard count <= UInt64(Int.max / elementSize),
                      let elementCount = Int(exactly: count) else { return false }
                return skipBytes(elementCount * elementSize)
            default:
                return false
            }
        }

        // Parse GGUF header minimally to iterate kvs
        guard let magic = readString(len: 4), magic == "GGUF" else {
            // Fallback: strong substring scan of header bytes
            return ["llava.projector_type", "mmproj", "mm_projector", "vision_tower"].contains { key in
                head.range(of: key.data(using: .utf8)!) != nil
            }
        }
        guard readU32() != nil else { return false } // version
        _ = readU64() // tensor count (unused)
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return false }

        let projectorIndicators = [
            "llava.projector_type",
            "mmproj",
            "mm_projector",
            "vision_tower"
        ]

        for _ in 0..<kvCount {
            guard let klen = readU64().flatMap({ Int(exactly: $0) }), let key = readString(len: klen), let type = readU32() else {
                break
            }
            let lowerKey = key.lowercased()
            if projectorIndicators.contains(where: { lowerKey.contains($0) }) {
                return true
            }
            switch type {
            case 8: // string
                guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return false }
                // Optionally, value can also contain indicators
                if let value = readString(len: len)?.lowercased(), projectorIndicators.contains(where: { value.contains($0) }) {
                    return true
                }
            default:
                guard skipValue(ofType: type) else { return false }
            }
        }

        // As a fallback, search the scanned header for strong projector tokens
        for token in projectorIndicators {
            if let needle = token.data(using: .utf8), head.range(of: needle) != nil {
                return true
            }
        }
        return false
    }

    fileprivate static func computeMTPInspection(at url: URL) -> MTPInspection? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0

        func readData(_ count: Int) -> Data? {
            let current = handle.offsetInFile
            guard count >= 0,
                  UInt64(count) <= fileSize - min(current, fileSize),
                  let data = try? handle.read(upToCount: count),
                  data.count == count else { return nil }
            return data
        }
        func skip(_ count: UInt64) -> Bool {
            let current = handle.offsetInFile
            guard count <= UInt64.max - current, current + count <= fileSize else { return false }
            do {
                try handle.seek(toOffset: current + count)
                return true
            } catch {
                return false
            }
        }
        func readU32() -> UInt32? {
            readData(4)?.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        func readU64() -> UInt64? {
            readData(8)?.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        }
        func readString() -> String? {
            guard let length = readU64(), let count = Int(exactly: length), let data = readData(count) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        func readInteger(type: UInt32) -> Int64? {
            switch type {
            case 0: return readData(1).map { Int64($0[0]) }
            case 1: return readData(1).map { Int64(Int8(bitPattern: $0[0])) }
            case 2: return readData(2)?.withUnsafeBytes { Int64(UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))) }
            case 3: return readData(2)?.withUnsafeBytes { Int64(Int16(bitPattern: UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)))) }
            case 4: return readU32().map(Int64.init)
            case 5: return readU32().map { Int64(Int32(bitPattern: $0)) }
            case 10:
                guard let value = readU64(), value <= UInt64(Int64.max) else { return nil }
                return Int64(value)
            case 11: return readU64().map { Int64(bitPattern: $0) }
            default: return nil
            }
        }
        func scalarSize(type: UInt32) -> UInt64? {
            switch type {
            case 0, 1, 7: return 1
            case 2, 3: return 2
            case 4, 5, 6: return 4
            case 10, 11, 12: return 8
            default: return nil
            }
        }
        func skipArray(elementType: UInt32, count: UInt64) -> Bool {
            if elementType == 8 {
                for _ in 0..<count {
                    guard let length = readU64(), skip(length) else { return false }
                }
                return true
            }
            guard let size = scalarSize(type: elementType), count <= UInt64.max / size else { return false }
            return skip(count * size)
        }
        func skipValue(type: UInt32) -> Bool {
            switch type {
            case 8:
                guard let length = readU64() else { return false }
                return skip(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                return skipArray(elementType: elementType, count: count)
            default:
                guard let size = scalarSize(type: type) else { return false }
                return skip(size)
            }
        }
        func tokenizerFingerprint(count: UInt64) -> UInt64? {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for _ in 0..<count {
                guard let length = readU64(), let byteCount = Int(exactly: length), let bytes = readData(byteCount) else { return nil }
                for byte in bytes {
                    hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
                }
                hash = (hash ^ 0xff) &* 1_099_511_628_211
            }
            return hash
        }

        guard readData(4) == Data("GGUF".utf8), readU32() != nil,
              let tensorCount = readU64(), let kvCount = readU64() else { return nil }
        var result = MTPInspection()

        for _ in 0..<kvCount {
            guard let key = readString(), let type = readU32() else { return nil }
            let lower = key.lowercased()
            if lower == "general.architecture", type == 8 {
                guard let architecture = readString() else { return nil }
                result.architecture = architecture.lowercased()
            } else if lower == "tokenizer.ggml.tokens", type == 9 {
                guard let elementType = readU32(), elementType == 8, let count = readU64() else { return nil }
                result.vocabularySize = Int(exactly: count)
                guard let fingerprint = tokenizerFingerprint(count: count) else { return nil }
                result.tokenizerFingerprint = fingerprint
            } else if lower == "nextn_predict_layers" || lower.hasSuffix(".nextn_predict_layers") {
                guard let value = readInteger(type: type) else { return nil }
                result.nextNLayers = max(0, Int(clamping: value))
            } else if lower.hasSuffix(".embedding_length") {
                guard let value = readInteger(type: type) else { return nil }
                result.hiddenSize = value > 0 ? Int(exactly: value) : nil
            } else if lower.hasSuffix(".vocab_size") {
                guard let value = readInteger(type: type) else { return nil }
                result.vocabularySize = value > 0 ? Int(exactly: value) : result.vocabularySize
            } else if !skipValue(type: type) {
                return nil
            }
        }

        for _ in 0..<tensorCount {
            guard let name = readString(), let dimensions = readU32(), dimensions <= 4 else { return nil }
            let lower = name.lowercased()
            for marker in ["nextn.eh_proj", "nextn.enorm", "nextn.hnorm"] where lower.contains(marker) {
                result.tensorCounts[marker, default: 0] += 1
            }
            for _ in 0..<dimensions {
                guard readU64() != nil else { return nil }
            }
            guard readU32() != nil, readU64() != nil else { return nil }
        }
        return result
    }

    fileprivate static func computeExpertTensorInventory(at url: URL) -> ExpertTensorInventory? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0

        func readData(_ count: Int) -> Data? {
            let current = handle.offsetInFile
            guard count >= 0,
                  UInt64(count) <= fileSize - min(current, fileSize),
                  let data = try? handle.read(upToCount: count),
                  data.count == count else { return nil }
            return data
        }
        func skip(_ count: UInt64) -> Bool {
            let current = handle.offsetInFile
            guard count <= UInt64.max - current, current + count <= fileSize else { return false }
            do {
                try handle.seek(toOffset: current + count)
                return true
            } catch {
                return false
            }
        }
        func readU32() -> UInt32? {
            readData(4)?.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        func readU64() -> UInt64? {
            readData(8)?.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) }
        }
        func readString() -> String? {
            guard let length = readU64(), let count = Int(exactly: length), let data = readData(count) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        func readInteger(type: UInt32) -> Int64? {
            switch type {
            case 0: return readData(1).map { Int64($0[0]) }
            case 1: return readData(1).map { Int64(Int8(bitPattern: $0[0])) }
            case 2: return readData(2)?.withUnsafeBytes { Int64(UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self))) }
            case 3: return readData(2)?.withUnsafeBytes { Int64(Int16(bitPattern: UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)))) }
            case 4: return readU32().map(Int64.init)
            case 5: return readU32().map { Int64(Int32(bitPattern: $0)) }
            case 10:
                guard let value = readU64(), value <= UInt64(Int64.max) else { return nil }
                return Int64(value)
            case 11: return readU64().map { Int64(bitPattern: $0) }
            default: return nil
            }
        }
        func scalarSize(type: UInt32) -> UInt64? {
            switch type {
            case 0, 1, 7: return 1
            case 2, 3: return 2
            case 4, 5, 6: return 4
            case 10, 11, 12: return 8
            default: return nil
            }
        }
        func skipArray(elementType: UInt32, count: UInt64) -> Bool {
            if elementType == 8 {
                for _ in 0..<count {
                    guard let length = readU64(), skip(length) else { return false }
                }
                return true
            }
            guard let size = scalarSize(type: elementType), count <= UInt64.max / size else { return false }
            return skip(count * size)
        }
        func skipValue(type: UInt32) -> Bool {
            switch type {
            case 8:
                guard let length = readU64() else { return false }
                return skip(length)
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return false }
                return skipArray(elementType: elementType, count: count)
            default:
                guard let size = scalarSize(type: type) else { return false }
                return skip(size)
            }
        }
        func expertFamily(_ stem: Substring) -> String? {
            switch stem {
            case "ffn_gate_up_exps": return "gate_up"
            case "ffn_gate_exps": return "gate"
            case "ffn_up_exps": return "up"
            case "ffn_down_exps": return "down"
            default: return nil
            }
        }

        guard readData(4) == Data("GGUF".utf8), readU32() != nil,
              let tensorCount = readU64(), let kvCount = readU64() else { return nil }

        var alignment: UInt64 = 32
        for _ in 0..<kvCount {
            guard let key = readString(), let type = readU32() else { return nil }
            if key.lowercased() == "general.alignment" {
                guard let value = readInteger(type: type), value > 0 else { return nil }
                alignment = UInt64(value)
            } else if !skipValue(type: type) {
                return nil
            }
        }

        var records: [ExpertTensorRecord] = []
        var residentExpertScaleCount = 0
        var unsupportedSidecarCount = 0
        for _ in 0..<tensorCount {
            guard let name = readString(), let dimensions = readU32(), dimensions <= 4 else { return nil }
            var ne: [Int64] = []
            ne.reserveCapacity(Int(dimensions))
            for _ in 0..<dimensions {
                guard let dim = readU64() else { return nil }
                ne.append(Int64(bitPattern: dim))
            }
            guard let type = readU32(), let tensorOffset = readU64() else { return nil }

            // Exact-name match keeps `_shexp`/`_chexps` and other variants out.
            let parts = name.lowercased().split(separator: ".")
            guard parts.count == 4, parts[0] == "blk", let layer = Int(parts[1]),
                  let family = expertFamily(parts[2]) else { continue }
            if parts[3] == "weight" {
                records.append(ExpertTensorRecord(
                    name: name,
                    layer: layer,
                    family: family,
                    ggmlType: Int32(bitPattern: type),
                    ne: ne,
                    offset: tensorOffset
                ))
            } else if parts[3] == "scale" {
                residentExpertScaleCount += 1
            } else if parts[3] == "input_scale" || parts[3] == "bias" {
                unsupportedSidecarCount += 1
            }
        }

        // Tensor data begins at the aligned offset right after the tensor-info table.
        let position = handle.offsetInFile
        let remainder = position % alignment
        let tensorDataOffset = remainder == 0 ? position : position + (alignment - remainder)
        return ExpertTensorInventory(
            records: records,
            tensorDataOffset: tensorDataOffset,
            residentExpertScaleCount: residentExpertScaleCount,
            unsupportedSidecarCount: unsupportedSidecarCount
        )
    }
}

// MARK: - Per-file memoization
//
// GGUF metadata is immutable for a given file, so the (relatively expensive)
// parse results are cached by (path, size, modification date). This avoids
// re-mmapping multi-GB model files on every call — e.g. when the Settings
// summary cards recompute their counts. Safe to call off the main thread.
extension GGUFMetadata {
    private final class Box<T> {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private struct CacheKey: Hashable {
        let fn: String
        let path: String
        let size: Int64
        let mtime: Double
    }

    private final class MetadataCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CacheKey: AnyObject] = [:]

        func value<T>(for key: CacheKey) -> T? {
            lock.lock(); defer { lock.unlock() }
            return (storage[key] as? Box<T>)?.value
        }

        func store<T>(_ value: T, for key: CacheKey) {
            lock.lock(); defer { lock.unlock() }
            storage[key] = Box(value)
        }
    }

    private static let metadataCache = MetadataCache()

    private static func fileStamp(_ url: URL) -> (size: Int64, mtime: Double) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return (size, mtime)
    }

    private static func memoized<T>(_ fn: String, _ url: URL, compute: () -> T) -> T {
        let stamp = fileStamp(url)
        let key = CacheKey(fn: fn, path: url.path, size: stamp.size, mtime: stamp.mtime)
        if let cached: T = metadataCache.value(for: key) {
            return cached
        }
        let value = compute()
        metadataCache.store(value, for: key)
        return value
    }

    static func architectureInfo(at url: URL) -> (architecture: String, name: String?)? {
        // Memoized: this IS on the hot path — LocalModel.loadInstalled calls it per GGUF on the
        // main thread on every model-list rebuild (cold launch + every refresh()), and the box is
        // cheap. Without the cache it re-mmaps + re-walks the KV header every time.
        memoized("architectureInfo", url) { computeArchitectureInfo(at: url) }
    }

    static func layerCount(at url: URL) -> Int? {
        memoized("layerCount", url) { computeLayerCount(at: url) }
    }

    static func contextLength(at url: URL) -> Int? {
        memoized("contextLength", url) { computeContextLength(at: url) }
    }

    static func moeInfo(at url: URL) -> MoEInfo? {
        memoized("moeInfo", url) { computeMoeInfo(at: url) }
    }

    static func expertTensorInventory(at url: URL) -> ExpertTensorInventory? {
        memoized("expertTensorInventory", url) { computeExpertTensorInventory(at: url) }
    }

    static func chatTemplate(at url: URL) -> String? {
        memoized("chatTemplate", url) { computeChatTemplate(at: url) }
    }

    static func suggestsTools(at url: URL) -> Bool {
        memoized("suggestsTools", url) { computeSuggestsTools(at: url) }
    }

    static func isVisionLikely(at url: URL) -> Bool {
        memoized("isVisionLikely", url) { computeIsVisionLikely(at: url) }
    }

    static func hasMultimodalProjector(at url: URL) -> Bool {
        memoized("hasMultimodalProjector", url) { computeHasMultimodalProjector(at: url) }
    }

    static func hasMTP(at url: URL) -> Bool {
        mtpCapability(at: url) == .embeddedValidated
    }

    static func mtpCapability(at url: URL) -> MTPCapability {
        guard let inspection = mtpInspection(at: url), inspection.nextNLayers > 0 else {
            return .unavailable
        }
        guard let architecture = inspection.architecture,
              executableMTPArchitectures.contains(architecture) else {
            return .declaredButUnsupported
        }
        return inspection.hasRequiredTensors ? .embeddedValidated : .sidecarRequired
    }

    static func mtpCapability(targetURL: URL, sidecarURL: URL) -> MTPCapability {
        guard targetURL.standardizedFileURL != sidecarURL.standardizedFileURL,
              let target = mtpInspection(at: targetURL),
              let sidecar = mtpInspection(at: sidecarURL),
              target.nextNLayers > 0,
              sidecar.nextNLayers > 0,
              target.nextNLayers == sidecar.nextNLayers,
              let targetArchitecture = target.architecture,
              executableMTPArchitectures.contains(targetArchitecture),
              sidecar.architecture == targetArchitecture,
              sidecar.hasRequiredTensors,
              let targetHidden = target.hiddenSize,
              let sidecarHidden = sidecar.hiddenSize,
              targetHidden == sidecarHidden,
              let targetVocabulary = target.vocabularySize,
              let sidecarVocabulary = sidecar.vocabularySize,
              targetVocabulary == sidecarVocabulary,
              let targetTokenizer = target.tokenizerFingerprint,
              let sidecarTokenizer = sidecar.tokenizerFingerprint,
              targetTokenizer == sidecarTokenizer else {
            return .unavailable
        }
        return .sidecarValidated(sidecarURL)
    }

    private static func mtpInspection(at url: URL) -> MTPInspection? {
        memoized("mtpInspection", url) { computeMTPInspection(at: url) }
    }

    /// Populate the metadata cache for a GGUF file. Safe to call off the main
    /// thread (e.g. from a detached task) so that subsequent main-thread reads
    /// are served from cache and never block on disk I/O.
    static func prewarm(at url: URL) {
        _ = architectureInfo(at: url)
        _ = layerCount(at: url)
        _ = contextLength(at: url)
        _ = moeInfo(at: url)
        _ = mtpCapability(at: url)
        _ = hasMultimodalProjector(at: url)
        _ = chatTemplate(at: url)
    }
}
