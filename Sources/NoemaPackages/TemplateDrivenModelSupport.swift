import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum TemplateDrivenModelSupport {
    public enum Profile: String, Sendable {
        case none
        case qwen35
        case gemma4

        public var usesTemplateDrivenMessages: Bool {
            self != .none
        }

        public var templateLabel: String {
            switch self {
            case .none:
                return "model-default"
            case .qwen35:
                return "qwen3.5-override"
            case .gemma4:
                return "gemma4-interleaved"
            }
        }
    }

    private struct Resolution: Sendable {
        let profile: Profile
        let chatTemplateFile: String?
        let source: String
    }

    public static func usesTemplateDrivenMessages(modelID: String? = nil, modelURL: URL? = nil) -> Bool {
        resolvedProfile(modelID: modelID, modelURL: modelURL).usesTemplateDrivenMessages
    }

    public static func isQwen35(modelID: String? = nil, modelURL: URL? = nil) -> Bool {
        resolvedProfile(modelID: modelID, modelURL: modelURL) == .qwen35
    }

    public static func isGemma4(modelID: String? = nil, modelURL: URL? = nil) -> Bool {
        resolvedProfile(modelID: modelID, modelURL: modelURL) == .gemma4
    }

    public static func resolvedProfile(modelID: String? = nil, modelURL: URL? = nil) -> Profile {
        resolve(modelID: modelID, modelURL: modelURL).profile
    }

    public static func templateLabel(modelID: String? = nil, modelURL: URL? = nil) -> String {
        resolvedProfile(modelID: modelID, modelURL: modelURL).templateLabel
    }

    public static func isQwen35Identifier(modelID: String? = nil, modelURL: URL? = nil) -> Bool {
        let normalized = normalizedIdentifier(modelID: modelID, modelURL: modelURL)
        guard !normalized.isEmpty else { return false }
        return normalized.contains("qwen3.5")
            || normalized.contains("qwen-3.5")
            || normalized.contains("qwen 3.5")
    }

    public static func isGemma4Identifier(modelID: String? = nil, modelURL: URL? = nil) -> Bool {
        let normalized = normalizedIdentifier(modelID: modelID, modelURL: modelURL)
        guard !normalized.isEmpty else { return false }
        return normalized.contains("gemma-4")
            || normalized.contains("gemma4")
            || normalized.contains("gemma 4")
    }

    public static func loopbackStartConfiguration(modelID: String? = nil,
                                                  modelURL: URL? = nil,
                                                  host: String = "127.0.0.1",
                                                  preferredPort: Int32 = 0,
                                                  ggufPath: String,
                                                  mmprojPath: String?,
                                                  mtpPath: String? = nil,
                                                  speculativeType: String? = nil,
                                                  specDraftNMax: Int32? = nil,
                                                  specDraftNMin: Int32? = nil,
                                                  specDraftPMin: Double? = nil,
                                                  specDynamic: Bool = false,
                                                  contextSize: Int32 = 4096,
                                                  contextShift: Bool = true,
                                                  gpuLayers: Int32 = -1,
                                                  threads: Int32 = 1,
                                                  threadsBatch: Int32? = nil,
                                                  batchSize: Int32 = 512,
                                                  ubatchSize: Int32 = 256,
                                                  useMmap: Bool = true,
                                                  useMlock: Bool = false,
                                                  warmup: Bool = true,
                                                  kvOffload: Bool = true,
                                                  unifiedKVCache: Bool = true,
                                                  flashAttention: Bool = true,
                                                  cacheTypeK: String = "f16",
                                                  cacheTypeV: String = "f16",
                                                  parallelSlots: Int32 = 1,
                                                  tensorOverride: String? = nil,
                                                  cpuMoE: Bool = false,
                                                  moeExpertCount: Int32? = nil,
                                                  yarnScale: Double? = nil,
                                                  yarnOriginalContext: Int32? = nil,
                                                  yarnBetaFast: Double? = nil,
                                                  yarnBetaSlow: Double? = nil,
                                                  promptCacheEnabled: Bool = true,
                                                  ctxCheckpointsOverride: Int32? = nil,
                                                  pagedMode: LlamaServerBridge.PagedMode = .off,
                                                  pagedManifestPath: String? = nil,
                                                  pagedTrace: Bool = false,
                                                  pagedBankBudgetMiB: Int32 = 0,
                                                  pagedPrefetch: Bool = false,
                                                  pagedIOThreads: Int32 = 0,
                                                  pagedIODepth: Int32 = 0,
                                                  pagedWaves: Bool = false,
                                                  pagedExpertMajor: Bool = false) -> LlamaServerBridge.StartConfiguration {
        let resolution = resolve(modelID: modelID, modelURL: modelURL)
        // Bound the prompt/KV checkpoint cache. llama.cpp defaults to an 8 GiB
        // cache-ram ceiling with 32 checkpoints per slot, which is a latent
        // out-of-memory risk on iOS. Cap it platform-appropriately for every
        // model (gemma4 keeps its own tighter cap below); reuse stays enabled.
        #if os(macOS)
        let defaultCacheRamMiB: Int32 = 4096
        let defaultCtxCheckpoints: Int32 = 8
        #else
        let defaultCacheRamMiB: Int32 = 1024
        let defaultCtxCheckpoints: Int32 = 4
        #endif
        let cacheRamMiB: Int32 = promptCacheEnabled
            ? (resolution.profile == .gemma4 ? 2048 : defaultCacheRamMiB)
            : 0
        // Context checkpoints are independent of the cache-ram prompt cache:
        // the server gates creation/restore solely on --ctx-checkpoints. The
        // override lets paged launches keep cache-ram at 0 while still
        // checkpointing the non-rollback-able (hybrid/recurrent) state, which
        // is the only prefix-reuse mechanism those architectures have.
        let ctxCheckpoints: Int32 = ctxCheckpointsOverride
            ?? (promptCacheEnabled
                ? (resolution.profile == .gemma4 ? 2 : defaultCtxCheckpoints)
                : 0)
        return LlamaServerBridge.StartConfiguration(
                host: host,
                preferredPort: preferredPort,
                ggufPath: ggufPath,
                mmprojPath: mmprojPath,
                mtpPath: mtpPath,
                chatTemplateFile: resolution.chatTemplateFile,
                reasoningBudget: resolution.profile == .qwen35 ? -1 : nil,
                contextSize: contextSize,
                contextShift: contextShift,
                gpuLayers: gpuLayers,
                threads: threads,
                threadsBatch: threadsBatch,
                batchSize: batchSize,
                ubatchSize: ubatchSize,
                useMmap: useMmap,
                useMlock: useMlock,
                warmup: warmup,
                kvOffload: kvOffload,
                unifiedKVCache: unifiedKVCache,
                flashAttention: flashAttention,
                cacheTypeK: cacheTypeK,
                cacheTypeV: cacheTypeV,
                parallelSlots: parallelSlots,
                tensorOverride: tensorOverride,
                cpuMoE: cpuMoE,
                moeExpertCount: moeExpertCount,
                yarnScale: yarnScale,
                yarnOriginalContext: yarnOriginalContext,
                yarnBetaFast: yarnBetaFast,
                yarnBetaSlow: yarnBetaSlow,
                cacheRamMiB: cacheRamMiB,
                ctxCheckpoints: ctxCheckpoints,
                speculativeType: speculativeType,
                specDraftNMax: specDraftNMax,
                specDraftNMin: specDraftNMin,
                specDraftPMin: specDraftPMin,
                specDynamic: specDynamic,
                // Native tool calling requires --jinja. It is safe for templates
                // that do not branch on tool metadata.
                useJinja: true,
                pagedMode: pagedMode,
                pagedManifestPath: pagedManifestPath,
                pagedBankBudgetMiB: pagedBankBudgetMiB,
                pagedIOThreads: pagedIOThreads,
                pagedIODepth: pagedIODepth,
                pagedPrefetch: pagedPrefetch,
                pagedTrace: pagedTrace,
                pagedWaves: pagedWaves,
                pagedExpertMajor: pagedExpertMajor
            )
    }

    public static func resolveChatTemplateFile(modelID: String? = nil, modelURL: URL? = nil) -> String? {
        resolve(modelID: modelID, modelURL: modelURL).chatTemplateFile
    }

    private static func materializeBundledGemma4InterleavedTemplate() -> String? {
        guard let resourceURL = Bundle.module.url(
            forResource: "google-gemma-4-31B-it-interleaved",
            withExtension: "jinja"
        ),
        let template = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return nil
        }
        return materializeTemplate(template, key: "google-gemma-4-31B-it-interleaved")
    }

    private static func resolve(modelID: String?, modelURL: URL?) -> Resolution {
        if isGemma4Identifier(modelID: modelID, modelURL: modelURL) {
            let bundledTemplate = materializeBundledGemma4InterleavedTemplate()
            let resolution = Resolution(
                profile: .gemma4,
                chatTemplateFile: bundledTemplate,
                source: "identifier"
            )
            logProfileResolution(resolution, modelID: modelID, modelURL: modelURL)
            return resolution
        }

        let root = templateRootDirectory(for: modelURL)
        let key = templateKey(modelID: modelID, modelURL: modelURL, root: root)

        if let root,
           let extracted = extractedTemplateCandidate(in: root, key: key) {
            let profile = profile(fromTemplate: extracted.contents)
            if profile != .none {
                let resolution = Resolution(
                    profile: profile,
                    chatTemplateFile: extracted.filePath,
                    source: extracted.source
                )
                logProfileResolution(resolution, modelID: modelID, modelURL: modelURL)
                return resolution
            }
            if isQwen35Identifier(modelID: modelID, modelURL: modelURL) {
                let resolution = Resolution(
                    profile: .qwen35,
                    chatTemplateFile: extracted.filePath,
                    source: extracted.source + "+identifier"
                )
                logProfileResolution(resolution, modelID: modelID, modelURL: modelURL)
                return resolution
            }
            let resolution = Resolution(
                profile: .none,
                chatTemplateFile: extracted.filePath,
                source: extracted.source
            )
            logProfileResolution(resolution, modelID: modelID, modelURL: modelURL)
            return resolution
        }

        if isQwen35Identifier(modelID: modelID, modelURL: modelURL) {
            let resolution = Resolution(
                profile: .qwen35,
                chatTemplateFile: nil,
                source: "identifier"
            )
            logProfileResolution(resolution, modelID: modelID, modelURL: modelURL)
            return resolution
        }

        let resolution = Resolution(profile: .none, chatTemplateFile: nil, source: "default")
        logProfileResolution(resolution, modelID: modelID, modelURL: modelURL)
        return resolution
    }

    private static func templateRootDirectory(for modelURL: URL?) -> URL? {
        guard let modelURL else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDir), isDir.boolValue {
            return modelURL
        }
        return modelURL.deletingLastPathComponent()
    }

    private struct TemplateCandidate {
        let contents: String
        let filePath: String?
        let source: String
    }

    private static func extractedTemplateCandidate(in root: URL, key: String) -> TemplateCandidate? {
        if let direct = existingTemplateFile(in: root, named: "chat_template.jinja"),
           let raw = try? String(contentsOf: direct, encoding: .utf8),
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            logTemplateSignature(path: direct.path, contents: raw)
            return TemplateCandidate(contents: raw, filePath: direct.path, source: "chat_template.jinja")
        }

        for candidate in ["chat_template.txt", "chat_template.json", "tokenizer_config.json", "tokenizer.json", "config.json", "hub.json"] {
            let fileURL = root.appendingPathComponent(candidate)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
            if candidate == "chat_template.txt",
               let raw = try? String(contentsOf: fileURL, encoding: .utf8),
               !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TemplateCandidate(
                    contents: raw,
                    filePath: materializeTemplate(raw, key: key),
                    source: candidate
                )
            }
            if let extracted = extractChatTemplate(from: fileURL),
               !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return TemplateCandidate(
                    contents: extracted,
                    filePath: materializeTemplate(extracted, key: key),
                    source: candidate
                )
            }
        }

        if let embedded = embeddedGGUFChatTemplate(in: root) {
            return TemplateCandidate(
                contents: embedded,
                filePath: materializeTemplate(embedded, key: key),
                source: "embedded-gguf"
            )
        }

        return nil
    }

    private static func existingTemplateFile(in root: URL, named name: String) -> URL? {
        let candidate = root.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: candidate), !data.isEmpty else { return nil }
        return candidate
    }

    private static func extractChatTemplate(from fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return extractChatTemplate(fromJSONObject: json)
    }

    private static func extractChatTemplate(fromJSONObject object: Any) -> String? {
        if let raw = object as? String, !raw.isEmpty {
            return raw
        }
        guard let dict = object as? [String: Any] else { return nil }
        if let template = dict["chat_template"] as? String, !template.isEmpty {
            return template
        }
        if let template = dict["chat_template_jinja"] as? String, !template.isEmpty {
            return template
        }
        if let gguf = dict["gguf"] as? [String: Any],
           let template = gguf["chat_template"] as? String,
           !template.isEmpty {
            return template
        }
        if let cardData = dict["cardData"] as? [String: Any] {
            if let template = cardData["chat_template"] as? String, !template.isEmpty {
                return template
            }
            if let template = cardData["chat_template_jinja"] as? String, !template.isEmpty {
                return template
            }
        }
        return nil
    }

    private static func embeddedGGUFChatTemplate(in root: URL) -> String? {
        guard let modelURL = firstGGUF(in: root) else { return nil }
        return extractChatTemplateFromGGUF(at: modelURL)
    }

    private static func firstGGUF(in root: URL) -> URL? {
        func isProjectorLike(_ url: URL) -> Bool {
            let lower = url.lastPathComponent.lowercased()
            return lower.contains("mmproj") || lower.contains("projector") || lower.contains("image_proj")
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue {
            let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension.lowercased() == "gguf" } ?? []
            return files.first(where: { !isProjectorLike($0) }) ?? files.first
        }
        return root.pathExtension.lowercased() == "gguf" ? root : nil
    }

    private static func extractChatTemplateFromGGUF(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var offset = 0

        func ensureCapacity(_ length: Int) -> Bool {
            length >= 0 && offset <= data.count - length
        }

        func readU32() -> UInt32? {
            guard ensureCapacity(4) else { return nil }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4
            return UInt32(littleEndian: value)
        }

        func readU64() -> UInt64? {
            guard ensureCapacity(8) else { return nil }
            let value = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            }
            offset += 8
            return UInt64(littleEndian: value)
        }

        func readString(len: Int) -> String? {
            guard ensureCapacity(len) else { return nil }
            let subdata = data.subdata(in: offset..<offset+len)
            offset += len
            return String(data: subdata, encoding: .utf8)
        }

        guard let magic = readString(len: 4), magic == "GGUF" else { return nil }
        guard readU32() != nil else { return nil }
        guard readU64() != nil else { return nil }
        guard let kvCount = readU64().flatMap({ Int(exactly: $0) }) else { return nil }

        for _ in 0..<kvCount {
            guard let keyLen = readU64().flatMap({ Int(exactly: $0) }),
                  let key = readString(len: keyLen),
                  let type = readU32() else {
                return nil
            }

            switch type {
            case 8:
                guard let len = readU64().flatMap({ Int(exactly: $0) }) else { return nil }
                if key.contains("chat_template") {
                    return readString(len: len)
                }
                guard ensureCapacity(len) else { return nil }
                offset += len
            case 9:
                guard let elementType = readU32(), let count = readU64() else { return nil }
                guard skipArray(elementType: elementType, count: count, data: data, offset: &offset) else { return nil }
            default:
                guard skipScalar(type: type, data: data, offset: &offset) else { return nil }
            }
        }

        return nil
    }

    private static func skipArray(elementType: UInt32, count: UInt64, data: Data, offset: inout Int) -> Bool {
        if elementType == 8 {
            guard count <= UInt64(Int.max) else { return false }
            for _ in 0..<Int(count) {
                guard offset <= data.count - 8 else { return false }
                let lenValue = data.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                }
                offset += 8
                guard let len = Int(exactly: UInt64(littleEndian: lenValue)),
                      offset <= data.count - len else { return false }
                offset += len
            }
            return true
        }

        let elementSize: Int
        switch elementType {
        case 0, 1, 7:
            elementSize = 1
        case 2, 3:
            elementSize = 2
        case 4, 5, 6:
            elementSize = 4
        case 10, 11, 12:
            elementSize = 8
        default:
            elementSize = 4
        }

        guard count <= UInt64(Int.max / max(elementSize, 1)),
              let elementCount = Int(exactly: count) else { return false }
        let byteCount = elementCount * elementSize
        guard offset <= data.count - byteCount else { return false }
        offset += byteCount
        return true
    }

    private static func skipScalar(type: UInt32, data: Data, offset: inout Int) -> Bool {
        let size: Int
        switch type {
        case 0, 1, 7:
            size = 1
        case 2, 3:
            size = 2
        case 4, 5, 6:
            size = 4
        case 10, 11, 12:
            size = 8
        default:
            size = 0
        }
        guard size > 0 else { return false }
        guard offset <= data.count - size else { return false }
        offset += size
        return true
    }

    private static func materializeTemplate(_ template: String, key: String) -> String? {
        let normalized = template.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoemaLoopbackTemplates",
            isDirectory: true
        )
        let safeKey = key
            .lowercased()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let fileURL = dir.appendingPathComponent("\(safeKey).jinja")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? normalized.write(to: fileURL, atomically: true, encoding: .utf8)

        let fileContents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        logTemplateSignature(path: fileURL.path, contents: fileContents, matchesSource: fileContents == normalized)
        return fileURL.path
    }

    private static func logTemplateSignature(path: String, contents: String, matchesSource: Bool = true) {
        let containsThink = contents.contains("<think>")
        let containsFunction = contents.contains("<function=")
        let containsEnableThinking = contents.contains("enable_thinking")
        let firstLine = contents.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let signature = "path=\(path) matches=\(matchesSource) think=\(containsThink) function=\(containsFunction) enable_thinking=\(containsEnableThinking) first=\(firstLine.prefix(80)) bytes=\(contents.utf8.count)"
        writeStderr("[Loopback][Template] \(signature)\n")
    }

    private static func profile(fromTemplate template: String) -> Profile {
        let lower = template.lowercased()

        if lower.contains("<|turn>system") && lower.contains("<|turn>model") {
            return .gemma4
        }

        let qwen35Markers = [
            "enable_thinking",
            "reasoning_content",
            "<tool_call>",
            "<function=",
            "<parameter=",
            "<|im_start|>",
            "<think>"
        ]
        let hasThinking = lower.contains("enable_thinking") || lower.contains("reasoning_content")
        let hasToolMarkup = lower.contains("<tool_call>") || lower.contains("<function=") || lower.contains("<parameter=")
        let hasChatML = lower.contains("<|im_start|>")
        if (hasThinking && hasChatML) || (hasThinking && hasToolMarkup) || qwen35Markers.allSatisfy({ marker in
            if marker == "<think>" {
                return lower.contains(marker) || hasThinking
            }
            return lower.contains(marker)
        }) {
            return .qwen35
        }

        return .none
    }

    private static func templateKey(modelID: String?, modelURL: URL?, root: URL?) -> String {
        if let modelID, !modelID.isEmpty {
            return modelID
        }
        if let modelURL {
            return modelURL.deletingPathExtension().lastPathComponent
        }
        return root?.lastPathComponent ?? "model"
    }

    private static func normalizedIdentifier(modelID: String?, modelURL: URL?) -> String {
        let modelComponent = modelID ?? modelURL?.deletingPathExtension().lastPathComponent ?? ""
        return modelComponent
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
    }

    private static func logProfileResolution(_ resolution: Resolution, modelID: String?, modelURL: URL?) {
        let modelComponent = modelID ?? modelURL?.lastPathComponent ?? "unknown"
        let templateName = resolution.chatTemplateFile.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none"
        let line = "[Loopback][Profile] model=\(modelComponent) profile=\(resolution.profile.rawValue) source=\(resolution.source) template=\(templateName)\n"
        writeStderr(line)
    }

    private static func writeStderr(_ line: String) {
        fputs(line, stderr)
        fflush(stderr)
    }
}
