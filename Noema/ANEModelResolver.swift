import Foundation

enum ANEMLLCapabilityLookup {
    static func argmaxInModel(modelURL: URL) -> Bool {
        let root = modelRoot(from: modelURL)
        if let manifestFlag = manifestArgmaxFlag(in: root) {
            return manifestFlag
        }
#if canImport(CoreML) && (os(iOS) || os(visionOS))
        return (try? ANEModelResolver.resolve(modelURL: root).anemllPipeline?.argmaxInModel) == true
#else
        return false
#endif
    }

    private static func manifestArgmaxFlag(in root: URL) -> Bool? {
        for fileName in ["meta.yaml", "meta.yml"] {
            let candidate = root.appendingPathComponent(fileName)
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let contents = try? String(contentsOf: candidate, encoding: .utf8) else {
                continue
            }
            for rawLine in contents.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("argmax_in_model:") else { continue }
                let rawValue = trimmed
                    .split(separator: ":", maxSplits: 1)
                    .dropFirst()
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return boolValue(from: rawValue)
            }
            return nil
        }
        return nil
    }

    private static func boolValue(from raw: String?) -> Bool? {
        guard let raw = raw?.lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func modelRoot(from url: URL) -> URL {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if let artifact = enclosingCoreMLArtifact(for: fixed) {
            return artifact.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        }

        if fm.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
            return fixed
        }

        return fixed.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    }

    private static func enclosingCoreMLArtifact(for url: URL) -> URL? {
        let fm = FileManager.default
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL

        while true {
            let ext = candidate.pathExtension.lowercased()
            if (ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel"),
               fm.fileExists(atPath: candidate.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }
}

#if canImport(CoreML) && (os(iOS) || os(visionOS))
import CoreML

private enum CoreMLCompileCache {
    static func cachedCompiledModelURL(for source: URL, modelRoot: URL) throws -> URL {
        let cacheDir = try scopedCacheDirectory(for: modelRoot)
        let relativePath = source.path
            .replacingOccurrences(of: modelRoot.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let safeName = relativePath
            .replacingOccurrences(of: "/", with: "__")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let baseName = safeName.isEmpty
            ? source.deletingPathExtension().lastPathComponent
            : safeName
        return cacheDir.appendingPathComponent(baseName + ".mlmodelc", isDirectory: true)
    }

    static func removeCache(for modelRoot: URL) throws {
        let cacheDir = scopedCacheDirectoryPath(for: modelRoot)
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }
        try FileManager.default.removeItem(at: cacheDir)
    }

    private static func scopedCacheDirectory(for modelRoot: URL) throws -> URL {
        let cacheDir = scopedCacheDirectoryPath(for: modelRoot)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try excludeFromBackup(cacheDir)
        return cacheDir
    }

    private static func scopedCacheDirectoryPath(for modelRoot: URL) -> URL {
        cacheRootDirectory().appendingPathComponent(cacheKey(for: modelRoot), isDirectory: true)
    }

    private static func cacheRootDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches
            .appendingPathComponent("Noema", isDirectory: true)
            .appendingPathComponent("CoreMLCompiled", isDirectory: true)
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private static func cacheKey(for modelRoot: URL) -> String {
        let normalized = modelRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let basename = modelRoot.lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        return "\(basename)_\(fnv1a64Hex(normalized))"
    }

    private static func fnv1a64Hex(_ text: String) -> String {
        let offset: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        var hash = offset
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(hash, radix: 16)
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum CoreMLModelFlavor: String, Sendable {
    case transformersLanguageModel
    case statefulCausalLM
    case anemllPipeline
    case unknown
}

@available(iOS 18.0, visionOS 2.0, *)
struct CoreMLArtifactFeature: Codable, Equatable, Sendable {
    let name: String
    let dataType: String?
    let formattedType: String?
    let shape: String?

    init(name: String, dataType: String? = nil, formattedType: String? = nil, shape: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.formattedType = formattedType
        self.shape = shape
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct CoreMLArtifactMetadata: Codable, Equatable, Sendable {
    let inputSchema: [CoreMLArtifactFeature]
    let outputSchema: [CoreMLArtifactFeature]
    let stateSchema: [CoreMLArtifactFeature]
    let generatedClassName: String?
    let userDefinedMetadata: [String: String]?

    init(
        inputSchema: [CoreMLArtifactFeature] = [],
        outputSchema: [CoreMLArtifactFeature] = [],
        stateSchema: [CoreMLArtifactFeature] = [],
        generatedClassName: String? = nil,
        userDefinedMetadata: [String: String]? = nil
    ) {
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.stateSchema = stateSchema
        self.generatedClassName = generatedClassName
        self.userDefinedMetadata = userDefinedMetadata
    }

    var inputNames: Set<String> { Set(inputSchema.map(\.name)) }
    var outputNames: Set<String> { Set(outputSchema.map(\.name)) }
    var stateNames: Set<String> { Set(stateSchema.map(\.name)) }

    func intMetadataValue(for key: String) -> Int? {
        guard let raw = userDefinedMetadata?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return Int(raw)
    }

    func boolMetadataValue(for key: String) -> Bool? {
        guard let raw = userDefinedMetadata?[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }

    func intArrayMetadataValue(for key: String) -> [Int]? {
        guard let raw = userDefinedMetadata?[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let values = parts.compactMap(Int.init)
        return values.count == parts.count ? values : nil
    }
}

/// Feature names resolved to runtime roles. Exports name the same tensors
/// differently (coremltools auto-names, camelCase vs snake_case conventions),
/// so the runtimes must not assume exact names.
@available(iOS 18.0, visionOS 2.0, *)
struct CoreMLResolvedRoles: Sendable, Equatable {
    var tokenInput: String?
    var maskInput: String?
    var logitsOutput: String?
    var keyCacheState: String?
    var valueCacheState: String?

    var summary: String {
        "tokenInput=\(tokenInput ?? "<none>")"
            + " mask=\(maskInput ?? "<none>")"
            + " logits=\(logitsOutput ?? "<none>")"
            + " keyCache=\(keyCacheState ?? "<none>")"
            + " valueCache=\(valueCacheState ?? "<none>")"
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum CoreMLRoleResolver {
    private static let tokenAliases: Set<String> = ["inputids", "inputtokens", "tokens", "tokenids"]
    private static let maskAliases: Set<String> = ["causalmask", "attentionmask", "mask"]
    private static let logitsAliases: Set<String> = ["logits", "outputlogits", "logit", "lmlogits"]
    private static let keyCacheAliases: Set<String> = ["keycache", "kcache"]
    private static let valueCacheAliases: Set<String> = ["valuecache", "vcache"]

    static func normalized(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    private static func isIntegerType(_ dataType: String?) -> Bool {
        dataType?.lowercased().contains("int") == true
    }

    private static func isFloatingPointType(_ dataType: String?) -> Bool {
        guard let lowered = dataType?.lowercased() else { return false }
        return lowered.contains("float") || lowered.contains("double") || lowered.contains("fp16") || lowered.contains("fp32")
    }

    private static func match(_ features: [CoreMLArtifactFeature], aliases: Set<String>) -> String? {
        features.first { aliases.contains(normalized($0.name)) }?.name
    }

    static func resolve(metadata: CoreMLArtifactMetadata) -> CoreMLResolvedRoles {
        resolve(inputs: metadata.inputSchema, outputs: metadata.outputSchema, states: metadata.stateSchema)
    }

    static func resolve(
        inputs: [CoreMLArtifactFeature],
        outputs: [CoreMLArtifactFeature],
        states: [CoreMLArtifactFeature]
    ) -> CoreMLResolvedRoles {
        var roles = CoreMLResolvedRoles()

        roles.tokenInput = match(inputs, aliases: tokenAliases)
        if roles.tokenInput == nil {
            let integerInputs = inputs.filter { isIntegerType($0.dataType) }
            if integerInputs.count == 1 {
                roles.tokenInput = integerInputs[0].name
            }
        }

        roles.maskInput = match(inputs, aliases: maskAliases)
        if roles.maskInput == nil,
           inputs.count == 2,
           let tokenInput = roles.tokenInput,
           let other = inputs.first(where: { $0.name != tokenInput }),
           isFloatingPointType(other.dataType) {
            roles.maskInput = other.name
        }

        roles.logitsOutput = match(outputs, aliases: logitsAliases)
        if roles.logitsOutput == nil {
            if outputs.count == 1 {
                roles.logitsOutput = outputs[0].name
            } else {
                let floatOutputs = outputs.filter { isFloatingPointType($0.dataType) }
                if floatOutputs.count == 1 {
                    roles.logitsOutput = floatOutputs[0].name
                }
            }
        }

        roles.keyCacheState = match(states, aliases: keyCacheAliases)
        roles.valueCacheState = match(states, aliases: valueCacheAliases)
        for state in states where roles.keyCacheState == nil || roles.valueCacheState == nil {
            let normalizedName = normalized(state.name)
            if roles.keyCacheState == nil, state.name != roles.valueCacheState, normalizedName.contains("key") {
                roles.keyCacheState = state.name
            } else if roles.valueCacheState == nil, state.name != roles.keyCacheState, normalizedName.contains("val") {
                roles.valueCacheState = state.name
            }
        }
        // A two-state model with one role identified gives the other state the
        // remaining role (covers exports like "k"/"v" with no recognizable text).
        if states.count == 2 {
            if let key = roles.keyCacheState, roles.valueCacheState == nil,
               let other = states.first(where: { $0.name != key }) {
                roles.valueCacheState = other.name
            } else if let value = roles.valueCacheState, roles.keyCacheState == nil,
                      let other = states.first(where: { $0.name != value }) {
                roles.keyCacheState = other.name
            }
        }
        if let key = roles.keyCacheState, key == roles.valueCacheState {
            roles.valueCacheState = nil
        }

        return roles
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct ANEMLLRecommendedSampling: Sendable, Equatable {
    let doSample: Bool
    let temperature: Double
    let topP: Double
    let topK: Int
}

@available(iOS 18.0, visionOS 2.0, *)
struct ANEMLLPipelineDescriptor: Sendable {
    let metaURL: URL
    let embeddingsURL: URL
    let lmHeadURL: URL
    let ffnChunkURLs: [URL]
    let contextLength: Int
    let stateLength: Int
    let batchSize: Int
    let slidingWindow: Int?
    let updateMaskPrefill: Bool
    let prefillDynamicSlice: Bool
    let vocabSize: Int?
    let lmHeadChunkSizes: [Int]?
    let argmaxInModel: Bool
    let recommendedSampling: ANEMLLRecommendedSampling?
}

@available(iOS 18.0, visionOS 2.0, *)
struct ANEResolvedModel: Sendable {
    let modelRoot: URL
    let sourceModelURL: URL
    let compiledModelURL: URL
    let tokenizerDirectory: URL
    let flavor: CoreMLModelFlavor
    let metadata: CoreMLArtifactMetadata
    let anemllPipeline: ANEMLLPipelineDescriptor?
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEModelResolver {
    private enum ResolutionCache {
        private final class Storage: @unchecked Sendable {
            let lock = NSLock()
            var entries: [String: ANEResolvedModel] = [:]
        }

        private static let storage = Storage()

        static func value(for root: URL) -> ANEResolvedModel? {
            let key = cacheKey(for: root)
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.entries[key]
        }

        static func store(_ resolved: ANEResolvedModel, for root: URL) {
            let key = cacheKey(for: root)
            storage.lock.lock()
            storage.entries[key] = resolved
            storage.lock.unlock()
        }

        static func removeValue(for root: URL) {
            let key = cacheKey(for: root)
            storage.lock.lock()
            storage.entries.removeValue(forKey: key)
            storage.lock.unlock()
        }

        private static func cacheKey(for root: URL) -> String {
            root.resolvingSymlinksInPath().standardizedFileURL.path
        }
    }

    private struct ANEMLLArtifactCandidate {
        let sourceURL: URL
        let compiledURL: URL
        let metadata: CoreMLArtifactMetadata
    }

    enum ResolveError: LocalizedError {
        case missingCoreMLArtifact
        case missingTokenizer
        case missingMetadata
        case invalidANEMLLPipeline(reason: String)
        case unsupportedCoreMLLayout(inputs: [String], outputs: [String], states: [String], resolvedRoles: String?)

        var errorDescription: String? {
            switch self {
            case .missingCoreMLArtifact:
                return "No CML artifact found (.mlmodelc, .mlpackage, or .mlmodel)."
            case .missingTokenizer:
                return "Tokenizer files are missing for this CML/Core ML model."
            case .missingMetadata:
                return "The compiled CML model is missing metadata.json, so Noema cannot determine the runtime layout."
            case .invalidANEMLLPipeline(let reason):
                return "Invalid ANEMLL pipeline manifest. \(reason)"
            case .unsupportedCoreMLLayout(let inputs, let outputs, let states, let resolvedRoles):
                let inputSummary = inputs.isEmpty ? "<none>" : inputs.joined(separator: ", ")
                let outputSummary = outputs.isEmpty ? "<none>" : outputs.joined(separator: ", ")
                let stateSummary = states.isEmpty ? "<none>" : states.joined(separator: ", ")
                let rolesSummary = resolvedRoles.map { " resolved: \($0)" } ?? ""
                return "Unsupported CML model layout. inputs=[\(inputSummary)] outputs=[\(outputSummary)] states=[\(stateSummary)]\(rolesSummary)"
            }
        }
    }

    static func resolve(modelURL: URL) throws -> ANEResolvedModel {
        let root = modelRoot(from: modelURL)
        if let cached = ResolutionCache.value(for: root) {
            return cached
        }

        if let pipeline = try resolveANEMLLPipeline(in: root) {
            guard let tokenizerDirectory = fastANEMLLTokenizerDirectory(in: root) ?? tokenizerDirectory(in: root) else {
                throw ResolveError.missingTokenizer
            }

            let representativeURL = pipeline.ffnChunkURLs.first ?? pipeline.embeddingsURL
            let resolved = ANEResolvedModel(
                modelRoot: root,
                sourceModelURL: pipeline.metaURL,
                compiledModelURL: representativeURL,
                tokenizerDirectory: tokenizerDirectory,
                flavor: .anemllPipeline,
                metadata: CoreMLArtifactMetadata(),
                anemllPipeline: pipeline
            )
            ResolutionCache.store(resolved, for: root)
            return resolved
        }

        guard let tokenizerDirectory = tokenizerDirectory(in: root) else {
            throw ResolveError.missingTokenizer
        }

        guard let source = preferredCoreMLArtifact(in: root) else {
            throw ResolveError.missingCoreMLArtifact
        }
        let compiled = try ensureCompiledModel(from: source, modelRoot: root)
        let metadata = try readCompiledMetadata(from: compiled)
        let flavor = classify(metadata: metadata)
        guard flavor != .unknown else {
            throw ResolveError.unsupportedCoreMLLayout(
                inputs: metadata.inputNames.sorted(),
                outputs: metadata.outputNames.sorted(),
                states: metadata.stateNames.sorted(),
                resolvedRoles: CoreMLRoleResolver.resolve(metadata: metadata).summary
            )
        }

        let resolved = ANEResolvedModel(
            modelRoot: root,
            sourceModelURL: source,
            compiledModelURL: compiled,
            tokenizerDirectory: tokenizerDirectory,
            flavor: flavor,
            metadata: metadata,
            anemllPipeline: nil
        )
        ResolutionCache.store(resolved, for: root)
        return resolved
    }

    static func modelRoot(from url: URL) -> URL {
        let fixed = url.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        var isDir: ObjCBool = false

        if let artifact = enclosingCoreMLArtifact(for: fixed) {
            return artifact.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        }

        if fm.fileExists(atPath: fixed.path, isDirectory: &isDir), isDir.boolValue {
            return fixed
        }

        return fixed.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
    }

    static func enclosingCoreMLArtifact(for url: URL) -> URL? {
        let fm = FileManager.default
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL

        while true {
            let ext = candidate.pathExtension.lowercased()
            if (ext == "mlmodelc" || ext == "mlpackage" || ext == "mlmodel"),
               fm.fileExists(atPath: candidate.path) {
                return candidate
            }

            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path {
                return nil
            }
            candidate = parent
        }
    }

    static func collectCoreMLArtifacts(in root: URL) -> [URL] {
        collectCoreMLArtifacts(in: root, preferCompiledDirect: false)
    }

    static func collectCoreMLArtifacts(in root: URL, preferCompiledDirect: Bool) -> [URL] {
        let fm = FileManager.default
        var artifacts: [URL] = []

        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            while let entry = enumerator.nextObject() as? URL {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
                let ext = entry.pathExtension.lowercased()

                if isDir.boolValue {
                    if ext == "mlmodelc" || ext == "mlpackage" {
                        artifacts.append(entry)
                        enumerator.skipDescendants()
                    }
                } else if ext == "mlmodel" {
                    artifacts.append(entry)
                }
            }
        }

        return artifacts.sorted { lhs, rhs in
            let lp = sourcePriority(for: lhs, preferCompiledDirect: preferCompiledDirect)
            let rp = sourcePriority(for: rhs, preferCompiledDirect: preferCompiledDirect)
            if lp != rp { return lp < rp }
            if lhs.path.count != rhs.path.count { return lhs.path.count < rhs.path.count }
            return lhs.path < rhs.path
        }
    }

    static func preferredCoreMLArtifact(in root: URL) -> URL? {
        preferredCoreMLArtifact(in: root, preferCompiledDirect: false)
    }

    static func preferredCoreMLArtifact(in root: URL, preferCompiledDirect: Bool) -> URL? {
        collectCoreMLArtifacts(in: root, preferCompiledDirect: preferCompiledDirect).first
    }

    static func readCompiledMetadata(from compiledModelURL: URL) throws -> CoreMLArtifactMetadata {
        let metadataURL = compiledModelURL.appendingPathComponent("metadata.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw ResolveError.missingMetadata
        }

        let data = try Data(contentsOf: metadataURL)
        let entries = try JSONDecoder().decode([CoreMLArtifactMetadata].self, from: data)
        guard let metadata = entries.first else {
            throw ResolveError.missingMetadata
        }
        return metadata
    }

    static func classify(metadata: CoreMLArtifactMetadata) -> CoreMLModelFlavor {
        // swift-transformers' LanguageModel force-unwraps the exact feature names
        // "inputIds" and "logits", so this route must stay exact-match. It covers
        // both stateless exports and camelCase keyCache/valueCache stateful ones.
        if metadata.inputNames.contains("inputIds"), metadata.outputNames.contains("logits") {
            return .transformersLanguageModel
        }

        let roles = CoreMLRoleResolver.resolve(metadata: metadata)
        if roles.tokenInput != nil,
           roles.logitsOutput != nil,
           roles.keyCacheState != nil,
           roles.valueCacheState != nil {
            return .statefulCausalLM
        }

        return .unknown
    }

    static func ensureCompiledModel(from source: URL, modelRoot: URL) throws -> URL {
        let normalizedSource = source.resolvingSymlinksInPath().standardizedFileURL
        if normalizedSource.pathExtension.lowercased() == "mlmodelc" {
            return normalizedSource
        }

        let cachedURL = cachedCompiledModelURL(for: normalizedSource, modelRoot: modelRoot)
        if !needsRecompile(source: normalizedSource, cachedCompiledURL: cachedURL) {
            return cachedURL
        }

        let compiledTmp = try MLModel.compileModel(at: normalizedSource)
        if FileManager.default.fileExists(atPath: cachedURL.path) {
            _ = try FileManager.default.replaceItemAt(cachedURL, withItemAt: compiledTmp)
        } else {
            try FileManager.default.moveItem(at: compiledTmp, to: cachedURL)
        }
        return cachedURL
    }

    static func cachedCompiledModelURL(for source: URL, modelRoot: URL) -> URL {
        if let cached = try? CoreMLCompileCache.cachedCompiledModelURL(for: source, modelRoot: modelRoot) {
            return cached
        }

        let fallbackCacheDir = modelRoot.appendingPathComponent(".coreml-compiled", isDirectory: true)
        return fallbackCacheDir.appendingPathComponent(
            source.deletingPathExtension().lastPathComponent + ".mlmodelc",
            isDirectory: true
        )
    }

    static func needsRecompile(source: URL, cachedCompiledURL: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: cachedCompiledURL.path) else {
            return true
        }

        guard let sourceDate = contentModificationDate(of: source),
              let cachedDate = contentModificationDate(of: cachedCompiledURL) else {
            return true
        }

        return sourceDate > cachedDate
    }

    private static func sourcePriority(for url: URL, preferCompiledDirect: Bool) -> Int {
        switch url.pathExtension.lowercased() {
        case "mlmodelc":
            return preferCompiledDirect ? 0 : 2
        case "mlpackage":
            return preferCompiledDirect ? 1 : 0
        case "mlmodel":
            return preferCompiledDirect ? 2 : 1
        default:
            return 9
        }
    }

    private static func contentModificationDate(of url: URL) -> Date? {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attributes[.modificationDate] as? Date {
            return date
        }
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private struct ANEMLLManifest {
        let contextLength: Int
        let stateLength: Int
        let batchSize: Int
        let numChunks: Int
        let embeddingsPath: String
        let lmHeadPath: String
        let ffnPath: String
        let slidingWindow: Int?
        let updateMaskPrefill: Bool
        let prefillDynamicSlice: Bool
        let vocabSize: Int?
        let lmHeadChunkSizes: [Int]?
        let argmaxInModel: Bool
        let recommendedSampling: ANEMLLRecommendedSampling?
    }

    private static func resolveANEMLLPipeline(in root: URL) throws -> ANEMLLPipelineDescriptor? {
        if let metaURL = existingANEMLLManifestURL(in: root) {
            return try resolveANEMLLPipeline(fromManifestAt: metaURL, in: root)
        }

        return try inferANEMLLPipeline(in: root)
    }

    private static func existingANEMLLManifestURL(in root: URL) -> URL? {
        for fileName in ["meta.yaml", "meta.yml"] {
            let candidate = root.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func resolveANEMLLPipeline(fromManifestAt metaURL: URL, in root: URL) throws -> ANEMLLPipelineDescriptor {
        let manifest = try parseANEMLLManifest(at: metaURL)
        guard let embeddingsURL = resolveANEMLLComponent(at: manifest.embeddingsPath, in: root) else {
            throw ResolveError.invalidANEMLLPipeline(reason: "Missing embeddings component `\(manifest.embeddingsPath)`.")
        }
        guard let lmHeadURL = resolveANEMLLComponent(at: manifest.lmHeadPath, in: root) else {
            throw ResolveError.invalidANEMLLPipeline(reason: "Missing LM head component `\(manifest.lmHeadPath)`.")
        }
        guard let firstChunkURL = resolveANEMLLComponent(at: manifest.ffnPath, in: root) else {
            throw ResolveError.invalidANEMLLPipeline(reason: "Missing FFN component `\(manifest.ffnPath)`.")
        }

        let ffnChunkURLs = try resolveANEMLLChunkURLs(
            firstChunkURL: firstChunkURL,
            expectedCount: manifest.numChunks
        )

        return ANEMLLPipelineDescriptor(
            metaURL: metaURL,
            embeddingsURL: embeddingsURL,
            lmHeadURL: lmHeadURL,
            ffnChunkURLs: ffnChunkURLs,
            contextLength: manifest.contextLength,
            stateLength: manifest.stateLength,
            batchSize: manifest.batchSize,
            slidingWindow: manifest.slidingWindow,
            updateMaskPrefill: manifest.updateMaskPrefill,
            prefillDynamicSlice: manifest.prefillDynamicSlice,
            vocabSize: manifest.vocabSize,
            lmHeadChunkSizes: manifest.lmHeadChunkSizes,
            argmaxInModel: manifest.argmaxInModel,
            recommendedSampling: manifest.recommendedSampling
        )
    }

    private static func inferANEMLLPipeline(in root: URL) throws -> ANEMLLPipelineDescriptor? {
        let artifacts = collectCoreMLArtifacts(in: root, preferCompiledDirect: true)
        guard artifacts.count >= 3 else { return nil }

        var embeddingCandidates: [ANEMLLArtifactCandidate] = []
        var lmHeadCandidates: [ANEMLLArtifactCandidate] = []
        var ffnCandidates: [ANEMLLArtifactCandidate] = []

        for source in artifacts {
            let compiled = try ensureCompiledModel(from: source, modelRoot: root)
            guard let metadata = try? readCompiledMetadata(from: compiled) else { continue }
            let candidate = ANEMLLArtifactCandidate(sourceURL: source, compiledURL: compiled, metadata: metadata)

            if isANEMLLEmbeddings(candidate) {
                embeddingCandidates.append(candidate)
            } else if isANEMLLLMHead(candidate) {
                lmHeadCandidates.append(candidate)
            } else if isANEMLLFFN(candidate) {
                ffnCandidates.append(candidate)
            }
        }

        guard let embeddings = bestANEMLLEmbeddingsCandidate(from: embeddingCandidates),
              let lmHead = bestANEMLLLMHeadCandidate(from: lmHeadCandidates),
              !ffnCandidates.isEmpty else {
            return nil
        }

        let sortedFFN = sortANEMLLFFNCandidates(ffnCandidates)
        let contextLength = inferANEMLLContextLength(
            from: [embeddings.metadata, lmHead.metadata] + sortedFFN.map(\.metadata),
            modelRoot: root
        ) ?? 2048
        let stateLength = inferANEMLLStateLength(
            from: [embeddings.metadata, lmHead.metadata] + sortedFFN.map(\.metadata),
            fallbackContextLength: contextLength
        )
        let batchSize = sortedFFN.compactMap { candidate in
            candidate.metadata.intMetadataValue(for: "com.anemll.batch_size")
        }.first ?? 64
        let slidingWindow = sortedFFN.compactMap { candidate in
            candidate.metadata.intMetadataValue(for: "com.anemll.sliding_window")
        }.first
        let updateMaskPrefill = sortedFFN.contains { candidate in
            candidate.metadata.boolMetadataValue(for: "com.anemll.update_mask_prefill") == true
                || candidate.metadata.inputNames.contains("update_mask")
        }
        let prefillDynamicSlice = sortedFFN.contains { candidate in
            candidate.metadata.boolMetadataValue(for: "com.anemll.prefill_dynamic_slice") == true
        }
        let vocabSize = lmHead.metadata.intMetadataValue(for: "com.anemll.vocab_size")
        let lmHeadChunkSizes = lmHead.metadata.intArrayMetadataValue(for: "com.anemll.lm_head_chunk_sizes")
        let argmaxInModel = sortedFFN.contains { candidate in
            candidate.metadata.boolMetadataValue(for: "com.anemll.argmax_in_model") == true
        } || lmHead.metadata.boolMetadataValue(for: "com.anemll.argmax_in_model") == true

        return ANEMLLPipelineDescriptor(
            metaURL: root,
            embeddingsURL: embeddings.compiledURL,
            lmHeadURL: lmHead.compiledURL,
            ffnChunkURLs: sortedFFN.map(\.compiledURL),
            contextLength: contextLength,
            stateLength: stateLength,
            batchSize: batchSize,
            slidingWindow: slidingWindow,
            updateMaskPrefill: updateMaskPrefill,
            prefillDynamicSlice: prefillDynamicSlice,
            vocabSize: vocabSize,
            lmHeadChunkSizes: lmHeadChunkSizes,
            argmaxInModel: argmaxInModel,
            recommendedSampling: nil
        )
    }

    private static func isANEMLLEmbeddings(_ candidate: ANEMLLArtifactCandidate) -> Bool {
        let inputs = candidate.metadata.inputNames
        let outputs = candidate.metadata.outputNames
        return inputs == ["input_ids"]
            && outputs.contains("hidden_states")
            && candidate.metadata.stateNames.isEmpty
    }

    private static func isANEMLLLMHead(_ candidate: ANEMLLArtifactCandidate) -> Bool {
        let inputs = candidate.metadata.inputNames
        let outputs = candidate.metadata.outputNames
        let hasLogitsOutputs = outputs.contains("logits")
            || outputs.contains(where: { $0.hasPrefix("logits") })
        let hasArgmaxOutputs = outputs.contains("argmax_idx")
            && outputs.contains("argmax_val")
        return inputs.contains("hidden_states")
            && (hasLogitsOutputs || hasArgmaxOutputs)
            && candidate.metadata.stateNames.isEmpty
    }

    private static func isANEMLLFFN(_ candidate: ANEMLLArtifactCandidate) -> Bool {
        let inputs = candidate.metadata.inputNames
        let outputs = candidate.metadata.outputNames
        let requiredInputs: Set<String> = ["hidden_states", "position_ids", "causal_mask", "current_pos"]
        return requiredInputs.isSubset(of: inputs)
            && outputs.contains("output_hidden_states")
    }

    private static func bestANEMLLEmbeddingsCandidate(from candidates: [ANEMLLArtifactCandidate]) -> ANEMLLArtifactCandidate? {
        candidates.sorted { lhs, rhs in
            let lName = lhs.sourceURL.lastPathComponent.lowercased()
            let rName = rhs.sourceURL.lastPathComponent.lowercased()
            let lPreferred = lName.contains("embedding")
            let rPreferred = rName.contains("embedding")
            if lPreferred != rPreferred { return lPreferred && !rPreferred }
            if lhs.sourceURL.path.count != rhs.sourceURL.path.count { return lhs.sourceURL.path.count < rhs.sourceURL.path.count }
            return lhs.sourceURL.path < rhs.sourceURL.path
        }.first
    }

    private static func bestANEMLLLMHeadCandidate(from candidates: [ANEMLLArtifactCandidate]) -> ANEMLLArtifactCandidate? {
        candidates.sorted { lhs, rhs in
            let lName = lhs.sourceURL.lastPathComponent.lowercased()
            let rName = rhs.sourceURL.lastPathComponent.lowercased()
            let lPreferred = lName.contains("lm_head") || lName.contains("lmhead")
            let rPreferred = rName.contains("lm_head") || rName.contains("lmhead")
            if lPreferred != rPreferred { return lPreferred && !rPreferred }
            if lhs.sourceURL.path.count != rhs.sourceURL.path.count { return lhs.sourceURL.path.count < rhs.sourceURL.path.count }
            return lhs.sourceURL.path < rhs.sourceURL.path
        }.first
    }

    private static func sortANEMLLFFNCandidates(_ candidates: [ANEMLLArtifactCandidate]) -> [ANEMLLArtifactCandidate] {
        candidates.sorted { lhs, rhs in
            let lChunk = lhs.metadata.intMetadataValue(for: "com.anemll.chunk_no") ?? chunkNumber(in: lhs.sourceURL.lastPathComponent) ?? Int.max
            let rChunk = rhs.metadata.intMetadataValue(for: "com.anemll.chunk_no") ?? chunkNumber(in: rhs.sourceURL.lastPathComponent) ?? Int.max
            if lChunk != rChunk { return lChunk < rChunk }
            return lhs.sourceURL.path < rhs.sourceURL.path
        }
    }

    private static func inferANEMLLContextLength(from metadatas: [CoreMLArtifactMetadata], modelRoot: URL) -> Int? {
        if let contextLength = metadatas.compactMap({ metadata in
            metadata.intMetadataValue(for: "com.anemll.context_length")
        }).first {
            return contextLength
        }

        let candidates = [modelRoot.lastPathComponent, modelRoot.deletingLastPathComponent().lastPathComponent]
        for name in candidates {
            if let range = name.range(of: #"ctx(\d+)"#, options: .regularExpression) {
                let digits = name[range].dropFirst(3)
                if let contextLength = Int(digits) {
                    return contextLength
                }
            }
        }
        return nil
    }

    private static func inferANEMLLStateLength(from metadatas: [CoreMLArtifactMetadata], fallbackContextLength: Int) -> Int {
        metadatas.compactMap { metadata in
            metadata.intMetadataValue(for: "com.anemll.state_length")
        }.first ?? fallbackContextLength
    }

    private static func chunkNumber(in fileName: String) -> Int? {
        guard let range = fileName.range(of: #"_chunk_(\d+)of\d+"#, options: .regularExpression) else {
            return nil
        }
        let match = String(fileName[range])
        guard let digitsRange = match.range(of: #"\d+"#, options: .regularExpression) else {
            return nil
        }
        return Int(match[digitsRange])
    }

    private static func parseANEMLLManifest(at metaURL: URL) throws -> ANEMLLManifest {
        let text = try String(contentsOf: metaURL, encoding: .utf8)
        var inParameters = false
        var values: [String: String] = [:]
        var nestedValues: [String: [String: String]] = [:]
        var currentNestedKey: String?

        for line in text.split(whereSeparator: \.isNewline) {
            let raw = String(line)
            if raw.hasPrefix("  parameters:") {
                inParameters = true
                currentNestedKey = nil
                continue
            }
            if inParameters, !raw.hasPrefix("    ") {
                inParameters = false
                currentNestedKey = nil
            }
            guard inParameters else { continue }

            if raw.hasPrefix("      "), let currentNestedKey {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.firstIndex(of: ":") else { continue }
                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
                nestedValues[currentNestedKey, default: [:]][key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                continue
            }

            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                currentNestedKey = key
            } else {
                currentNestedKey = nil
                values[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        guard
            let embeddingsPath = values["embeddings"], !embeddingsPath.isEmpty,
            let lmHeadPath = values["lm_head"], !lmHeadPath.isEmpty,
            let ffnPath = values["ffn"], !ffnPath.isEmpty
        else {
            throw ResolveError.invalidANEMLLPipeline(reason: "Expected `embeddings`, `lm_head`, and `ffn` entries under `model_info.parameters` in meta.yaml.")
        }

        let contextLength = Int(values["context_length"] ?? "") ?? 2048
        let stateLength = Int(values["state_length"] ?? "") ?? contextLength
        let batchSize = Int(values["batch_size"] ?? "") ?? 64
        let numChunks = max(1, Int(values["num_chunks"] ?? "") ?? 1)
        let slidingWindow = Int(values["sliding_window"] ?? "")
        let updateMaskPrefill = boolValue(from: values["update_mask_prefill"]) ?? false
        let prefillDynamicSlice = boolValue(from: values["prefill_dynamic_slice"]) ?? false
        let vocabSize = Int(values["vocab_size"] ?? "")
        let lmHeadChunkSizes = intArrayValue(from: values["lm_head_chunk_sizes"])
        let argmaxInModel = boolValue(from: values["argmax_in_model"]) ?? false
        let recommendedSampling: ANEMLLRecommendedSampling? = {
            guard let sampling = nestedValues["recommended_sampling"],
                  let temperature = doubleValue(from: sampling["temperature"]),
                  let topP = doubleValue(from: sampling["top_p"] ?? sampling["topP"]),
                  let topK = Int(sampling["top_k"] ?? sampling["topK"] ?? "") else {
                return nil
            }
            return ANEMLLRecommendedSampling(
                doSample: boolValue(from: sampling["do_sample"]) ?? true,
                temperature: temperature,
                topP: topP,
                topK: topK
            )
        }()

        return ANEMLLManifest(
            contextLength: contextLength,
            stateLength: stateLength,
            batchSize: batchSize,
            numChunks: numChunks,
            embeddingsPath: embeddingsPath,
            lmHeadPath: lmHeadPath,
            ffnPath: ffnPath,
            slidingWindow: slidingWindow,
            updateMaskPrefill: updateMaskPrefill,
            prefillDynamicSlice: prefillDynamicSlice,
            vocabSize: vocabSize,
            lmHeadChunkSizes: lmHeadChunkSizes,
            argmaxInModel: argmaxInModel,
            recommendedSampling: recommendedSampling
        )
    }

    private static func boolValue(from raw: String?) -> Bool? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "true", "1", "yes", "on":
            return true
        case "false", "0", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func doubleValue(from raw: String?) -> Double? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return Double(raw)
    }

    private static func intArrayValue(from raw: String?) -> [Int]? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        let values = parts.compactMap(Int.init)
        return values.count == parts.count ? values : nil
    }

    private static func resolveANEMLLComponent(at relativePath: String, in root: URL) -> URL? {
        let cleaned = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let baseURL = root.appendingPathComponent(cleaned)
        let fm = FileManager.default
        if fm.fileExists(atPath: baseURL.path) {
            let normalized = baseURL.resolvingSymlinksInPath().standardizedFileURL
            if normalized.pathExtension.lowercased() == "mlpackage" || normalized.pathExtension.lowercased() == "mlmodel" {
                let compiledSibling = normalized.deletingPathExtension().appendingPathExtension("mlmodelc")
                if fm.fileExists(atPath: compiledSibling.path) {
                    return compiledSibling.resolvingSymlinksInPath().standardizedFileURL
                }
            }
            return normalized
        }

        guard baseURL.pathExtension.isEmpty else { return nil }

        for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
            let candidate = baseURL.appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) {
                return candidate.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        return nil
    }

    private static func resolveANEMLLChunkURLs(firstChunkURL: URL, expectedCount: Int) throws -> [URL] {
        guard expectedCount > 1 else { return [firstChunkURL] }

        let directory = firstChunkURL.deletingLastPathComponent()
        let name = firstChunkURL.lastPathComponent
        guard let match = name.range(of: #"_chunk_\d+of\d+"#, options: .regularExpression) else {
            throw ResolveError.invalidANEMLLPipeline(
                reason: "FFN component `\(name)` does not use `_chunk_NNofNN` naming."
            )
        }

        let prefix = String(name[..<match.lowerBound])
        let suffix = String(name[match.upperBound...])
        let regex = try NSRegularExpression(
            pattern: "^\(NSRegularExpression.escapedPattern(for: prefix))_chunk_(\\d+)of(\\d+)\(NSRegularExpression.escapedPattern(for: suffix))$"
        )

        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let chunkURLs = files.compactMap { file -> (Int, URL)? in
            let fileName = file.lastPathComponent
            let range = NSRange(location: 0, length: fileName.utf16.count)
            guard let result = regex.firstMatch(in: fileName, options: [], range: range),
                  let chunkRange = Range(result.range(at: 1), in: fileName),
                  let totalRange = Range(result.range(at: 2), in: fileName),
                  let chunkIndex = Int(fileName[chunkRange]),
                  let totalChunks = Int(fileName[totalRange]),
                  totalChunks == expectedCount else {
                return nil
            }
            return (chunkIndex, file)
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)

        guard chunkURLs.count == expectedCount else {
            throw ResolveError.invalidANEMLLPipeline(
                reason: "Expected \(expectedCount) FFN chunks but found \(chunkURLs.count)."
            )
        }

        return chunkURLs
    }

    private static func fastANEMLLTokenizerDirectory(in root: URL) -> URL? {
        let fm = FileManager.default
        let preferredNames: Set<String> = [
            "tokenizer.json",
            "tokenizer.model",
            "spiece.model",
            "sentencepiece.bpe.model",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "vocab.json",
            "vocab.txt",
            "merges.txt"
        ]

        func containsTokenizer(in directory: URL) -> Bool {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
            return files.contains { file in
                preferredNames.contains(file.lastPathComponent.lowercased())
            }
        }

        if containsTokenizer(in: root) {
            return root
        }

        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return nil
        }

        for entry in files {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            if containsTokenizer(in: entry) {
                return entry
            }
        }

        return nil
    }

    private static func tokenizerDirectory(in root: URL) -> URL? {
        let fm = FileManager.default
        let preferredNames: Set<String> = [
            "tokenizer.json",
            "tokenizer.model",
            "spiece.model",
            "sentencepiece.bpe.model",
            "tokenizer_config.json",
            "special_tokens_map.json",
            "vocab.json",
            "vocab.txt",
            "merges.txt"
        ]

        func containsTokenizer(in directory: URL) -> Bool {
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return false }
            return files.contains { file in
                preferredNames.contains(file.lastPathComponent.lowercased())
            }
        }

        if containsTokenizer(in: root) {
            return root
        }

        if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            while let entry = enumerator.nextObject() as? URL {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { continue }
                if preferredNames.contains(entry.lastPathComponent.lowercased()) {
                    return entry.deletingLastPathComponent()
                }
            }
        }

        return nil
    }

    static func precompilePreferredArtifact(in modelURL: URL) throws -> URL? {
        let root = modelRoot(from: modelURL)
        let artifacts = collectCoreMLArtifacts(in: root)
        if artifacts.contains(where: { $0.pathExtension.lowercased() == "mlmodelc" }) {
            return nil
        }
        guard let source = preferredCoreMLArtifact(in: root),
              source.pathExtension.lowercased() != "mlmodelc" else {
            return nil
        }
        return try ensureCompiledModel(from: source, modelRoot: root)
    }

    static func removeCompiledCache(for modelURL: URL) throws {
        let root = modelRoot(from: modelURL)
        try CoreMLCompileCache.removeCache(for: root)
        ResolutionCache.removeValue(for: root)
    }

    static func validateDownloadedANEMLLInstall(in modelURL: URL) throws -> ANEMLLPipelineDescriptor {
        let root = modelRoot(from: modelURL)
        guard let metaURL = existingANEMLLManifestURL(in: root) else {
            throw ResolveError.invalidANEMLLPipeline(reason: "Missing meta.yaml.")
        }
        guard tokenizerDirectory(in: root) != nil else {
            throw ResolveError.missingTokenizer
        }

        let pipeline = try resolveANEMLLPipeline(fromManifestAt: metaURL, in: root)
        let components: [(String, URL)] =
            [("embeddings", pipeline.embeddingsURL), ("lm_head", pipeline.lmHeadURL)] +
            pipeline.ffnChunkURLs.enumerated().map { ("ffn_chunk_\($0.offset + 1)", $0.element) }

        for (label, url) in components {
            try validateDownloadedANEMLLCompiledComponent(at: url, label: label)
        }

        return pipeline
    }

    private static func validateDownloadedANEMLLCompiledComponent(at url: URL, label: String) throws {
        let fm = FileManager.default
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard normalized.pathExtension.lowercased() == "mlmodelc" else {
            throw ResolveError.invalidANEMLLPipeline(reason: "`\(label)` must be downloaded as an unzipped .mlmodelc bundle.")
        }
        let metadataURL = normalized.appendingPathComponent("metadata.json")
        let weightsURL = normalized.appendingPathComponent("weights", isDirectory: true)
        guard fm.fileExists(atPath: metadataURL.path) else {
            throw ResolveError.invalidANEMLLPipeline(reason: "`\(label)` is missing metadata.json.")
        }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: weightsURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw ResolveError.invalidANEMLLPipeline(reason: "`\(label)` is missing the weights directory.")
        }
        let weightFiles = (try? fm.contentsOfDirectory(at: weightsURL, includingPropertiesForKeys: nil)) ?? []
        guard weightFiles.contains(where: {
            let file = $0.lastPathComponent.lowercased()
            return file == "weight.bin" || file.hasSuffix(".bin")
        }) else {
            throw ResolveError.invalidANEMLLPipeline(reason: "`\(label)` is missing model weights.")
        }
    }
}
#endif
