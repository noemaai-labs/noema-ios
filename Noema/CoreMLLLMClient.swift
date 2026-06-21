import Foundation

#if canImport(CoreML) && (os(iOS) || os(visionOS))
@preconcurrency import CoreML
import CoreVideo
@preconcurrency import Generation
@preconcurrency import Models
@preconcurrency import Tokenizers

private enum CoreMLTokenizerCache {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var tokenizers: [String: any Tokenizer] = [:]
    }

    private static let storage = Storage()

    static func value(for modelFolder: URL) -> (any Tokenizer)? {
        let key = cacheKey(for: modelFolder)
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.tokenizers[key]
    }

    static func store(_ tokenizer: any Tokenizer, for modelFolder: URL) {
        let key = cacheKey(for: modelFolder)
        storage.lock.lock()
        storage.tokenizers[key] = tokenizer
        storage.lock.unlock()
    }

    private static func cacheKey(for modelFolder: URL) -> String {
        modelFolder.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

@available(iOS 18.0, visionOS 2.0, *)
final actor CoreMLLLMClient {
    private enum State {
        case idle
        case loaded
    }

    private let resolvedModel: ANEResolvedModel
    private var settings: ModelSettings
    private var runtime: any CoreMLTextRuntime
    private var state: State = .idle
    private var activeGenerationTask: Task<Void, Never>?
    private var systemPrompt: String?
    private var runtimeLoadDiagnostics: String?

    init(resolvedModel: ANEResolvedModel, settings: ModelSettings) throws {
        self.resolvedModel = resolvedModel
        self.settings = settings
        self.runtime = EmptyCoreMLRuntime()
    }

    func load() async throws {
        guard state == .idle else { return }
        runtimeLoadDiagnostics = nil
        let tokenizer = try await Self.tokenizer(for: resolvedModel.tokenizerDirectory)
        let strategy = Self.loadStrategy(for: settings, flavor: resolvedModel.flavor)
        var failures: [(MLComputeUnits, Error)] = []

        for computeUnits in strategy.computeUnits {
            do {
                let nextRuntime = try await makeRuntime(tokenizer: tokenizer, computeUnits: computeUnits)
                runtime = nextRuntime
                runtimeLoadDiagnostics = Self.makeLoadDiagnostics(
                    strategy: strategy,
                    selectedComputeUnits: computeUnits,
                    failedComputeUnits: failures.map(\.0),
                    runtimeSummary: nextRuntime.loadDiagnosticSummary
                )
                state = .loaded
                return
            } catch {
                if error is StatefulCMLCompatibilityError {
                    throw error
                }
                failures.append((computeUnits, error))
            }
        }

        throw loadError(from: failures, strategy: strategy)
    }

    func unload() {
        cancelActive()
        runtime.unload()
        runtime = EmptyCoreMLRuntime()
        state = .idle
        runtimeLoadDiagnostics = nil
    }

    func cancelActive() {
        activeGenerationTask?.cancel()
        activeGenerationTask = nil
    }

    func hardResetConversation() {
        // Stateless generation; nothing to reset in this phase.
    }

    func syncSystemPrompt(_ prompt: String?) {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        systemPrompt = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func loadDiagnosticsSummary() -> String? {
        runtimeLoadDiagnostics
    }

    func countTokens(in prompt: String) async throws -> Int {
        let tokenizer = try await Self.tokenizer(for: resolvedModel.tokenizerDirectory)
        let promptTokens = tokenizer.encode(text: prompt)
        if !promptTokens.isEmpty {
            return promptTokens.count
        }
        return tokenizer.bosTokenId == nil ? 0 : 1
    }

    func textStream(from input: LLMInput) async throws -> AsyncThrowingStream<String, Error> {
        try await load()

        let prompt = Self.resolvedPromptText(for: input, systemPrompt: systemPrompt)
        let config = generationConfig()
        let runtime = self.runtime

        return AsyncThrowingStream { continuation in
            let generationTask = Task {
                let emittedText = LockIsolated("")
                let emitDelta: @Sendable (String) -> Void = { fullText in
                    emittedText.withMutableValue { currentText in
                        guard fullText != currentText else { return }
                        if fullText.hasPrefix(currentText) {
                            let delta = String(fullText.dropFirst(currentText.count))
                            if !delta.isEmpty {
                                continuation.yield(delta)
                            }
                            currentText = fullText
                        } else if currentText.hasSuffix(fullText) {
                            return
                        } else {
                            let maxOverlap = min(currentText.count, fullText.count)
                            var overlap = 0

                            if maxOverlap > 0 {
                                var candidate = maxOverlap
                                while candidate > 0 {
                                    if currentText.suffix(candidate) == fullText.prefix(candidate) {
                                        overlap = candidate
                                        break
                                    }
                                    candidate -= 1
                                }
                            }

                            let delta = overlap > 0 ? String(fullText.dropFirst(overlap)) : fullText
                            if !delta.isEmpty {
                                continuation.yield(delta)
                                currentText += delta
                            }
                        }
                    }
                }

                do {
                    let output = try await runtime.generate(prompt: prompt, config: config, onPartialText: emitDelta)

                    if !Task.isCancelled {
                        emitDelta(output)
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: CancellationError())
                    }
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                    } else {
                        continuation.finish(throwing: error)
                    }
                }

                self.setActiveTask(nil)
            }

            continuation.onTermination = { [weak self] _ in
                generationTask.cancel()
                Task {
                    await self?.cancelActive()
                }
            }

            Task {
                self.setActiveTask(generationTask)
            }
        }
    }

    private func setActiveTask(_ task: Task<Void, Never>?) {
        activeGenerationTask = task
    }

    private static func tokenizer(for modelFolder: URL) async throws -> any Tokenizer {
        if let cached = CoreMLTokenizerCache.value(for: modelFolder) {
            return cached
        }

        let tokenizer = try await AutoTokenizer.from(modelFolder: modelFolder)
        CoreMLTokenizerCache.store(tokenizer, for: modelFolder)
        return tokenizer
    }

    private func makeRuntime(tokenizer: any Tokenizer, computeUnits: MLComputeUnits) async throws -> any CoreMLTextRuntime {
        switch resolvedModel.flavor {
        case .transformersLanguageModel:
            return try TransformersCoreMLRuntime(
                resolvedModel: resolvedModel,
                tokenizer: tokenizer,
                computeUnits: computeUnits
            )
        case .statefulCausalLM:
            return try await StatefulCausalCoreMLRuntime(
                resolvedModel: resolvedModel,
                tokenizer: tokenizer,
                computeUnits: computeUnits
            )
        case .anemllPipeline:
            return try await ANEMLLCoreMLRuntime(
                resolvedModel: resolvedModel,
                tokenizer: tokenizer,
                computeUnits: computeUnits
            )
        case .unknown:
            throw NSError(
                domain: "Noema.CoreML",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported CML model layout."]
            )
        }
    }

    private func loadError(from failures: [(MLComputeUnits, Error)], strategy: CoreMLLoadStrategy) -> Error {
        let attemptedUnits = failures.map { Self.computeUnitsName($0.0) }
        let lastError = failures.last?.1
        let modelName = resolvedModel.sourceModelURL.lastPathComponent
        let sourceName: String = {
            let ext = resolvedModel.sourceModelURL.pathExtension.lowercased()
            if ext == "mlmodelc" {
                return "compiled bundle"
            }
            if resolvedModel.sourceModelURL.lastPathComponent.lowercased() == "meta.yaml" {
                return "pipeline manifest"
            }
            return "source artifact"
        }()
        let description = [
            "Failed to load CML model `\(modelName)`.",
            "runtime=\(resolvedModel.flavor.rawValue)",
            "source=\(sourceName)",
            strategy.requestedConfiguration.map { "requestedComputeUnits=\($0.displayName)" },
            attemptedUnits.isEmpty ? nil : "effectiveComputeUnits=\(attemptedUnits.joined(separator: " -> "))",
            strategy.restrictionReason,
            lastError.map { "lastError=\($0.localizedDescription)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return NSError(
            domain: "Noema.CoreML",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    static func resolvedPromptText(for input: LLMInput, systemPrompt: String?) -> String {
        switch input.content {
        case .plain(let text):
            return text
        case .messages(let messages):
            let flattened = messages
                .map { "\($0.role): \($0.content)" }
                .joined(separator: "\n")
            let hasExplicitSystem = messages.contains { $0.role.compare("system", options: .caseInsensitive) == .orderedSame }
            guard let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !systemPrompt.isEmpty,
                  !hasExplicitSystem else {
                return flattened
            }
            return "System: \(systemPrompt)\n\n\(flattened)"
        case .multimodal(let text, _):
            return text
        case .multimodalMessages(let messages, _):
            let flattened = messages
                .map { "\($0.role): \($0.content)" }
                .joined(separator: "\n")
            let hasExplicitSystem = messages.contains { $0.role.compare("system", options: .caseInsensitive) == .orderedSame }
            guard let systemPrompt = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !systemPrompt.isEmpty,
                  !hasExplicitSystem else {
                return flattened
            }
            return "System: \(systemPrompt)\n\n\(flattened)"
        }
    }

    private func generationConfig() -> GenerationConfig {
        let maxNewTokens = max(1, Int(min(settings.contextLength.rounded(.down), 4096)))
        let sampling = resolvedModel.flavor == .anemllPipeline
            ? ANEMLLSamplingConfigResolver.resolve(settings: settings, pipeline: resolvedModel.anemllPipeline)
            : (
                doSample: settings.temperature > 0.0,
                temperature: Float(max(0.0, settings.temperature)),
                topK: max(1, settings.topK),
                topP: Float(max(0.0, min(1.0, settings.topP)))
            )
        let minP: Float? = settings.minP > 0 ? Float(max(0.0, min(1.0, settings.minP))) : nil
        let repetitionPenalty = max(0.01, settings.repetitionPenalty)

        return GenerationConfig(
            maxLength: Int.max / 4,
            maxNewTokens: maxNewTokens,
            doSample: sampling.doSample,
            temperature: sampling.temperature,
            topK: sampling.topK,
            topP: sampling.topP,
            minP: minP,
            repetitionPenalty: repetitionPenalty
        )
    }

    static func loadStrategy(for settings: ModelSettings, flavor: CoreMLModelFlavor) -> CoreMLLoadStrategy {
        if flavor == .anemllPipeline {
            switch settings.processingUnitConfiguration {
            case nil:
                return CoreMLLoadStrategy(
                    computeUnits: [.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly],
                    isAutomatic: true,
                    requestedConfiguration: settings.processingUnitConfiguration,
                    restrictionReason: "note=ANEMLL pipelines prefer CPU + Neural Engine, but fall back to CPU + GPU or CPU Only if Core ML cannot build an ANE execution plan."
                )
            case .some(.all):
                return CoreMLLoadStrategy(
                    computeUnits: [.all, .cpuAndGPU, .cpuOnly],
                    isAutomatic: false,
                    requestedConfiguration: settings.processingUnitConfiguration,
                    restrictionReason: nil
                )
            case .some(.cpuOnly):
                return CoreMLLoadStrategy(
                    computeUnits: [.cpuOnly],
                    isAutomatic: false,
                    requestedConfiguration: settings.processingUnitConfiguration,
                    restrictionReason: nil
                )
            case .some(.cpuAndGPU):
                return CoreMLLoadStrategy(
                    computeUnits: [.cpuAndGPU],
                    isAutomatic: false,
                    requestedConfiguration: settings.processingUnitConfiguration,
                    restrictionReason: nil
                )
            case .some(.cpuAndNeuralEngine):
                return CoreMLLoadStrategy(
                    computeUnits: [.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly],
                    isAutomatic: false,
                    requestedConfiguration: settings.processingUnitConfiguration,
                    restrictionReason: "note=CPU + Neural Engine is attempted first, but ANEMLL pipelines may fall back to CPU + GPU or CPU Only if Core ML cannot build an ANE execution plan."
                )
            }
        }

        switch settings.processingUnitConfiguration {
        case nil:
            return CoreMLLoadStrategy(
                computeUnits: [.all, .cpuAndGPU, .cpuOnly],
                isAutomatic: true,
                requestedConfiguration: settings.processingUnitConfiguration,
                restrictionReason: nil
            )
        case .some(.all):
            return CoreMLLoadStrategy(
                computeUnits: [.all, .cpuAndGPU, .cpuOnly],
                isAutomatic: false,
                requestedConfiguration: settings.processingUnitConfiguration,
                restrictionReason: nil
            )
        case .some(.cpuOnly):
            return CoreMLLoadStrategy(
                computeUnits: [.cpuOnly],
                isAutomatic: false,
                requestedConfiguration: settings.processingUnitConfiguration,
                restrictionReason: nil
            )
        case .some(.cpuAndGPU):
            return CoreMLLoadStrategy(
                computeUnits: [.cpuAndGPU],
                isAutomatic: false,
                requestedConfiguration: settings.processingUnitConfiguration,
                restrictionReason: nil
            )
        case .some(.cpuAndNeuralEngine):
            if flavor == .statefulCausalLM {
                return CoreMLLoadStrategy(
                    computeUnits: [.cpuAndNeuralEngine, .cpuAndGPU, .cpuOnly],
                    isAutomatic: false,
                    requestedConfiguration: settings.processingUnitConfiguration,
                    restrictionReason: "note=CPU + Neural Engine is attempted first, but stateful CML models may fall back to CPU + GPU or CPU Only if Core ML cannot build an ANE execution plan."
                )
            }

            return CoreMLLoadStrategy(
                computeUnits: [.cpuAndNeuralEngine],
                isAutomatic: false,
                requestedConfiguration: settings.processingUnitConfiguration,
                restrictionReason: nil
            )
        }
    }

    static func computeUnitsName(_ computeUnits: MLComputeUnits) -> String {
        switch computeUnits {
        case .all:
            return "All"
        case .cpuOnly:
            return "CPU Only"
        case .cpuAndGPU:
            return "CPU + GPU"
        case .cpuAndNeuralEngine:
            return "CPU + Neural Engine"
        @unknown default:
            return "Unknown"
        }
    }

    private static func makeLoadDiagnostics(
        strategy: CoreMLLoadStrategy,
        selectedComputeUnits: MLComputeUnits,
        failedComputeUnits: [MLComputeUnits],
        runtimeSummary: String?
    ) -> String {
        [
            strategy.requestedConfiguration.map { "requestedComputeUnits=\($0.displayName)" },
            "automaticComputeSelection=\(strategy.isAutomatic)",
            strategy.computeUnits.count > 1
                ? "computeUnitsAttemptOrder=\(strategy.computeUnits.map(computeUnitsName).joined(separator: " -> "))"
                : nil,
            !failedComputeUnits.isEmpty
                ? "failedComputeUnits=\(failedComputeUnits.map(computeUnitsName).joined(separator: " -> "))"
                : nil,
            "selectedComputeUnits=\(computeUnitsName(selectedComputeUnits))",
            strategy.restrictionReason,
            runtimeSummary
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct CoreMLLoadStrategy {
    let computeUnits: [MLComputeUnits]
    let isAutomatic: Bool
    let requestedConfiguration: ProcessingUnitConfiguration?
    let restrictionReason: String?
}

@available(iOS 18.0, visionOS 2.0, *)
struct StatefulCMLCompatibilityError: LocalizedError, Equatable, Sendable {
    let reason: String

    var errorDescription: String? {
        "Stateful CML model is incompatible with Noema. \(reason)"
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum StatefulCMLPrefillMode: String, Sendable {
    case compatibilitySingleQuery = "compat-single-query"

    var summary: String {
        "prefillMode=\(rawValue)"
    }

    var maskWidthFormulaSummary: String {
        "maskWidthFormula=tokens"
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct StatefulCMLDimension: Sendable, Equatable {
    let minValue: Int?
    let maxValue: Int?

    static func fixed(_ value: Int) -> Self {
        Self(minValue: value, maxValue: value)
    }

    var fixedValue: Int? {
        guard let minValue, let maxValue, minValue == maxValue else { return nil }
        return minValue
    }

    var summary: String {
        if let fixedValue {
            return String(fixedValue)
        }
        switch (minValue, maxValue) {
        case let (min?, max?) where min != max:
            return "\(min)...\(max)"
        case let (nil, max?):
            return "...\(max)"
        case let (min?, nil):
            return "\(min)..."
        default:
            return "?"
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct StatefulCMLTensorSpec: Sendable, Equatable {
    let name: String
    let dataType: MLMultiArrayDataType
    let dimensions: [StatefulCMLDimension]

    init(name: String, dataType: MLMultiArrayDataType, dimensions: [StatefulCMLDimension]) {
        self.name = name
        self.dataType = dataType
        self.dimensions = dimensions
    }

    init(
        name: String,
        description: MLFeatureDescription,
        metadataFeature: CoreMLArtifactFeature? = nil,
        allowUnspecifiedShape: Bool = false
    ) throws {
        guard let constraint = description.multiArrayConstraint else {
            throw StatefulCMLCompatibilityError(reason: "`\(name)` is not a multi-array input/output.")
        }

        let dimensions = Self.resolveDimensions(from: constraint)
        let fallbackDimensions = Self.resolveDimensions(from: metadataFeature)
        let resolvedDimensions = !dimensions.isEmpty ? dimensions : fallbackDimensions

        guard !resolvedDimensions.isEmpty || allowUnspecifiedShape else {
            throw StatefulCMLCompatibilityError(reason: "`\(name)` does not expose a usable tensor shape.")
        }

        self.init(name: name, dataType: constraint.dataType, dimensions: resolvedDimensions)
    }

    var rank: Int {
        dimensions.count
    }

    var hasKnownShape: Bool {
        !dimensions.isEmpty
    }

    var minSequenceLength: Int? {
        dimensions.last?.minValue
    }

    var maxSequenceLength: Int? {
        dimensions.last?.maxValue
    }

    var shapeSummary: String {
        guard !dimensions.isEmpty else { return "dynamic" }
        return dimensions.map(\.summary).joined(separator: "x")
    }

    var summary: String {
        "\(name)=\(dataType.displayName)[\(shapeSummary)]"
    }

    static func dimension(from sizeRange: NSRange) -> StatefulCMLDimension {
        StatefulCMLDimension(
            minValue: sizeRange.location,
            maxValue: sizeRange.location + max(sizeRange.length - 1, 0)
        )
    }

    private static func resolveDimensions(from constraint: MLMultiArrayConstraint) -> [StatefulCMLDimension] {
        let shapeConstraint = constraint.shapeConstraint

        switch shapeConstraint.type {
        case .enumerated:
            let shapes = shapeConstraint.enumeratedShapes
            guard let firstShape = shapes.first else { return [] }
            return (0..<firstShape.count).map { index in
                let values = shapes.map { $0[index].intValue }
                return StatefulCMLDimension(
                    minValue: values.min(),
                    maxValue: values.max()
                )
            }
        case .range:
            let sizeRangeForDimension = shapeConstraint.sizeRangeForDimension
            if sizeRangeForDimension.count > 0 {
                return (0..<sizeRangeForDimension.count).map { index in
                    let nsRange = sizeRangeForDimension[index] as? NSRange
                    if let nsRange {
                        return dimension(from: nsRange)
                    }
                    return StatefulCMLDimension(minValue: nil, maxValue: nil)
                }
            }
            return constraint.shape.map { StatefulCMLDimension.fixed($0.intValue) }
        case .unspecified:
            return constraint.shape.map { StatefulCMLDimension.fixed($0.intValue) }
        @unknown default:
            return constraint.shape.map { StatefulCMLDimension.fixed($0.intValue) }
        }
    }

    private static func resolveDimensions(from metadataFeature: CoreMLArtifactFeature?) -> [StatefulCMLDimension] {
        guard let raw = metadataFeature?.shape?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return []
        }

        let values = raw
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .filter { !$0.isEmpty }
            .compactMap(Int.init)

        guard !values.isEmpty else { return [] }
        return values.map(StatefulCMLDimension.fixed)
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct StatefulCMLStateSpec: Sendable, Equatable {
    let name: String
    let dataType: MLMultiArrayDataType
    let bufferShape: [Int]

    init(name: String, dataType: MLMultiArrayDataType, bufferShape: [Int]) {
        self.name = name
        self.dataType = dataType
        self.bufferShape = bufferShape
    }

    init(name: String, description: MLFeatureDescription) throws {
        guard let constraint = description.stateConstraint else {
            throw StatefulCMLCompatibilityError(reason: "`\(name)` does not expose a state constraint.")
        }
        self.name = name
        self.dataType = constraint.dataType
        self.bufferShape = constraint.bufferShape
    }

    var summary: String {
        let shape = bufferShape.isEmpty ? "dynamic" : bufferShape.map(String.init).joined(separator: "x")
        return "\(name)=\(dataType.displayName)[\(shape)]"
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct StatefulCMLMaskLayout: Sendable, Equatable {
    let dataType: MLMultiArrayDataType
    let dimensions: [StatefulCMLDimension]

    init(dataType: MLMultiArrayDataType, dimensions: [StatefulCMLDimension]) throws {
        guard dimensions.count >= 2 else {
            throw StatefulCMLCompatibilityError(reason: "`causal_mask` does not expose a usable tensor shape.")
        }
        let queryAxis = dimensions.count - 2
        for (index, dimension) in dimensions.enumerated() where index < queryAxis {
            if let fixedValue = dimension.fixedValue, fixedValue != 1 {
                throw StatefulCMLCompatibilityError(
                    reason: "`causal_mask` dimension \(index) must be 1 for Noema's stateful runtime, found \(fixedValue)."
                )
            }
            if dimension.fixedValue == nil, let maxValue = dimension.maxValue, maxValue > 1 {
                throw StatefulCMLCompatibilityError(
                    reason: "`causal_mask` dimension \(index) must be fixed to 1 for Noema's stateful runtime."
                )
            }
        }
        let queryDimension = dimensions[queryAxis]
        if let fixedQueryLength = queryDimension.fixedValue {
            guard fixedQueryLength == 1 else {
                throw StatefulCMLCompatibilityError(
                    reason: "`causal_mask` query dimension must support 1 for compatibility prefill, found fixed length \(fixedQueryLength)."
                )
            }
        } else if let minQueryLength = queryDimension.minValue, minQueryLength > 1 {
            throw StatefulCMLCompatibilityError(
                reason: "`causal_mask` query dimension must support 1 for compatibility prefill."
            )
        }

        self.dataType = dataType
        self.dimensions = dimensions
    }

    var rank: Int {
        dimensions.count
    }

    var queryAxis: Int {
        dimensions.count - 2
    }

    var fixedWidth: Int? {
        dimensions.last?.fixedValue
    }

    var maxWidth: Int? {
        dimensions.last?.maxValue
    }

    var fixedQueryLength: Int? {
        dimensions[queryAxis].fixedValue
    }

    var maxQueryLength: Int? {
        dimensions[queryAxis].maxValue
    }

    var summary: String {
        "causal_mask=\(dataType.displayName)[\(dimensions.map(\.summary).joined(separator: "x"))]"
    }

    func resolvedShape(for logicalWidth: Int, logicalQueryLength: Int) throws -> [Int] {
        guard logicalWidth > 0 else {
            throw StatefulCMLCompatibilityError(reason: "`causal_mask` width must be positive.")
        }
        guard logicalQueryLength > 0 else {
            throw StatefulCMLCompatibilityError(reason: "`causal_mask` query length must be positive.")
        }
        guard logicalQueryLength <= logicalWidth else {
            throw StatefulCMLCompatibilityError(reason: "`causal_mask` query length \(logicalQueryLength) exceeds width \(logicalWidth).")
        }

        guard let widthDimension = dimensions.last else {
            throw StatefulCMLCompatibilityError(reason: "`causal_mask` is missing a width dimension.")
        }

        if let maxWidth = widthDimension.maxValue, logicalWidth > maxWidth {
            throw StatefulCMLCompatibilityError(
                reason: "`causal_mask` width \(logicalWidth) exceeds supported width \(maxWidth)."
            )
        }

        let queryDimension = dimensions[queryAxis]
        if let maxQueryLength = queryDimension.maxValue, logicalQueryLength > maxQueryLength {
            throw StatefulCMLCompatibilityError(
                reason: "`causal_mask` query length \(logicalQueryLength) exceeds supported length \(maxQueryLength)."
            )
        }
        if let fixedQueryLength = queryDimension.fixedValue, logicalQueryLength > fixedQueryLength {
            throw StatefulCMLCompatibilityError(
                reason: "`causal_mask` query length \(logicalQueryLength) exceeds fixed length \(fixedQueryLength)."
            )
        }

        return dimensions.enumerated().map { index, dimension in
            if index == queryAxis {
                return dimension.fixedValue ?? logicalQueryLength
            }
            if index == dimensions.count - 1 {
                return dimension.fixedValue ?? logicalWidth
            }
            return dimension.fixedValue ?? 1
        }
    }

    func makeAdditiveCausalMask(logicalWidth: Int, logicalQueryLength: Int) throws -> MLMultiArray {
        let shape = try resolvedShape(for: logicalWidth, logicalQueryLength: logicalQueryLength)
        let resolvedQueryLength = shape[queryAxis]
        let resolvedWidth = shape[shape.count - 1]
        let baseVisibleWidth = max(logicalWidth - logicalQueryLength, 0)

        switch dataType {
        case .float16:
            let blockedValue = -Float16.greatestFiniteMagnitude
            let scalars = additiveMaskScalars(
                shape: shape,
                queryLength: resolvedQueryLength,
                width: resolvedWidth,
                baseVisibleWidth: baseVisibleWidth,
                blockedValue: blockedValue
            )
            return MLMultiArray(MLShapedArray<Float16>(scalars: scalars, shape: shape))
        case .float32:
            let blockedValue = -Float.greatestFiniteMagnitude
            let scalars = additiveMaskScalars(
                shape: shape,
                queryLength: resolvedQueryLength,
                width: resolvedWidth,
                baseVisibleWidth: baseVisibleWidth,
                blockedValue: blockedValue
            )
            return MLMultiArray(MLShapedArray<Float>(scalars: scalars, shape: shape))
        case .double:
            let blockedValue = -Double.greatestFiniteMagnitude
            let scalars = additiveMaskScalars(
                shape: shape,
                queryLength: resolvedQueryLength,
                width: resolvedWidth,
                baseVisibleWidth: baseVisibleWidth,
                blockedValue: blockedValue
            )
            return MLMultiArray(MLShapedArray<Double>(scalars: scalars, shape: shape))
        default:
            throw StatefulCMLCompatibilityError(reason: "`causal_mask` must be a floating-point tensor.")
        }
    }

    private func additiveMaskScalars<Scalar>(
        shape: [Int],
        queryLength: Int,
        width: Int,
        baseVisibleWidth: Int,
        blockedValue: Scalar
    ) -> [Scalar] where Scalar: BinaryFloatingPoint {
        let prefixCount = max(shape.dropLast(2).reduce(1, *), 1)
        var scalars = [Scalar](repeating: blockedValue, count: shape.reduce(1, *))
        let planeSize = queryLength * width

        for prefixIndex in 0..<prefixCount {
            let planeBase = prefixIndex * planeSize
            for row in 0..<queryLength {
                let visibleWidth = min(baseVisibleWidth + row + 1, width)
                guard visibleWidth > 0 else { continue }
                let rowBase = planeBase + (row * width)
                for column in 0..<visibleWidth {
                    scalars[rowBase + column] = .zero
                }
            }
        }

        return scalars
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct StatefulCMLContract: Sendable, Equatable {
    let inputIDs: StatefulCMLTensorSpec
    let causalMask: StatefulCMLTensorSpec?
    let logits: StatefulCMLTensorSpec
    let maskLayout: StatefulCMLMaskLayout?
    let contextLength: Int
    let generatedClassName: String?
    let keyCacheState: StatefulCMLStateSpec?
    let valueCacheState: StatefulCMLStateSpec?
    let prefillMode: StatefulCMLPrefillMode

    init(
        inputIDs: StatefulCMLTensorSpec,
        causalMask: StatefulCMLTensorSpec?,
        logits: StatefulCMLTensorSpec,
        hasKeyCache: Bool,
        hasValueCache: Bool,
        keyCacheState: StatefulCMLStateSpec? = nil,
        valueCacheState: StatefulCMLStateSpec? = nil,
        metadata: CoreMLArtifactMetadata
    ) throws {
        guard hasKeyCache else {
            throw StatefulCMLCompatibilityError(reason: "Missing `key_cache` state.")
        }
        guard hasValueCache else {
            throw StatefulCMLCompatibilityError(reason: "Missing `value_cache` state.")
        }
        guard inputIDs.rank == 2 else {
            throw StatefulCMLCompatibilityError(reason: "`\(inputIDs.name)` must be rank 2, found rank \(inputIDs.rank).")
        }
        guard inputIDs.dataType.isInteger else {
            throw StatefulCMLCompatibilityError(reason: "`\(inputIDs.name)` must use an integer scalar type.")
        }
        if logits.hasKnownShape, logits.rank != 3 {
            throw StatefulCMLCompatibilityError(reason: "`\(logits.name)` must be rank 3, found rank \(logits.rank).")
        }
        guard logits.dataType.isFloatingPoint else {
            throw StatefulCMLCompatibilityError(reason: "`\(logits.name)` must use a floating-point scalar type.")
        }

        var maskLayout: StatefulCMLMaskLayout? = nil
        if let causalMask {
            guard causalMask.dataType.isFloatingPoint else {
                throw StatefulCMLCompatibilityError(reason: "`\(causalMask.name)` must use a floating-point scalar type.")
            }
            maskLayout = try StatefulCMLMaskLayout(
                dataType: causalMask.dataType,
                dimensions: causalMask.dimensions
            )
        }

        let minSequenceLength = inputIDs.minSequenceLength
        let maxSequenceLength = inputIDs.maxSequenceLength
        let contextLength: Int
        if let minSequenceLength, let maxSequenceLength, maxSequenceLength > minSequenceLength {
            contextLength = maxSequenceLength
        } else if let fixedSequenceLength = minSequenceLength, fixedSequenceLength == maxSequenceLength, fixedSequenceLength > 1 {
            throw StatefulCMLCompatibilityError(
                reason: "`\(inputIDs.name)` has a fixed prompt-chunk length of \(fixedSequenceLength); Noema's stateful runtime feeds one token per call. Re-export with sequence length 1 or a ranged sequence length."
            )
        } else if let derived = Self.derivedContextLength(
            maskLayout: maskLayout,
            keyCacheState: keyCacheState,
            metadata: metadata
        ) {
            // Fixed single-token (or unbounded) input shape: the sequence axis
            // says nothing about the context window, so take it from metadata,
            // the mask width, or the KV-cache buffer instead.
            contextLength = derived
        } else {
            throw StatefulCMLCompatibilityError(
                reason: "Could not determine the context length: `\(inputIDs.name)` shape is \(inputIDs.shapeSummary), no usable causal-mask width or KV-cache buffer shape was found. Re-export with a ranged sequence length or an explicit mask width."
            )
        }

        if let maskMaxWidth = maskLayout?.maxWidth, maskMaxWidth < contextLength {
            throw StatefulCMLCompatibilityError(
                reason: "`\(causalMask?.name ?? "causal_mask")` width \(maskMaxWidth) is smaller than the context length \(contextLength)."
            )
        }

        self.inputIDs = inputIDs
        self.causalMask = causalMask
        self.logits = logits
        self.maskLayout = maskLayout
        self.contextLength = contextLength
        self.generatedClassName = metadata.generatedClassName
        self.keyCacheState = keyCacheState
        self.valueCacheState = valueCacheState
        self.prefillMode = .compatibilitySingleQuery
    }

    private static func derivedContextLength(
        maskLayout: StatefulCMLMaskLayout?,
        keyCacheState: StatefulCMLStateSpec?,
        metadata: CoreMLArtifactMetadata
    ) -> Int? {
        let sanityRange = 8...1_048_576
        for key in ["context_length", "max_context_length", "state_length"] {
            if let value = metadata.intMetadataValue(for: key), sanityRange.contains(value) {
                return value
            }
        }
        if let width = maskLayout?.fixedWidth ?? maskLayout?.maxWidth, sanityRange.contains(width) {
            return width
        }
        if let bufferShape = keyCacheState?.bufferShape, bufferShape.count >= 3 {
            // Typical KV buffer layout is [... , heads, context, headDim].
            let candidate = bufferShape[bufferShape.count - 2]
            if sanityRange.contains(candidate) {
                return candidate
            }
        }
        return nil
    }

    init(modelDescription: MLModelDescription, metadata: CoreMLArtifactMetadata) throws {
        let roles = CoreMLRoleResolver.resolve(
            inputs: Self.artifactFeatures(from: modelDescription.inputDescriptionsByName),
            outputs: Self.artifactFeatures(from: modelDescription.outputDescriptionsByName),
            states: Self.artifactFeatures(from: modelDescription.stateDescriptionsByName)
        )

        func available(_ descriptions: [String: MLFeatureDescription]) -> String {
            let names = descriptions.keys.sorted().joined(separator: ", ")
            return names.isEmpty ? "<none>" : names
        }

        guard let tokenName = roles.tokenInput,
              let inputIDsDescription = modelDescription.inputDescriptionsByName[tokenName] else {
            throw StatefulCMLCompatibilityError(
                reason: "Missing token input (looked for `input_ids` and equivalents). Model inputs: [\(available(modelDescription.inputDescriptionsByName))]."
            )
        }
        guard let logitsName = roles.logitsOutput,
              let logitsDescription = modelDescription.outputDescriptionsByName[logitsName] else {
            throw StatefulCMLCompatibilityError(
                reason: "Missing logits output (looked for `logits` and equivalents). Model outputs: [\(available(modelDescription.outputDescriptionsByName))]."
            )
        }
        guard let keyCacheName = roles.keyCacheState,
              let keyCacheDescription = modelDescription.stateDescriptionsByName[keyCacheName] else {
            throw StatefulCMLCompatibilityError(
                reason: "Missing `key_cache` state (or equivalent). Model states: [\(available(modelDescription.stateDescriptionsByName))]."
            )
        }
        guard let valueCacheName = roles.valueCacheState,
              let valueCacheDescription = modelDescription.stateDescriptionsByName[valueCacheName] else {
            throw StatefulCMLCompatibilityError(
                reason: "Missing `value_cache` state (or equivalent). Model states: [\(available(modelDescription.stateDescriptionsByName))]."
            )
        }

        var causalMaskSpec: StatefulCMLTensorSpec? = nil
        if let maskName = roles.maskInput,
           let causalMaskDescription = modelDescription.inputDescriptionsByName[maskName] {
            causalMaskSpec = try StatefulCMLTensorSpec(
                name: maskName,
                description: causalMaskDescription,
                metadataFeature: metadata.inputSchema.first(where: { $0.name == maskName })
            )
        }

        try self.init(
            inputIDs: StatefulCMLTensorSpec(
                name: tokenName,
                description: inputIDsDescription,
                metadataFeature: metadata.inputSchema.first(where: { $0.name == tokenName })
            ),
            causalMask: causalMaskSpec,
            logits: StatefulCMLTensorSpec(
                name: logitsName,
                description: logitsDescription,
                metadataFeature: metadata.outputSchema.first(where: { $0.name == logitsName }),
                allowUnspecifiedShape: true
            ),
            hasKeyCache: true,
            hasValueCache: true,
            keyCacheState: try StatefulCMLStateSpec(name: keyCacheName, description: keyCacheDescription),
            valueCacheState: try StatefulCMLStateSpec(name: valueCacheName, description: valueCacheDescription),
            metadata: metadata
        )
    }

    private static func artifactFeatures(from descriptions: [String: MLFeatureDescription]) -> [CoreMLArtifactFeature] {
        descriptions.values.map { description in
            let dataType: String?
            if let constraint = description.multiArrayConstraint {
                dataType = constraint.dataType.displayName
            } else if let stateConstraint = description.stateConstraint {
                dataType = stateConstraint.dataType.displayName
            } else {
                dataType = nil
            }
            return CoreMLArtifactFeature(name: description.name, dataType: dataType)
        }
    }

    var summary: String {
        [
            "context=\(contextLength)",
            prefillMode.summary,
            "effectivePromptLimit=\(effectivePromptTokenLimit)",
            prefillMode.maskWidthFormulaSummary,
            inputIDs.summary,
            maskLayout?.summary ?? "causal_mask=<none>",
            logits.summary,
            keyCacheState?.summary,
            valueCacheState?.summary,
            generatedClassName.map { "class=\($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    var effectivePromptTokenLimit: Int {
        max(contextLength - 1, 1)
    }

    var effectiveSequenceTokenLimit: Int {
        contextLength
    }

    var prefillModeSummary: String {
        prefillMode.summary
    }

    func maskWidth(for tokenCount: Int) -> Int {
        switch prefillMode {
        case .compatibilitySingleQuery:
            // The single query attends over the currently visible token prefix.
            return tokenCount
        }
    }

    func maskQueryLength(isPrefill _: Bool) -> Int {
        switch prefillMode {
        case .compatibilitySingleQuery:
            return 1
        }
    }

    func validateTokenCount(_ tokenCount: Int) throws {
        guard tokenCount > 0 else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -20,
                userInfo: [NSLocalizedDescriptionKey: "CML generation received an empty token sequence."]
            )
        }
        guard tokenCount <= effectivePromptTokenLimit else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -22,
                userInfo: [NSLocalizedDescriptionKey: "CML prompt length \(tokenCount) exceeds effective prompt limit \(effectivePromptTokenLimit) while reserving one slot for the next generated token."]
            )
        }
    }

    func makeCausalMask(logicalWidth: Int, logicalQueryLength: Int) throws -> MLMultiArray {
        guard let maskLayout else {
            throw StatefulCMLCompatibilityError(reason: "Model does not take a causal-mask input.")
        }
        return try maskLayout.makeAdditiveCausalMask(logicalWidth: logicalWidth, logicalQueryLength: logicalQueryLength)
    }

    func nextTokenScores(from logitsValue: MLMultiArray, tokenIndex: Int) throws -> MLTensor {
        guard logitsValue.dataType == logits.dataType else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -24,
                userInfo: [NSLocalizedDescriptionKey: "CML logits output type `\(logitsValue.dataType.displayName)` does not match validated type `\(logits.dataType.displayName)`."]
            )
        }
        guard logitsValue.shape.count == 3 else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -25,
                userInfo: [NSLocalizedDescriptionKey: "CML logits output must be rank 3, found rank \(logitsValue.shape.count)."]
            )
        }
        let sequenceLength = logitsValue.shape[1].intValue
        guard tokenIndex >= 0, tokenIndex < sequenceLength else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -26,
                userInfo: [NSLocalizedDescriptionKey: "CML logits output is missing scores for token index \(tokenIndex)."]
            )
        }

        switch logits.dataType {
        case .float16:
            let logits = MLShapedArray<Float16>(logitsValue)
            return MLTensor(logits)[nil, tokenIndex, nil].expandingShape(at: 0)
        case .float32:
            let logits = MLShapedArray<Float>(logitsValue)
            return MLTensor(logits)[nil, tokenIndex, nil].expandingShape(at: 0)
        case .double:
            let logits = MLShapedArray<Double>(logitsValue)
            let floatLogits = MLShapedArray<Float>(
                scalars: logits.scalars.map(Float.init),
                shape: logits.shape
            )
            return MLTensor(floatLogits)[nil, tokenIndex, nil].expandingShape(at: 0)
        default:
            throw NSError(
                domain: "Noema.CoreML",
                code: -23,
                userInfo: [NSLocalizedDescriptionKey: "CML logits output uses unsupported scalar type `\(logits.dataType.displayName)`."]
            )
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private enum CoreMLModelDiagnostics {
    static func summary(
        for model: MLModel,
        compiledModelURL: URL,
        configuration: MLModelConfiguration
    ) async -> String? {
        var parts: [String] = []

        let availableDevices = MLModel.availableComputeDevices
            .map(describe)
            .sorted()
        if !availableDevices.isEmpty {
            parts.append("availableComputeDevices=\(availableDevices.joined(separator: ","))")
        }

        if let computePlan = try? await MLComputePlan.load(contentsOf: compiledModelURL, configuration: configuration),
           let computePlanSummary = summarize(computePlan: computePlan) {
            parts.append(computePlanSummary)
        }

        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func summarize(computePlan: MLComputePlan) -> String? {
        var preferredDevices = Set<String>()
        var supportedDevices = Set<String>()
        collectUsage(
            from: computePlan.modelStructure,
            computePlan: computePlan,
            preferredDevices: &preferredDevices,
            supportedDevices: &supportedDevices
        )
        guard !preferredDevices.isEmpty || !supportedDevices.isEmpty else { return nil }

        var parts: [String] = []
        if !preferredDevices.isEmpty {
            parts.append("computePlan.preferred=\(preferredDevices.sorted().joined(separator: ","))")
        }
        if !supportedDevices.isEmpty {
            parts.append("computePlan.supported=\(supportedDevices.sorted().joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }

    private static func collectUsage(
        from structure: MLModelStructure,
        computePlan: MLComputePlan,
        preferredDevices: inout Set<String>,
        supportedDevices: inout Set<String>
    ) {
        switch structure {
        case .neuralNetwork(let network):
            for layer in network.layers {
                if let usage = computePlan.deviceUsage(for: layer) {
                    record(usage: usage, preferredDevices: &preferredDevices, supportedDevices: &supportedDevices)
                }
            }
        case .pipeline(let pipeline):
            for subModel in pipeline.subModels {
                collectUsage(
                    from: subModel,
                    computePlan: computePlan,
                    preferredDevices: &preferredDevices,
                    supportedDevices: &supportedDevices
                )
            }
        case .program(let program):
            for function in program.functions.values {
                collectUsage(
                    from: function.block,
                    computePlan: computePlan,
                    preferredDevices: &preferredDevices,
                    supportedDevices: &supportedDevices
                )
            }
        case .unsupported:
            break
        @unknown default:
            break
        }
    }

    private static func collectUsage(
        from block: MLModelStructure.Program.Block,
        computePlan: MLComputePlan,
        preferredDevices: inout Set<String>,
        supportedDevices: inout Set<String>
    ) {
        for operation in block.operations {
            if let usage = computePlan.deviceUsage(for: operation) {
                record(usage: usage, preferredDevices: &preferredDevices, supportedDevices: &supportedDevices)
            }
            for nestedBlock in operation.blocks {
                collectUsage(
                    from: nestedBlock,
                    computePlan: computePlan,
                    preferredDevices: &preferredDevices,
                    supportedDevices: &supportedDevices
                )
            }
        }
    }

    private static func record(
        usage: MLComputePlan.DeviceUsage,
        preferredDevices: inout Set<String>,
        supportedDevices: inout Set<String>
    ) {
        preferredDevices.insert(describe(usage.preferred))
        for device in usage.supported {
            supportedDevices.insert(describe(device))
        }
    }

    private static func describe(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu(_):
            return "CPU"
        case .gpu(_):
            return "GPU"
        case .neuralEngine(_):
            return "NeuralEngine"
        @unknown default:
            return "Unknown"
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private protocol CoreMLTextRuntime: Sendable {
    var loadDiagnosticSummary: String? { get }
    func generate(prompt: String, config: GenerationConfig, onPartialText: @Sendable @escaping (String) -> Void) async throws -> String
    func unload()
}

@available(iOS 18.0, visionOS 2.0, *)
typealias CoreMLNextTokenPredictor = (MLTensor, GenerationConfig) async throws -> MLTensor

@available(iOS 18.0, visionOS 2.0, *)
private extension MLMultiArrayDataType {
    var isFloatingPoint: Bool {
        switch self {
        case .double, .float16, .float32:
            return true
        default:
            return false
        }
    }

    var isInteger: Bool {
        self == .int32
    }

    var displayName: String {
        switch self {
        case .double:
            return "Double"
        case .float16:
            return "Float16"
        case .float32:
            return "Float32"
        case .int32:
            return "Int32"
        default:
            return "Unknown"
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private extension MLComputeUnits {
    var diagnosticName: String {
        switch self {
        case .all:
            return "All"
        case .cpuOnly:
            return "CPU Only"
        case .cpuAndGPU:
            return "CPU + GPU"
        case .cpuAndNeuralEngine:
            return "CPU + Neural Engine"
        @unknown default:
            return "Unknown"
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum CoreMLGenerationEngine {
    static func generate(
        prompt: String,
        config: GenerationConfig,
        tokenizer: any Tokenizer,
        resetState: @escaping () async -> Void,
        predictor: @escaping CoreMLNextTokenPredictor,
        onPartialText: @escaping (String) -> Void
    ) async throws -> String {
        try await generate(
            promptTokens: tokenizer.encode(text: prompt),
            config: config,
            bosTokenId: tokenizer.bosTokenId,
            eosTokenId: tokenizer.eosTokenId,
            decode: { tokenizer.decode(tokens: $0) },
            resetState: resetState,
            predictor: predictor,
            onPartialText: onPartialText
        )
    }

    static func generate(
        promptTokens initialPromptTokens: [Int],
        config: GenerationConfig,
        bosTokenId: Int?,
        eosTokenId: Int?,
        decode: @escaping ([Int]) -> String,
        resetState: @escaping () async -> Void,
        predictor: @escaping CoreMLNextTokenPredictor,
        onPartialText: @escaping (String) -> Void
    ) async throws -> String {
        var promptTokens = initialPromptTokens
        if promptTokens.isEmpty {
            if let bosTokenId {
                promptTokens = [bosTokenId]
            } else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "CML generation could not start because the prompt encoded to zero tokens."]
                )
            }
        }

        var generationConfig = config
        generationConfig.bosTokenId = bosTokenId
        generationConfig.eosTokenId = eosTokenId
        generationConfig.maxLength = min(config.maxLength, promptTokens.count + config.maxNewTokens)

        await resetState()

        var outputTokens = promptTokens
        var generatedTokens: [Int] = []
        let logitsProcessors = createLogitsProcessorList(config: generationConfig)

        while outputTokens.count < generationConfig.maxLength {
            try throwIfCancelled()

            let inputTensor = tensor(from: outputTokens)
            let nextTokenScores = try await predictor(inputTensor, generationConfig)

            try throwIfCancelled()

            let processedScores = await logitsProcessors(inputTensor, nextTokenScores)
            let nextToken = try await selectNextToken(from: processedScores, mode: generationConfig.generationMode)

            if let eosTokenId = generationConfig.eosTokenId, nextToken == eosTokenId {
                break
            }

            outputTokens.append(nextToken)
            generatedTokens.append(nextToken)
            onPartialText(decode(generatedTokens))
        }

        try throwIfCancelled()
        return decode(generatedTokens)
    }

    private static func tensor(from tokenIDs: [Int]) -> MLTensor {
        MLTensor(tokenIDs.map(Int32.init)).expandingShape(at: 0)
    }

    static func throwIfCancelled() throws {
        if Task.isCancelled {
            throw CancellationError()
        }
    }

    private static func createLogitsProcessorList(config: GenerationConfig) -> LogitsProcessorList {
        var processors: [any LogitsProcessor] = []

        if config.repetitionPenalty != 1.0,
           let processor = try? RepetitionPenaltyLogitsProcessor(penalty: Float(config.repetitionPenalty)) {
            processors.append(processor)
        }

        if config.temperature > 0 && config.temperature != 1.0,
           let processor = try? TemperatureLogitsWarper(temperature: config.temperature) {
            processors.append(processor)
        }

        if config.topK > 0 && config.topK < Int.max,
           let processor = try? TopKLogitsWarper(topK: config.topK) {
            processors.append(processor)
        }

        if config.topP < 1.0,
           let processor = try? TopPLogitsWarper(topP: Float(config.topP)) {
            processors.append(processor)
        }

        if let minP = config.minP,
           let processor = try? MinPLogitsWarper(minP: Float(minP)) {
            processors.append(processor)
        }

        return LogitsProcessorList(processors: processors)
    }

    private static func selectNextToken(from scores: MLTensor, mode: GenerationMode) async throws -> Int {
        let tokenTensor: MLTensor
        switch mode {
        case .greedy:
            let indices = scores.argmax(alongAxis: -1).reshaped(to: [1, 1])
            tokenTensor = indices.scalarType == Int32.self ? indices : indices.cast(to: Int32.self)
        case .sample:
            let probs = scores.softmax(alongAxis: -1)
            let batchSize = scores.shape[0]
            let randomTensor = MLTensor(randomUniform: [batchSize, 1], in: 0..<1, scalarType: Float.self)
            let cumulativeProbs = probs.cumulativeSum(alongAxis: -1)
            let randomThreshold = cumulativeProbs.scalarType == Float.self ? randomTensor : randomTensor.cast(to: cumulativeProbs.scalarType)
            let mask = cumulativeProbs .< randomThreshold
            let indexed = (mask * 1000.0) + cumulativeProbs
            let sampledIndex = indexed.argmin(alongAxis: -1).reshaped(to: [1, 1])
            tokenTensor = sampledIndex.scalarType == Int32.self ? sampledIndex : sampledIndex.cast(to: Int32.self)
        default:
            throw NSError(
                domain: "Noema.CoreML",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: "CML generation mode `\(String(describing: mode))` is not supported."]
            )
        }

        guard let token = await tokenTensor.shapedArray(of: Int32.self).scalars.first else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -14,
                userInfo: [NSLocalizedDescriptionKey: "CML generation failed to decode the next token ID."]
            )
        }
        return Int(token)
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private struct EmptyCoreMLRuntime: CoreMLTextRuntime {
    let loadDiagnosticSummary: String? = nil

    func generate(prompt _: String, config _: GenerationConfig, onPartialText _: @Sendable @escaping (String) -> Void) async throws -> String {
        throw NSError(
            domain: "Noema.CoreML",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Failed to initialize CML runtime."]
        )
    }

    func unload() {}
}

@available(iOS 18.0, visionOS 2.0, *)
private final class TransformersCoreMLRuntime: @unchecked Sendable, CoreMLTextRuntime {
    private let languageModel: LanguageModel
    private let tokenizer: any Tokenizer
    let loadDiagnosticSummary: String? = nil

    init(resolvedModel: ANEResolvedModel, tokenizer: any Tokenizer, computeUnits: MLComputeUnits) throws {
        self.tokenizer = tokenizer
        languageModel = try LanguageModel.loadCompiled(
            url: resolvedModel.compiledModelURL,
            computeUnits: computeUnits,
            tokenizer: tokenizer
        )
    }

    func generate(prompt: String, config: GenerationConfig, onPartialText: @Sendable @escaping (String) -> Void) async throws -> String {
        try await CoreMLGenerationEngine.generate(
            prompt: prompt,
            config: config,
            tokenizer: tokenizer,
            resetState: { [languageModel] in
                await languageModel.resetState()
            },
            predictor: { [languageModel] tokens, generationConfig in
                await languageModel.predictNextTokenScores(tokens, config: generationConfig)
            },
            onPartialText: onPartialText
        )
    }

    func unload() {}
}

@available(iOS 18.0, visionOS 2.0, *)
private final class StatefulCausalCoreMLRuntime: @unchecked Sendable, CoreMLTextRuntime {
    private let languageModel: StatefulCausalLanguageModel
    private let tokenizer: any Tokenizer
    let loadDiagnosticSummary: String?

    init(resolvedModel: ANEResolvedModel, tokenizer: any Tokenizer, computeUnits: MLComputeUnits) async throws {
        self.tokenizer = tokenizer
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try await MLModel.load(contentsOf: resolvedModel.compiledModelURL, configuration: configuration)
        let contract = try StatefulCMLContract(
            modelDescription: model.modelDescription,
            metadata: resolvedModel.metadata
        )
        languageModel = StatefulCausalLanguageModel(
            model: model,
            modelName: resolvedModel.sourceModelURL.deletingPathExtension().lastPathComponent,
            contract: contract
        )
        let modelDiagnostics = await CoreMLModelDiagnostics.summary(
            for: model,
            compiledModelURL: resolvedModel.compiledModelURL,
            configuration: configuration
        )
        loadDiagnosticSummary = [contract.summary, modelDiagnostics]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    func generate(prompt: String, config: GenerationConfig, onPartialText: @Sendable @escaping (String) -> Void) async throws -> String {
        let promptTokenCount = tokenizer.encode(text: prompt).count
        if promptTokenCount > 0 {
            try languageModel.contract.validateTokenCount(promptTokenCount)
        }
        var adjustedConfig = config
        adjustedConfig.maxLength = min(config.maxLength, languageModel.contract.effectiveSequenceTokenLimit)

        return try await CoreMLGenerationEngine.generate(
            prompt: prompt,
            config: adjustedConfig,
            tokenizer: tokenizer,
            resetState: { [languageModel] in
                await languageModel.resetState()
            },
            predictor: { [languageModel] tokens, generationConfig in
                try await languageModel.predictNextTokenScores(tokens, config: generationConfig)
            },
            onPartialText: onPartialText
        )
    }

    func unload() {}
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLPrefillStrategy: String, Sendable, Equatable {
    case paddedBatchesWithUpdateMask = "padded-batches+update-mask"
    case fullBatchesWithInferRemainder = "full-batches+infer-remainder"
    case inferOnly = "infer-only"

    func makePlan(tokenCount: Int, batchSize: Int) -> ANEMLLPrefillPlan {
        let safeTokenCount = max(tokenCount, 0)
        let safeBatchSize = max(batchSize, 1)

        switch self {
        case .paddedBatchesWithUpdateMask:
            return ANEMLLPrefillPlan(
                strategy: self,
                fullBatchTokenCount: safeTokenCount,
                remainderTokenCount: 0,
                needsFinalTokenInfer: false
            )
        case .fullBatchesWithInferRemainder:
            let fullBatchTokenCount = (safeTokenCount / safeBatchSize) * safeBatchSize
            return ANEMLLPrefillPlan(
                strategy: self,
                fullBatchTokenCount: fullBatchTokenCount,
                remainderTokenCount: safeTokenCount - fullBatchTokenCount,
                needsFinalTokenInfer: false
            )
        case .inferOnly:
            return ANEMLLPrefillPlan(
                strategy: self,
                fullBatchTokenCount: 0,
                remainderTokenCount: safeTokenCount,
                needsFinalTokenInfer: false
            )
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct ANEMLLPrefillPlan: Sendable, Equatable {
    let strategy: ANEMLLPrefillStrategy
    let fullBatchTokenCount: Int
    let remainderTokenCount: Int
    let needsFinalTokenInfer: Bool

    var summary: String {
        "prefillStrategy=\(strategy.rawValue) fullBatchTokens=\(fullBatchTokenCount) remainderTokens=\(remainderTokenCount) finalInfer=\(needsFinalTokenInfer)"
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLHiddenStateShapeResolver {
    static func resolve(inputShape: [Int], embeddingShape: [Int], outputShape: [Int]) -> [Int] {
        let candidateShapes = [inputShape, embeddingShape, outputShape].filter { !$0.isEmpty }
        guard var resolvedShape = candidateShapes.first(where: { $0.count >= 3 }) ?? candidateShapes.first else {
            return [1, 1, 1]
        }

        let resolvedWidth = [inputShape, embeddingShape, outputShape]
            .compactMap(\.last)
            .first(where: { $0 > 1 })
            ?? resolvedShape.last
            ?? 1

        if resolvedShape.count < 3 {
            resolvedShape = [1, 1, resolvedWidth]
        } else {
            resolvedShape[resolvedShape.count - 1] = resolvedWidth
        }

        return resolvedShape.map { max($0, 1) }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLAllowedSequenceLengths: Sendable, Equatable {
    case enumerated([Int])
    case range(min: Int?, max: Int?)
    case unknown

    static func fromEnumeratedShapes(_ shapes: [[Int]], axis: Int) -> Self {
        let values = shapes
            .filter { $0.indices.contains(axis) }
            .map { $0[axis] }

        guard !values.isEmpty else { return .unknown }
        return .enumerated(Array(Set(values)).sorted())
    }

    static func fromRange(min: Int?, max: Int?) -> Self {
        .range(min: min, max: max)
    }

    func supports(_ length: Int) -> Bool {
        switch self {
        case .enumerated(let values):
            return values.contains(length)
        case .range(let min, let max):
            if let min, length < min { return false }
            if let max, length > max { return false }
            return true
        case .unknown:
            return false
        }
    }

    var summary: String {
        switch self {
        case .enumerated(let values):
            return values.map(String.init).joined(separator: ",")
        case .range(let min, let max):
            switch (min, max) {
            case let (min?, max?) where min == max:
                return "\(min)"
            case let (min?, max?):
                return "\(min)...\(max)"
            case let (min?, nil):
                return "\(min)..."
            case let (nil, max?):
                return "...\(max)"
            default:
                return "unknown"
            }
        case .unknown:
            return "unknown"
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLFunctionLoadPlanner {
    static func requiredFunctions(availableFunctions: [String], requiresRotation: Bool) throws -> [String] {
        let available = Set(availableFunctions)

        guard available.contains("infer"), available.contains("prefill") else {
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL chunk is missing required functions. Available functions: \(availableFunctions.joined(separator: ","))"
            )
        }

        guard requiresRotation else {
            return ["infer", "prefill"]
        }

        guard available.contains("infer_rotate"), available.contains("prefill_rotate") else {
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL chunk requires both infer_rotate and prefill_rotate for sliding-window inference. " +
                    "Available functions: \(availableFunctions.joined(separator: ","))"
            )
        }

        return ["infer", "prefill", "infer_rotate", "prefill_rotate"]
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLChunkLoadMode: Equatable, Sendable {
    case multiFunction([String])
    case singleModel
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLChunkLoadPlanner {
    static func resolve(
        availableFunctions: [String]?,
        requiresRotation: Bool,
        artifactName: String
    ) throws -> ANEMLLChunkLoadMode {
        let resolvedFunctions = (availableFunctions ?? []).sorted()

        if resolvedFunctions.contains("infer"), resolvedFunctions.contains("prefill") {
            _ = try ANEMLLFunctionLoadPlanner.requiredFunctions(
                availableFunctions: resolvedFunctions,
                requiresRotation: requiresRotation
            )
            return .multiFunction(resolvedFunctions)
        }

        guard !requiresRotation else {
            let summary = resolvedFunctions.isEmpty ? "none" : resolvedFunctions.joined(separator: ",")
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL chunk `\(artifactName)` requires infer/prefill/infer_rotate/prefill_rotate entry points for sliding-window inference. " +
                    "Available functions: \(summary)"
            )
        }

        return .singleModel
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLLoadErrorClassifier {
    static func isFunctionNameUnsupported(_ error: Error) -> Bool {
        let message = error.localizedDescription
        return message.contains("functionName") && message.contains("ML Program")
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLLoadDiagnosticSummary {
    static func make(
        modelFormat: String,
        artifactType: String,
        computeUnits: String,
        pipeline: ANEMLLPipelineDescriptor,
        prefillStrategy: ANEMLLPrefillStrategy,
        supportsUpdateMask: Bool,
        embedInputLengths: String,
        functions: String
    ) -> String {
        [
            "runtime=anemllPipeline",
            "modelFormat=\(modelFormat)",
            "artifactType=\(artifactType)",
            "computeUnits=\(computeUnits)",
            "context=\(pipeline.contextLength)",
            "stateLength=\(pipeline.stateLength)",
            "batchSize=\(pipeline.batchSize)",
            "argmaxInModel=\(pipeline.argmaxInModel)",
            "lmHeadMode=\(pipeline.argmaxInModel ? "argmax" : "logits")",
            "slidingWindow=\(pipeline.slidingWindow.map(String.init) ?? "none")",
            "prefillStrategy=\(prefillStrategy.rawValue)",
            "manifestPrefillDynamicSlice=\(pipeline.prefillDynamicSlice)",
            "supportsUpdateMask=\(supportsUpdateMask)",
            "embedInputLengths=\(embedInputLengths)",
            "functions=\(functions)"
        ].joined(separator: " ")
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLSamplingConfigResolver {
    static func resolve(
        settings: ModelSettings,
        pipeline: ANEMLLPipelineDescriptor?
    ) -> (doSample: Bool, temperature: Float, topK: Int, topP: Float) {
        if pipeline?.argmaxInModel == true {
            return (
                doSample: false,
                temperature: 0,
                topK: 0,
                topP: 1
            )
        }

        guard let recommended = pipeline?.recommendedSampling,
              shouldUseRecommendedSampling(settings: settings) else {
            return (
                doSample: settings.temperature > 0.0,
                temperature: Float(max(0.0, settings.temperature)),
                topK: max(0, settings.topK),
                topP: Float(max(0.0, min(1.0, settings.topP)))
            )
        }

        return (
            doSample: recommended.doSample,
            temperature: Float(max(0.0, recommended.temperature)),
            topK: max(0, recommended.topK),
            topP: Float(max(0.0, min(1.0, recommended.topP)))
        )
    }

    private static func shouldUseRecommendedSampling(settings: ModelSettings) -> Bool {
        let defaults = ModelSettings.default(for: .ane)
        return settings.temperature == defaults.temperature
            && settings.topK == defaults.topK
            && settings.topP == defaults.topP
    }
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLLMHeadOutputMode: Equatable, Sendable {
    case logits([String])
    case argmax(indexName: String, valueName: String)

    var outputNames: [String] {
        switch self {
        case .logits(let names):
            return names
        case .argmax(let indexName, let valueName):
            return [indexName, valueName]
        }
    }

    var supportsSampling: Bool {
        if case .logits = self {
            return true
        }
        return false
    }
}

@available(iOS 18.0, visionOS 2.0, *)
struct ANEMLLArgmaxChunkLayout: Equatable, Sendable {
    let sizes: [Int]
    let offsets: [Int]
}

@available(iOS 18.0, visionOS 2.0, *)
enum ANEMLLArgmaxOutputResolver {
    static func selectToken(
        indexArray: MLMultiArray,
        valueArray: MLMultiArray,
        pipeline: ANEMLLPipelineDescriptor
    ) throws -> Int {
        guard indexArray.count == valueArray.count else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL argmax outputs have mismatched shard counts."]
            )
        }
        guard indexArray.count > 0 else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL argmax output is empty."]
            )
        }

        let layout = try resolveChunkLayout(numChunks: indexArray.count, pipeline: pipeline)
        var bestChunk = 0
        var bestLocalIndex = 0
        var bestValue = -Float.infinity

        for index in 0..<indexArray.count {
            let localIndex = indexArray[index].intValue
            let value = valueArray[index].floatValue
            if value > bestValue {
                bestValue = value
                bestChunk = index
                bestLocalIndex = localIndex
            }
        }

        let chunkSize = layout.sizes[bestChunk]
        guard bestLocalIndex >= 0, bestLocalIndex < chunkSize else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey:
                    "ANEMLL argmax output index \(bestLocalIndex) is outside chunk \(bestChunk + 1) size \(chunkSize)."
                ]
            )
        }

        return bestLocalIndex + layout.offsets[bestChunk]
    }

    static func resolveChunkLayout(
        numChunks: Int,
        pipeline: ANEMLLPipelineDescriptor
    ) throws -> ANEMLLArgmaxChunkLayout {
        guard numChunks > 0 else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL argmax output is empty."]
            )
        }

        if let configured = pipeline.lmHeadChunkSizes,
           !configured.isEmpty {
            guard configured.count == numChunks else {
                throw StatefulCMLCompatibilityError(
                    reason: "ANEMLL `lm_head_chunk_sizes` metadata count \(configured.count) does not match argmax shard count \(numChunks)."
                )
            }
            guard configured.allSatisfy({ $0 > 0 }) else {
                throw StatefulCMLCompatibilityError(
                    reason: "ANEMLL `lm_head_chunk_sizes` metadata must contain positive sizes for every argmax shard."
                )
            }
            return ANEMLLArgmaxChunkLayout(
                sizes: configured,
                offsets: offsets(for: configured)
            )
        }

        guard let vocabSize = pipeline.vocabSize,
              vocabSize > 0 else {
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL `argmax_in_model` pipelines require `lm_head_chunk_sizes` or `vocab_size` metadata to map shard-local winners to token IDs."
            )
        }

        let baseChunkSize = vocabSize / numChunks
        let remainder = vocabSize % numChunks
        let sizes = (0..<numChunks).map { index in
            max(baseChunkSize + (index < remainder ? 1 : 0), 1)
        }
        return ANEMLLArgmaxChunkLayout(
            sizes: sizes,
            offsets: offsets(for: sizes)
        )
    }

    private static func offsets(for sizes: [Int]) -> [Int] {
        var runningOffset = 0
        return sizes.map { size in
            defer { runningOffset += size }
            return runningOffset
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private struct ANEMLLChunkModels: Sendable {
    let inferModel: MLModel
    let prefillModel: MLModel
    let inferRotateModel: MLModel?
    let prefillRotateModel: MLModel?
    let hiddenStateOutputName: String
    let supportsUpdateMask: Bool
    let prefillOutputShape: [Int]
    let availableFunctions: [String]

    var prefillUsesSingleOutput: Bool {
        prefillOutputShape.count > 1 && prefillOutputShape[1] == 1
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private struct ANEMLLBatchBuffers {
    let inputIDs: MLMultiArray
    let positionIDs: MLMultiArray
    let currentPos: MLMultiArray
    let causalMask: MLMultiArray
    let updateMask: MLMultiArray?
    let embeddingOutputBackings: [String: Any]
    let prefillOutputBackingsPingPong: [[String: Any]]
    let lastTokenOutputBackingsPingPong: [[String: Any]]
}

@available(iOS 18.0, visionOS 2.0, *)
private final class ANEMLLCoreMLRuntime: @unchecked Sendable, CoreMLTextRuntime {
    private let languageModel: ANEMLLanguageModel
    private let tokenizer: any Tokenizer
    let loadDiagnosticSummary: String?

    init(resolvedModel: ANEResolvedModel, tokenizer: any Tokenizer, computeUnits: MLComputeUnits) async throws {
        self.tokenizer = tokenizer
        guard let pipeline = resolvedModel.anemllPipeline else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Missing ANEMLL pipeline metadata."]
            )
        }

        let embeddingsModel = try await Self.loadModel(
            at: pipeline.embeddingsURL,
            computeUnits: computeUnits
        )
        let lmHeadModel = try await Self.loadModel(
            at: pipeline.lmHeadURL,
            computeUnits: computeUnits
        )
        let chunks = try await Self.loadChunks(
            urls: pipeline.ffnChunkURLs,
            pipeline: pipeline,
            computeUnits: computeUnits
        )

        languageModel = try ANEMLLanguageModel(
            embeddingsModel: embeddingsModel,
            chunks: chunks,
            lmHeadModel: lmHeadModel,
            pipeline: pipeline,
            modelName: resolvedModel.modelRoot.lastPathComponent
        )

        let compiledModeSummary = [
            pipeline.embeddingsURL,
            pipeline.lmHeadURL
        ] + pipeline.ffnChunkURLs
        let directCompiledAssets = compiledModeSummary.allSatisfy { $0.pathExtension.lowercased() == "mlmodelc" }
        let availableFunctions = chunks
            .enumerated()
            .map { "chunk\($0.offset + 1)=\($0.element.availableFunctions.joined(separator: ","))" }
            .joined(separator: " ")
        let usesSingleModelChunk = chunks.contains {
            $0.availableFunctions == ["single_model"] || $0.availableFunctions == ["single_model_fallback"]
        }
        let usesNamedFunctionChunks = chunks.contains {
            $0.availableFunctions != ["single_model"] && $0.availableFunctions != ["single_model_fallback"]
        }
        let ffnModelFormat: String = {
            switch (usesNamedFunctionChunks, usesSingleModelChunk) {
            case (true, false):
                return "mlprogram"
            case (false, true):
                return "single-model"
            case (true, true):
                return "mixed"
            case (false, false):
                return "unknown"
            }
        }()

        loadDiagnosticSummary = ANEMLLLoadDiagnosticSummary.make(
            modelFormat: ffnModelFormat,
            artifactType: directCompiledAssets ? "mlmodelc-direct" : "compiled-cache",
            computeUnits: computeUnits.diagnosticName,
            pipeline: pipeline,
            prefillStrategy: languageModel.prefillStrategy,
            supportsUpdateMask: languageModel.supportsUpdateMaskPrefill,
            embedInputLengths: languageModel.embedInputLengthsSummary,
            functions: availableFunctions
        )
    }

    func generate(prompt: String, config: GenerationConfig, onPartialText: @Sendable @escaping (String) -> Void) async throws -> String {
        var promptTokens = tokenizer.encode(text: prompt)
        if promptTokens.isEmpty {
            if let bosTokenId = tokenizer.bosTokenId {
                promptTokens = [bosTokenId]
            } else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -12,
                    userInfo: [NSLocalizedDescriptionKey: "CML generation could not start because the prompt encoded to zero tokens."]
                )
            }
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        await languageModel.resetState()

        var generatedTokens: [Int] = []
        var emittedText = ""
        var hiddenStateResult = try languageModel.prefillPromptTokens(promptTokens)

        while generatedTokens.count < config.maxNewTokens {
            try CoreMLGenerationEngine.throwIfCancelled()

            let nextToken = try languageModel.selectNextToken(
                from: hiddenStateResult.hiddenStates,
                tokenIndex: hiddenStateResult.tokenIndex,
                config: config,
                generatedTokenHistory: generatedTokens
            )

            if let eosTokenId = tokenizer.eosTokenId, nextToken == eosTokenId {
                break
            }

            generatedTokens.append(nextToken)
            emittedText = tokenizer.decode(tokens: generatedTokens)
            onPartialText(emittedText)

            hiddenStateResult = try languageModel.inferPromptToken(
                nextToken,
                position: promptTokens.count + generatedTokens.count - 1
            )
        }

        let output = tokenizer.decode(tokens: generatedTokens)

        let totalTime = CFAbsoluteTimeGetCurrent() - startTime
        let promptTokenCount = promptTokens.count
        let generatedTokenCount = generatedTokens.count
        let prefillDuration = languageModel.lastPrefillDuration
        let decodeDuration = max(totalTime - prefillDuration, 0)
        let decodeTPS = decodeDuration > 0 ? Double(generatedTokenCount) / decodeDuration : 0
        print(
            "[Noema.CoreML][ANEMLL] promptTokens=\(promptTokenCount) generatedTokens=\(generatedTokenCount) " +
                "prefillMs=\(Int((prefillDuration * 1000).rounded())) decodeTPS=\(String(format: "%.1f", decodeTPS)) " +
                "\(languageModel.prefillPlanSummary ?? "prefillStrategy=unknown")"
        )

        return output
    }

    func unload() {}

    private static func loadChunks(
        urls: [URL],
        pipeline: ANEMLLPipelineDescriptor,
        computeUnits: MLComputeUnits
    ) async throws -> [ANEMLLChunkModels] {
        var chunks: [ANEMLLChunkModels] = []
        chunks.reserveCapacity(urls.count)

        let requiresRotateFunctions: Bool = {
            guard let slidingWindow = pipeline.slidingWindow else { return false }
            return pipeline.contextLength > slidingWindow
        }()

        for url in urls {
            let loadMode = try await ANEMLLChunkLoadPlanner.resolve(
                availableFunctions: availableFunctionNames(at: url),
                requiresRotation: requiresRotateFunctions,
                artifactName: url.lastPathComponent
            )

            var inferModel: MLModel
            var prefillModel: MLModel
            var availableFunctions: [String]
            var inferRotateModel: MLModel?
            var prefillRotateModel: MLModel?

            switch loadMode {
            case .multiFunction(let names):
                do {
                    inferModel = try await loadModel(at: url, functionName: "infer", computeUnits: computeUnits)
                    prefillModel = try await loadModel(at: url, functionName: "prefill", computeUnits: computeUnits)
                    availableFunctions = names
                    if requiresRotateFunctions {
                        inferRotateModel = try await loadModel(at: url, functionName: "infer_rotate", computeUnits: computeUnits)
                        prefillRotateModel = try await loadModel(at: url, functionName: "prefill_rotate", computeUnits: computeUnits)
                    } else {
                        inferRotateModel = nil
                        prefillRotateModel = nil
                    }
                } catch let error where ANEMLLLoadErrorClassifier.isFunctionNameUnsupported(error) {
                    print(
                        "[Noema.CoreML][ANEMLL] Multi-function load failed for `\(url.lastPathComponent)` — " +
                        "model is not an ML Program. Falling back to single-model loading."
                    )
                    do {
                        let sharedModel = try await loadModel(at: url, computeUnits: computeUnits)
                        inferModel = sharedModel
                        prefillModel = sharedModel
                        availableFunctions = ["single_model_fallback"]
                        inferRotateModel = nil
                        prefillRotateModel = nil
                    } catch {
                        throw StatefulCMLCompatibilityError(
                            reason: "ANEMLL chunk `\(url.lastPathComponent)` cannot be loaded — " +
                                "the model has multi-function metadata but is not an ML Program. " +
                                "This model format is incompatible and may need to be re-converted. " +
                                "underlyingError=\(error.localizedDescription)"
                        )
                    }
                }
            case .singleModel:
                let sharedModel = try await loadModel(at: url, computeUnits: computeUnits)
                inferModel = sharedModel
                prefillModel = sharedModel
                availableFunctions = ["single_model"]
                inferRotateModel = nil
                prefillRotateModel = nil
            }

            let outputNames = Array(inferModel.modelDescription.outputDescriptionsByName.keys)
            let hiddenStateOutputName = outputNames.contains("output_hidden_states")
                ? "output_hidden_states"
                : (outputNames.first ?? "")

            guard !hiddenStateOutputName.isEmpty else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL chunk `\(url.lastPathComponent)` is missing a hidden state output."]
                )
            }

            let prefillOutputShape = prefillModel
                .modelDescription
                .outputDescriptionsByName[hiddenStateOutputName]?
                .multiArrayConstraint?
                .shape
                .map(\.intValue) ?? []

            chunks.append(
                ANEMLLChunkModels(
                    inferModel: inferModel,
                    prefillModel: prefillModel,
                    inferRotateModel: inferRotateModel,
                    prefillRotateModel: prefillRotateModel,
                    hiddenStateOutputName: hiddenStateOutputName,
                    supportsUpdateMask: prefillModel.modelDescription.inputDescriptionsByName.keys.contains("update_mask"),
                    prefillOutputShape: prefillOutputShape,
                    availableFunctions: availableFunctions
                )
            )
        }

        return chunks
    }

    private static func availableFunctionNames(at url: URL) async -> [String]? {
        do {
            let asset = try MLModelAsset(url: url)
            let names = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                asset.functionNames { names, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: (names ?? []).sorted())
                    }
                }
            }
            return names.isEmpty ? nil : names
        } catch {
            return nil
        }
    }

    private static func loadModel(
        at url: URL,
        functionName: String? = nil,
        computeUnits: MLComputeUnits
    ) async throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        if let functionName {
            configuration.functionName = functionName
        }

        do {
            return try await loadModelWithTimeout(
                at: url,
                configuration: configuration,
                timeout: modelLoadTimeout(for: computeUnits)
            )
        } catch {
            let functionSummary = functionName.map { " function=\($0)" } ?? ""
            throw NSError(
                domain: "Noema.CoreML",
                code: -6,
                userInfo: [
                    NSUnderlyingErrorKey: error,
                    NSLocalizedDescriptionKey:
                        "Failed to load ANEMLL artifact `\(url.lastPathComponent)`\(functionSummary) " +
                        "computeUnits=\(computeUnits.diagnosticName). underlyingError=\(error.localizedDescription)"
                ]
            )
        }
    }

    private static func modelLoadTimeout(for computeUnits: MLComputeUnits) -> TimeInterval {
        switch computeUnits {
        case .cpuAndNeuralEngine:
            return 30
        default:
            return 60
        }
    }

    private static func loadModelWithTimeout(
        at url: URL,
        configuration: MLModelConfiguration,
        timeout: TimeInterval
    ) async throws -> MLModel {
        final class ResumeGate: @unchecked Sendable {
            private let lock = NSLock()
            private var hasResumed = false

            func run(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                body()
            }
        }

        let gate = ResumeGate()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let model = try MLModel(contentsOf: url, configuration: configuration)
                    gate.run {
                        continuation.resume(returning: model)
                    }
                } catch {
                    gate.run {
                        continuation.resume(throwing: error)
                    }
                }
            }

            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.run {
                    continuation.resume(
                        throwing: NSError(
                            domain: "Noema.CoreML",
                            code: -19,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Timed out after \(Int(timeout))s while loading Core ML artifact `\(url.lastPathComponent)`."
                            ]
                        )
                    )
                }
            }
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private final class ANEMLLanguageModel {
    let model: MLModel
    let modelName: String
    let prefillStrategy: ANEMLLPrefillStrategy
    let supportsUpdateMaskPrefill: Bool
    let embedInputLengthsSummary: String

    private let embeddingsModel: MLModel
    private let chunks: [ANEMLLChunkModels]
    private let lmHeadModel: MLModel
    private let pipeline: ANEMLLPipelineDescriptor
    private let contextLength: Int
    private let batchSize: Int
    private let hiddenStateBackingShape: [Int]
    private let lmHeadOutputMode: ANEMLLLMHeadOutputMode
    private let predictionQueue = DispatchQueue(label: "com.noema.coreml.anemll.prediction", qos: .userInitiated)
    private var state: MLState?
    private var processedTokenCount = 0
    private var singleTokenInputIDs: MLMultiArray
    private var singleTokenPositionIDs: MLMultiArray
    private var singleTokenCurrentPos: MLMultiArray
    private var singleTokenCausalMask: MLMultiArray
    private var singleTokenEmbeddingOutputBackings: [String: Any]
    private var inferOutputBackingsPingPong: [[String: Any]]
    private var batchBuffersByLength: [Int: ANEMLLBatchBuffers] = [:]
    private var lmHeadOutputBackings: [String: Any]
    private(set) var lastPrefillDuration: TimeInterval = 0
    private(set) var prefillPlanSummary: String?

    private var lmHeadOutputNames: [String] {
        if case .logits(let outputNames) = lmHeadOutputMode {
            return outputNames
        }
        return []
    }

    init(
        embeddingsModel: MLModel,
        chunks: [ANEMLLChunkModels],
        lmHeadModel: MLModel,
        pipeline: ANEMLLPipelineDescriptor,
        modelName: String
    ) throws {
        guard let representativeModel = chunks.first?.inferModel else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -11,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL pipeline is missing FFN chunks."]
            )
        }

        self.model = representativeModel
        self.embeddingsModel = embeddingsModel
        self.chunks = chunks
        self.lmHeadModel = lmHeadModel
        self.pipeline = pipeline
        self.contextLength = pipeline.contextLength
        self.batchSize = max(pipeline.batchSize, 1)
        self.modelName = modelName
        let hiddenStateOutputName = chunks.first?.hiddenStateOutputName ?? "output_hidden_states"
        let prefillCapabilities = try Self.resolvePrefillCapabilities(
            embeddingsModel: embeddingsModel,
            chunks: chunks,
            batchSize: batchSize,
            pipeline: pipeline
        )
        self.prefillStrategy = prefillCapabilities.strategy
        self.supportsUpdateMaskPrefill = prefillCapabilities.supportsUpdateMaskPrefill
        self.embedInputLengthsSummary = prefillCapabilities.embedInputLengths.summary
        self.hiddenStateBackingShape = Self.resolveHiddenStateBackingShape(
            embeddingsDescription: embeddingsModel.modelDescription.outputDescriptionsByName["hidden_states"],
            inputDescription: representativeModel.modelDescription.inputDescriptionsByName["hidden_states"],
            outputDescription: representativeModel.modelDescription.outputDescriptionsByName[hiddenStateOutputName]
        )
        self.lmHeadOutputMode = try Self.resolveLMHeadOutputMode(from: lmHeadModel)
        self.state = chunks.first?.prefillModel.makeState()
        self.singleTokenInputIDs = try Self.makeMultiArray(shape: [1, 1], dataType: .int32)
        self.singleTokenPositionIDs = try Self.makeMultiArray(shape: [1], dataType: .int32)
        self.singleTokenCurrentPos = try Self.makeMultiArray(shape: [1], dataType: .int32)
        self.singleTokenCausalMask = try Self.makeMultiArray(shape: [1, 1, 1, contextLength], dataType: .float16)
        self.singleTokenEmbeddingOutputBackings = try Self.makeEmbeddingOutputBackings(
            from: embeddingsModel,
            sequenceLength: 1,
            shapeOverride: hiddenStateBackingShape
        )
        self.inferOutputBackingsPingPong = try Self.makeHiddenStateBackingsPingPong(
            outputName: hiddenStateOutputName,
            description: chunks.first?.inferModel.modelDescription.outputDescriptionsByName[hiddenStateOutputName],
            sequenceLength: 1,
            shapeOverride: hiddenStateBackingShape
        )
        self.lmHeadOutputBackings = try Self.makeLMHeadOutputBackings(from: lmHeadModel, outputMode: lmHeadOutputMode)
    }

    func resetState() async {
        state = chunks.first?.prefillModel.makeState()
        processedTokenCount = 0
        lastPrefillDuration = 0
        prefillPlanSummary = nil
    }

    func prefillPromptTokens(_ promptTokens: [Int]) throws -> (hiddenStates: MLMultiArray, tokenIndex: Int) {
        let tokenScalars = promptTokens.map(Int32.init)
        guard !tokenScalars.isEmpty else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL generation received an empty token sequence."]
            )
        }
        if tokenScalars.count > contextLength {
            throw NSError(
                domain: "Noema.CoreML",
                code: -16,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL prompt length \(tokenScalars.count) exceeds context length \(contextLength)."]
            )
        }

        let prefillStart = CFAbsoluteTimeGetCurrent()
        let result = try prefillHiddenStates(for: tokenScalars)
        lastPrefillDuration = CFAbsoluteTimeGetCurrent() - prefillStart
        processedTokenCount = tokenScalars.count
        return result
    }

    func inferPromptToken(_ token: Int, position: Int) throws -> (hiddenStates: MLMultiArray, tokenIndex: Int) {
        let result = try inferHiddenStates(for: Int32(token), position: position)
        processedTokenCount = position + 1
        return result
    }

    func selectNextToken(
        from hiddenStates: MLMultiArray,
        tokenIndex: Int,
        config: GenerationConfig,
        generatedTokenHistory: [Int]
    ) throws -> Int {
        let prediction = try lmHeadPrediction(from: hiddenStates)

        if case .argmax(let indexName, let valueName) = lmHeadOutputMode {
            let indexArray = try lmHeadOutputArray(named: indexName, prediction: prediction)
            let valueArray = try lmHeadOutputArray(named: valueName, prediction: prediction)
            return try ANEMLLArgmaxOutputResolver.selectToken(
                indexArray: indexArray,
                valueArray: valueArray,
                pipeline: pipeline
            )
        }

        switch config.generationMode {
        case .greedy:
            return try greedyToken(from: prediction, tokenIndex: tokenIndex)
        case .sample:
            return try sampledToken(
                from: prediction,
                tokenIndex: tokenIndex,
                config: config,
                generatedTokenHistory: generatedTokenHistory
            )
        @unknown default:
            throw NSError(
                domain: "Noema.CoreML",
                code: -13,
                userInfo: [NSLocalizedDescriptionKey: "CML generation mode `\(String(describing: config.generationMode))` is not supported."]
            )
        }
    }

    func predictNextTokenScores(_ tokens: MLTensor, config _: GenerationConfig) async throws -> MLTensor {
        let tokenArray = await tokens.shapedArray(of: Int32.self)
        let tokenScalars = tokenArray.scalars
        guard !tokenScalars.isEmpty else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -15,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL generation received an empty token sequence."]
            )
        }
        if tokenScalars.count > contextLength {
            throw NSError(
                domain: "Noema.CoreML",
                code: -16,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL prompt length \(tokenScalars.count) exceeds context length \(contextLength)."]
            )
        }

        let shouldPrefill = processedTokenCount == 0
            || tokenScalars.count <= processedTokenCount
            || tokenScalars.count > (processedTokenCount + 1)

        try CoreMLGenerationEngine.throwIfCancelled()

        let hiddenStateResult: (hiddenStates: MLMultiArray, tokenIndex: Int)
        if shouldPrefill {
            await resetState()
            let prefillStart = CFAbsoluteTimeGetCurrent()
            hiddenStateResult = try prefillHiddenStates(for: tokenScalars)
            lastPrefillDuration = CFAbsoluteTimeGetCurrent() - prefillStart
        } else {
            guard let lastToken = tokenScalars.last else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL extension step is missing the latest token."]
                )
            }
            hiddenStateResult = try inferHiddenStates(for: lastToken, position: tokenScalars.count - 1)
        }

        processedTokenCount = tokenScalars.count
        return try nextTokenScores(from: hiddenStateResult.hiddenStates, tokenIndex: hiddenStateResult.tokenIndex)
    }

    private func prefillHiddenStates(for tokens: [Int32]) throws -> (hiddenStates: MLMultiArray, tokenIndex: Int) {
        let plan = prefillStrategy.makePlan(tokenCount: tokens.count, batchSize: batchSize)
        prefillPlanSummary = plan.summary

        var position = 0
        var lastPrefillResult: (hiddenStates: MLMultiArray, tokenIndex: Int)?

        while position < plan.fullBatchTokenCount {
            let logicalBatchLength: Int
            switch prefillStrategy {
            case .paddedBatchesWithUpdateMask:
                logicalBatchLength = min(plan.fullBatchTokenCount - position, batchSize)
            case .fullBatchesWithInferRemainder:
                logicalBatchLength = batchSize
            case .inferOnly:
                logicalBatchLength = batchSize
            }
            let tokenSlice = Array(tokens[position..<(position + logicalBatchLength)])
            lastPrefillResult = try runPrefillBatch(tokens: tokenSlice, startPosition: position)
            position += logicalBatchLength
        }

        if plan.remainderTokenCount > 0 {
            var lastInferResult: (hiddenStates: MLMultiArray, tokenIndex: Int)?
            while position < tokens.count {
                lastInferResult = try inferHiddenStates(for: tokens[position], position: position)
                position += 1
            }
            guard let lastInferResult else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -17,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL remainder infer produced no hidden states."]
                )
            }
            return lastInferResult
        }

        guard let lastPrefillResult else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -17,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL prefill produced no hidden states."]
            )
        }

        return lastPrefillResult
    }

    private func inferHiddenStates(for token: Int32, position: Int) throws -> (hiddenStates: MLMultiArray, tokenIndex: Int) {
        try CoreMLGenerationEngine.throwIfCancelled()
        try fillSingleTokenInputs(token: token, position: position)

        let embedInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": singleTokenInputIDs
        ])
        let embedOptions = MLPredictionOptions()
        embedOptions.outputBackings = singleTokenEmbeddingOutputBackings
        _ = try embeddingsModel.prediction(from: embedInput, options: embedOptions)

        guard var currentHiddenStates = singleTokenEmbeddingOutputBackings["hidden_states"] as? MLMultiArray else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL embeddings model is missing the `hidden_states` output."]
            )
        }

        guard let state else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL state is unavailable."]
            )
        }

        for index in chunks.indices {
            try CoreMLGenerationEngine.throwIfCancelled()
            let model = chunkInferModel(for: index, position: position)
            let outputBackings = inferOutputBackingsPingPong[index % inferOutputBackingsPingPong.count]
            let options = MLPredictionOptions()
            options.outputBackings = outputBackings
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "hidden_states": currentHiddenStates,
                "position_ids": singleTokenPositionIDs,
                "causal_mask": singleTokenCausalMask,
                "current_pos": singleTokenCurrentPos
            ])

            let prediction = try predictSerially(model: model, provider: provider, state: state, options: options)
            guard let nextHiddenStates = prediction.featureValue(for: chunks[index].hiddenStateOutputName)?.multiArrayValue
                ?? outputBackings[chunks[index].hiddenStateOutputName] as? MLMultiArray else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL chunk `\(index + 1)` did not return hidden states."]
                )
            }
            currentHiddenStates = nextHiddenStates
        }

        return (currentHiddenStates, 0)
    }

    private func runPrefillBatch(tokens: [Int32], startPosition: Int) throws -> (hiddenStates: MLMultiArray, tokenIndex: Int) {
        try CoreMLGenerationEngine.throwIfCancelled()
        let logicalBatchLength = max(tokens.count, 1)
        guard logicalBatchLength <= batchSize else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -17,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL prefill batch length \(logicalBatchLength) exceeds configured batch size \(batchSize)."]
            )
        }
        if prefillStrategy == .fullBatchesWithInferRemainder, logicalBatchLength != batchSize {
            throw NSError(
                domain: "Noema.CoreML",
                code: -17,
                userInfo: [NSLocalizedDescriptionKey:
                    "ANEMLL full-batch prefill requires exactly \(batchSize) tokens, got \(logicalBatchLength)."
                ]
            )
        }

        let inputBatchLength = batchSize
        let buffers = try batchBuffers(for: batchSize)

        try fillBatchInputs(
            buffers: buffers,
            tokens: tokens,
            startPosition: startPosition,
            inputBatchLength: inputBatchLength,
            logicalBatchLength: logicalBatchLength
        )

        let embedInput = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": buffers.inputIDs
        ])
        let embedOptions = MLPredictionOptions()
        embedOptions.outputBackings = buffers.embeddingOutputBackings
        _ = try embeddingsModel.prediction(from: embedInput, options: embedOptions)

        guard var currentHiddenStates = buffers.embeddingOutputBackings["hidden_states"] as? MLMultiArray else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL embeddings model is missing the `hidden_states` output."]
            )
        }

        var lastTokenIndex = logicalBatchLength - 1
        guard let state else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL state is unavailable."]
            )
        }

        for index in chunks.indices {
            try CoreMLGenerationEngine.throwIfCancelled()
            let model = chunkPrefillModel(for: index, position: startPosition)
            let outputBackings = chunks[index].prefillUsesSingleOutput
                ? buffers.lastTokenOutputBackingsPingPong[index % buffers.lastTokenOutputBackingsPingPong.count]
                : buffers.prefillOutputBackingsPingPong[index % buffers.prefillOutputBackingsPingPong.count]

            let options = MLPredictionOptions()
            options.outputBackings = outputBackings

            var inputDictionary: [String: Any] = [
                "hidden_states": currentHiddenStates,
                "position_ids": buffers.positionIDs,
                "causal_mask": buffers.causalMask,
                "current_pos": buffers.currentPos
            ]
            if supportsUpdateMaskPrefill, chunks[index].supportsUpdateMask, let updateMask = buffers.updateMask {
                inputDictionary["update_mask"] = updateMask
            }

            let provider = try MLDictionaryFeatureProvider(dictionary: inputDictionary)
            let prediction = try predictSerially(model: model, provider: provider, state: state, options: options)
            guard let nextHiddenStates = prediction.featureValue(for: chunks[index].hiddenStateOutputName)?.multiArrayValue
                ?? outputBackings[chunks[index].hiddenStateOutputName] as? MLMultiArray else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -7,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL chunk `\(index + 1)` did not return hidden states during prefill."]
                )
            }

            currentHiddenStates = nextHiddenStates
            if chunks[index].prefillUsesSingleOutput {
                lastTokenIndex = 0
            } else if currentHiddenStates.shape.count > 1 {
                lastTokenIndex = min(logicalBatchLength, currentHiddenStates.shape[1].intValue) - 1
            }
        }

        return (currentHiddenStates, max(lastTokenIndex, 0))
    }

    private func lmHeadPrediction(from hiddenStates: MLMultiArray) throws -> any MLFeatureProvider {
        try CoreMLGenerationEngine.throwIfCancelled()

        let provider = try MLDictionaryFeatureProvider(dictionary: ["hidden_states": hiddenStates])
        let options = MLPredictionOptions()
        options.outputBackings = lmHeadOutputBackings
        return try lmHeadModel.prediction(from: provider, options: options)
    }

    private func greedyToken(from prediction: any MLFeatureProvider, tokenIndex: Int) throws -> Int {
        var bestToken = 0
        var bestValue = -Float.infinity
        var tokenOffset = 0

        for name in lmHeadOutputNames {
            let logits = try lmHeadOutputArray(named: name, prediction: prediction)
            try visitLogits(in: logits, tokenIndex: tokenIndex) { localIndex, value in
                if value > bestValue {
                    bestValue = value
                    bestToken = tokenOffset + localIndex
                }
            }
            tokenOffset += logitsWidth(of: logits)
        }

        return bestToken
    }

    private func sampledToken(
        from prediction: any MLFeatureProvider,
        tokenIndex: Int,
        config: GenerationConfig,
        generatedTokenHistory: [Int]
    ) throws -> Int {
        let perPartLimit = max(config.topK, 100)
        var candidates: [(tokenID: Int, logit: Float)] = []
        var tokenOffset = 0

        for name in lmHeadOutputNames {
            let logits = try lmHeadOutputArray(named: name, prediction: prediction)
            var partCandidates: [(tokenID: Int, logit: Float)] = []
            try appendTopCandidates(
                from: logits,
                tokenIndex: tokenIndex,
                tokenOffset: tokenOffset,
                maxCount: perPartLimit,
                into: &partCandidates
            )
            candidates.append(contentsOf: partCandidates)
            tokenOffset += logitsWidth(of: logits)
        }

        guard !candidates.isEmpty else {
            return try greedyToken(from: prediction, tokenIndex: tokenIndex)
        }

        if config.repetitionPenalty != 1.0, !generatedTokenHistory.isEmpty {
            let penalizedTokens = Set(generatedTokenHistory)
            for index in candidates.indices where penalizedTokens.contains(candidates[index].tokenID) {
                if candidates[index].logit < 0 {
                    candidates[index].logit *= Float(config.repetitionPenalty)
                } else {
                    candidates[index].logit /= Float(config.repetitionPenalty)
                }
            }
        }

        let temperature = max(config.temperature, 0.0001)
        let maxLogit = candidates.map(\.logit).max() ?? 0
        var weightedCandidates = candidates.map { candidate in
            (
                tokenID: candidate.tokenID,
                score: exp((candidate.logit - maxLogit) / temperature)
            )
        }

        if let minP = config.minP, minP > 0 {
            let threshold = (weightedCandidates.map(\.score).max() ?? 0) * Float(minP)
            let filtered = weightedCandidates.filter { $0.score >= threshold }
            if !filtered.isEmpty {
                weightedCandidates = filtered
            }
        }

        if config.topK > 0, weightedCandidates.count > config.topK {
            weightedCandidates.sort { $0.score > $1.score }
            weightedCandidates = Array(weightedCandidates.prefix(config.topK))
        }

        if config.topP < 1.0 {
            weightedCandidates.sort { $0.score > $1.score }
            let totalScore = weightedCandidates.reduce(into: Float.zero) { $0 += $1.score }
            let threshold = Float(config.topP) * totalScore
            var cumulative: Float = 0
            var filtered: [(tokenID: Int, score: Float)] = []
            filtered.reserveCapacity(weightedCandidates.count)

            for candidate in weightedCandidates {
                filtered.append(candidate)
                cumulative += candidate.score
                if cumulative >= threshold {
                    break
                }
            }

            if !filtered.isEmpty {
                weightedCandidates = filtered
            }
        }

        let totalScore = weightedCandidates.reduce(into: Float.zero) { $0 += $1.score }
        guard totalScore > 0 else {
            if let tokenID = weightedCandidates.max(by: { $0.score < $1.score })?.tokenID {
                return tokenID
            }
            return try greedyToken(from: prediction, tokenIndex: tokenIndex)
        }

        let threshold = Float.random(in: 0..<totalScore)
        var cumulative: Float = 0
        for candidate in weightedCandidates {
            cumulative += candidate.score
            if threshold <= cumulative {
                return candidate.tokenID
            }
        }

        if let tokenID = weightedCandidates.last?.tokenID {
            return tokenID
        }
        return try greedyToken(from: prediction, tokenIndex: tokenIndex)
    }

    private func appendTopCandidates(
        from logits: MLMultiArray,
        tokenIndex: Int,
        tokenOffset: Int,
        maxCount: Int,
        into candidates: inout [(tokenID: Int, logit: Float)]
    ) throws {
        try visitLogits(in: logits, tokenIndex: tokenIndex) { localIndex, value in
            let candidate = (tokenID: tokenOffset + localIndex, logit: value)
            if candidates.count < maxCount {
                candidates.append(candidate)
                if candidates.count == maxCount {
                    candidates.sort { $0.logit > $1.logit }
                }
                return
            }

            guard let lastValue = candidates.last?.logit, value > lastValue else {
                return
            }

            candidates[candidates.count - 1] = candidate
            var insertionIndex = candidates.count - 1
            while insertionIndex > 0, candidates[insertionIndex].logit > candidates[insertionIndex - 1].logit {
                candidates.swapAt(insertionIndex, insertionIndex - 1)
                insertionIndex -= 1
            }
        }
    }

    private func lmHeadOutputArray(named name: String, prediction: any MLFeatureProvider) throws -> MLMultiArray {
        if let backing = lmHeadOutputBackings[name] as? MLMultiArray {
            return backing
        }
        if let featureValue = prediction.featureValue(for: name)?.multiArrayValue {
            return featureValue
        }

        throw NSError(
            domain: "Noema.CoreML",
            code: -9,
            userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head is missing output `\(name)`."]
        )
    }

    private func visitLogits(
        in logits: MLMultiArray,
        tokenIndex: Int,
        _ body: (Int, Float) throws -> Void
    ) throws {
        let rowWidth = logitsWidth(of: logits)
        let rowCount = max(logits.count / max(rowWidth, 1), 1)
        let rowIndex = min(max(tokenIndex, 0), rowCount - 1)
        let baseOffset: Int

        if let pixelBuffer = logits.pixelBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

            guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head output backing is unavailable."]
                )
            }

            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / Self.bytesPerElement(for: logits.dataType)
            baseOffset = rowIndex * rowStride

            switch logits.dataType {
            case .float16:
                let pointer = baseAddress.assumingMemoryBound(to: Float16.self)
                for index in 0..<rowWidth {
                    try body(index, Float(pointer[baseOffset + index]))
                }
            case .float32:
                let pointer = baseAddress.assumingMemoryBound(to: Float.self)
                for index in 0..<rowWidth {
                    try body(index, pointer[baseOffset + index])
                }
            case .double:
                let pointer = baseAddress.assumingMemoryBound(to: Double.self)
                for index in 0..<rowWidth {
                    try body(index, Float(pointer[baseOffset + index]))
                }
            default:
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head uses unsupported logits type `\(logits.dataType.displayName)`."]
                )
            }

            return
        }

        let basePointer = logits.dataPointer
        baseOffset = rowIndex * rowWidth
        switch logits.dataType {
        case .float16:
            let pointer = basePointer.assumingMemoryBound(to: Float16.self)
            for index in 0..<rowWidth {
                try body(index, Float(pointer[baseOffset + index]))
            }
        case .float32:
            let pointer = basePointer.assumingMemoryBound(to: Float.self)
            for index in 0..<rowWidth {
                try body(index, pointer[baseOffset + index])
            }
        case .double:
            let pointer = basePointer.assumingMemoryBound(to: Double.self)
            for index in 0..<rowWidth {
                try body(index, Float(pointer[baseOffset + index]))
            }
        default:
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head uses unsupported logits type `\(logits.dataType.displayName)`."]
            )
        }
    }

    private func logitsWidth(of logits: MLMultiArray) -> Int {
        logits.shape.last?.intValue ?? logits.count
    }

    private func nextTokenScores(from hiddenStates: MLMultiArray, tokenIndex: Int) throws -> MLTensor {
        guard lmHeadOutputMode.supportsSampling else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL argmax-in-model LM head does not expose logits scores."]
            )
        }

        let prediction = try lmHeadPrediction(from: hiddenStates)

        guard let firstOutputName = lmHeadOutputNames.first else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -10,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head outputs are not compatible with Noema."]
            )
        }

        if lmHeadOutputNames.count == 1,
           let logitsValue = (lmHeadOutputBackings[firstOutputName] as? MLMultiArray)
                ?? prediction.featureValue(for: firstOutputName)?.multiArrayValue {
            return try mltensor(from: logitsValue, tokenIndex: tokenIndex)
        }

        guard let firstLogitsValue = (lmHeadOutputBackings[firstOutputName] as? MLMultiArray)
            ?? prediction.featureValue(for: firstOutputName)?.multiArrayValue else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head is missing output `\(firstOutputName)`."]
            )
        }

        switch firstLogitsValue.dataType {
        case .float16:
            return try combineFloat16Logits(prediction: prediction, tokenIndex: tokenIndex)
        case .float32:
            return try combineFloat32Logits(prediction: prediction, tokenIndex: tokenIndex)
        case .double:
            return try combineDoubleLogits(prediction: prediction, tokenIndex: tokenIndex)
        default:
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head uses unsupported logits type `\(firstLogitsValue.dataType.displayName)`."]
            )
        }
    }

    private func combineFloat16Logits(prediction: any MLFeatureProvider, tokenIndex: Int) throws -> MLTensor {
        var shapedParts: [MLShapedArray<Float16>] = []
        shapedParts.reserveCapacity(lmHeadOutputNames.count)
        for name in lmHeadOutputNames {
            guard let logitsValue = (lmHeadOutputBackings[name] as? MLMultiArray) ?? prediction.featureValue(for: name)?.multiArrayValue else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head is missing output `\(name)`."]
                )
            }
            shapedParts.append(MLShapedArray<Float16>(logitsValue))
        }

        let sequenceLength = shapedParts.first?.shape.dropLast().last ?? 1
        let totalWidth = shapedParts.reduce(0) { $0 + ($1.shape.last ?? 0) }
        var scalars: [Float16] = []
        scalars.reserveCapacity(sequenceLength * totalWidth)
        for row in 0..<sequenceLength {
            for part in shapedParts {
                let width = part.shape.last ?? 0
                let rowBase = row * width
                scalars.append(contentsOf: part.scalars[rowBase..<(rowBase + width)])
            }
        }
        let combined = MLShapedArray<Float16>(scalars: scalars, shape: [1, sequenceLength, totalWidth])
        return MLTensor(combined)[nil, tokenIndex, nil].expandingShape(at: 0)
    }

    private func combineFloat32Logits(prediction: any MLFeatureProvider, tokenIndex: Int) throws -> MLTensor {
        var shapedParts: [MLShapedArray<Float>] = []
        shapedParts.reserveCapacity(lmHeadOutputNames.count)
        for name in lmHeadOutputNames {
            guard let logitsValue = (lmHeadOutputBackings[name] as? MLMultiArray) ?? prediction.featureValue(for: name)?.multiArrayValue else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head is missing output `\(name)`."]
                )
            }
            shapedParts.append(MLShapedArray<Float>(logitsValue))
        }

        let sequenceLength = shapedParts.first?.shape.dropLast().last ?? 1
        let totalWidth = shapedParts.reduce(0) { $0 + ($1.shape.last ?? 0) }
        var scalars: [Float] = []
        scalars.reserveCapacity(sequenceLength * totalWidth)
        for row in 0..<sequenceLength {
            for part in shapedParts {
                let width = part.shape.last ?? 0
                let rowBase = row * width
                scalars.append(contentsOf: part.scalars[rowBase..<(rowBase + width)])
            }
        }
        let combined = MLShapedArray<Float>(scalars: scalars, shape: [1, sequenceLength, totalWidth])
        return MLTensor(combined)[nil, tokenIndex, nil].expandingShape(at: 0)
    }

    private func combineDoubleLogits(prediction: any MLFeatureProvider, tokenIndex: Int) throws -> MLTensor {
        var shapedParts: [MLShapedArray<Double>] = []
        shapedParts.reserveCapacity(lmHeadOutputNames.count)
        for name in lmHeadOutputNames {
            guard let logitsValue = (lmHeadOutputBackings[name] as? MLMultiArray) ?? prediction.featureValue(for: name)?.multiArrayValue else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head is missing output `\(name)`."]
                )
            }
            shapedParts.append(MLShapedArray<Double>(logitsValue))
        }

        let sequenceLength = shapedParts.first?.shape.dropLast().last ?? 1
        let totalWidth = shapedParts.reduce(0) { $0 + ($1.shape.last ?? 0) }
        var scalars: [Float] = []
        scalars.reserveCapacity(sequenceLength * totalWidth)
        for row in 0..<sequenceLength {
            for part in shapedParts {
                let width = part.shape.last ?? 0
                let rowBase = row * width
                scalars.append(contentsOf: part.scalars[rowBase..<(rowBase + width)].map(Float.init))
            }
        }
        let combined = MLShapedArray<Float>(scalars: scalars, shape: [1, sequenceLength, totalWidth])
        return MLTensor(combined)[nil, tokenIndex, nil].expandingShape(at: 0)
    }

    private func batchBuffers(for inputBatchLength: Int) throws -> ANEMLLBatchBuffers {
        if let existing = batchBuffersByLength[inputBatchLength] {
            return existing
        }

        let buffers = try ANEMLLBatchBuffers(
            inputIDs: Self.makeMultiArray(shape: [1, inputBatchLength], dataType: .int32),
            positionIDs: Self.makeMultiArray(shape: [inputBatchLength], dataType: .int32),
            currentPos: Self.makeMultiArray(shape: [1], dataType: .int32),
            causalMask: Self.makeMultiArray(shape: [1, 1, inputBatchLength, contextLength], dataType: .float16),
            updateMask: pipeline.updateMaskPrefill
                ? Self.makeMultiArray(shape: [1, 1, contextLength, inputBatchLength], dataType: .float16)
                : nil,
            embeddingOutputBackings: try Self.makeEmbeddingOutputBackings(
                from: embeddingsModel,
                sequenceLength: inputBatchLength,
                shapeOverride: hiddenStateBackingShape
            ),
            prefillOutputBackingsPingPong: try Self.makeHiddenStateBackingsPingPong(
                outputName: chunks.first?.hiddenStateOutputName ?? "output_hidden_states",
                description: chunks.first?.prefillModel.modelDescription.outputDescriptionsByName[chunks.first?.hiddenStateOutputName ?? "output_hidden_states"],
                sequenceLength: inputBatchLength,
                shapeOverride: hiddenStateBackingShape
            ),
            lastTokenOutputBackingsPingPong: try Self.makeHiddenStateBackingsPingPong(
                outputName: chunks.first?.hiddenStateOutputName ?? "output_hidden_states",
                description: chunks.first?.prefillModel.modelDescription.outputDescriptionsByName[chunks.first?.hiddenStateOutputName ?? "output_hidden_states"],
                sequenceLength: 1,
                shapeOverride: hiddenStateBackingShape
            )
        )
        batchBuffersByLength[inputBatchLength] = buffers
        return buffers
    }

    private func fillSingleTokenInputs(token: Int32, position: Int) throws {
        singleTokenInputIDs[[0, 0] as [NSNumber]] = NSNumber(value: token)
        singleTokenPositionIDs[0] = NSNumber(value: position)
        singleTokenCurrentPos[0] = NSNumber(value: position)
        let maskPointer = singleTokenCausalMask.dataPointer.assumingMemoryBound(to: Float16.self)
        for index in 0..<contextLength {
            maskPointer[index] = index <= position ? 0 : -Float16.greatestFiniteMagnitude
        }
    }

    private func fillBatchInputs(
        buffers: ANEMLLBatchBuffers,
        tokens: [Int32],
        startPosition: Int,
        inputBatchLength: Int,
        logicalBatchLength: Int
    ) throws {
        for column in 0..<inputBatchLength {
            let tokenValue: Int32 = column < logicalBatchLength ? tokens[column] : 0
            buffers.inputIDs[[0, column] as [NSNumber]] = NSNumber(value: tokenValue)
            buffers.positionIDs[column] = NSNumber(value: startPosition + column)
        }
        buffers.currentPos[0] = NSNumber(value: startPosition)

        let maskPointer = buffers.causalMask.dataPointer.assumingMemoryBound(to: Float16.self)
        let totalMaskElements = inputBatchLength * contextLength
        for index in 0..<totalMaskElements {
            maskPointer[index] = -Float16.greatestFiniteMagnitude
        }
        for row in 0..<inputBatchLength {
            let visibleWidth = min(startPosition + row + 1, contextLength)
            let rowBase = row * contextLength
            if visibleWidth > 0 {
                for column in 0..<visibleWidth {
                    maskPointer[rowBase + column] = 0
                }
            }
        }

        if let updateMask = buffers.updateMask {
            let updatePointer = updateMask.dataPointer.assumingMemoryBound(to: Float16.self)
            let totalUpdateElements = contextLength * inputBatchLength
            for index in 0..<totalUpdateElements {
                updatePointer[index] = 0
            }
            for offset in 0..<logicalBatchLength {
                let writePosition = startPosition + offset
                if writePosition < contextLength {
                    updatePointer[(writePosition * inputBatchLength) + offset] = 1
                }
            }
        }
    }

    private func chunkInferModel(for index: Int, position: Int) -> MLModel {
        let chunk = chunks[index]
        if let slidingWindow = pipeline.slidingWindow, position >= slidingWindow, let rotated = chunk.inferRotateModel {
            return rotated
        }
        return chunk.inferModel
    }

    private func chunkPrefillModel(for index: Int, position: Int) -> MLModel {
        let chunk = chunks[index]
        if let slidingWindow = pipeline.slidingWindow, position >= slidingWindow, let rotated = chunk.prefillRotateModel {
            return rotated
        }
        return chunk.prefillModel
    }

    private func predictSerially(
        model: MLModel,
        provider: MLDictionaryFeatureProvider,
        state: MLState,
        options: MLPredictionOptions
    ) throws -> any MLFeatureProvider {
        var result: (any MLFeatureProvider)?
        var predictionError: Error?
        predictionQueue.sync {
            do {
                result = try model.prediction(from: provider, using: state, options: options)
            } catch {
                predictionError = error
            }
        }
        if let predictionError {
            throw predictionError
        }
        guard let result else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL prediction finished without output."]
            )
        }
        return result
    }

    private func mltensor(from logitsValue: MLMultiArray, tokenIndex: Int) throws -> MLTensor {
        switch logitsValue.dataType {
        case .float16:
            let logits = MLShapedArray<Float16>(logitsValue)
            return MLTensor(logits)[nil, tokenIndex, nil].expandingShape(at: 0)
        case .float32:
            let logits = MLShapedArray<Float>(logitsValue)
            return MLTensor(logits)[nil, tokenIndex, nil].expandingShape(at: 0)
        case .double:
            let logits = MLShapedArray<Double>(logitsValue)
            let floatLogits = MLShapedArray<Float>(scalars: logits.scalars.map(Float.init), shape: logits.shape)
            return MLTensor(floatLogits)[nil, tokenIndex, nil].expandingShape(at: 0)
        default:
            throw NSError(
                domain: "Noema.CoreML",
                code: -9,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head uses unsupported logits type `\(logitsValue.dataType.displayName)`."]
            )
        }
    }

    private static func resolveLMHeadOutputMode(from model: MLModel) throws -> ANEMLLLMHeadOutputMode {
        let outputNames = Array(model.modelDescription.outputDescriptionsByName.keys)
        if outputNames.contains("argmax_idx"), outputNames.contains("argmax_val") {
            return .argmax(indexName: "argmax_idx", valueName: "argmax_val")
        }
        if outputNames.contains("logits") {
            return .logits(["logits"])
        }

        let sharded = outputNames.filter { $0.lowercased().hasPrefix("logits") }.sorted { lhs, rhs in
            let l = numericSuffix(in: lhs) ?? Int.max
            let r = numericSuffix(in: rhs) ?? Int.max
            if l != r { return l < r }
            return lhs < rhs
        }
        if !sharded.isEmpty {
            return .logits(sharded)
        }

        throw NSError(
            domain: "Noema.CoreML",
            code: -10,
            userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head outputs are not compatible with Noema."]
        )
    }

    private static func numericSuffix(in name: String) -> Int? {
        guard let range = name.range(of: #"\d+$"#, options: .regularExpression) else {
            return nil
        }
        return Int(name[range])
    }

    private static func makeMultiArray(shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataType)
    }

    private static func bytesPerElement(for dataType: MLMultiArrayDataType) -> Int {
        switch dataType {
        case .float16:
            return MemoryLayout<Float16>.size
        case .float32:
            return MemoryLayout<Float>.size
        case .double:
            return MemoryLayout<Double>.size
        case .int32:
            return MemoryLayout<Int32>.size
        default:
            return MemoryLayout<Float16>.size
        }
    }

    private static func makePixelBufferBacking(shape: [Int], dataType: MLMultiArrayDataType) throws -> MLMultiArray? {
        guard dataType == .float16, let width = shape.last, width > 0 else {
            return nil
        }

        let height = max(shape.dropLast().reduce(1, *), 1)
        let attributes: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent16Half,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        return MLMultiArray(pixelBuffer: pixelBuffer, shape: shape.map { NSNumber(value: $0) })
    }

    private static func makeEmbeddingOutputBackings(
        from model: MLModel,
        sequenceLength: Int,
        shapeOverride: [Int]? = nil
    ) throws -> [String: Any] {
        guard let description = model.modelDescription.outputDescriptionsByName["hidden_states"] else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -8,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL embeddings model is missing the `hidden_states` output description."]
            )
        }
        let array = try makeOutputBacking(
            description: description,
            sequenceLength: sequenceLength,
            fallbackShape: [1, sequenceLength, 1],
            shapeOverride: shapeOverride
        )
        return ["hidden_states": array]
    }

    private static func makeHiddenStateBackingsPingPong(
        outputName: String,
        description: MLFeatureDescription?,
        sequenceLength: Int,
        shapeOverride: [Int]? = nil
    ) throws -> [[String: Any]] {
        guard let description else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL chunk is missing the `\(outputName)` output description."]
            )
        }
        return try (0..<2).map { _ in
            [
                outputName: try makeOutputBacking(
                    description: description,
                    sequenceLength: sequenceLength,
                    fallbackShape: [1, sequenceLength, 1],
                    shapeOverride: shapeOverride
                )
            ]
        }
    }

    private static func makeLMHeadOutputBackings(
        from model: MLModel,
        outputMode: ANEMLLLMHeadOutputMode
    ) throws -> [String: Any] {
        var backings: [String: Any] = [:]
        let fallbackShape: [Int] = outputMode.supportsSampling ? [1, 1, 1] : [1]
        for name in outputMode.outputNames {
            guard let description = model.modelDescription.outputDescriptionsByName[name] else {
                throw NSError(
                    domain: "Noema.CoreML",
                    code: -9,
                    userInfo: [NSLocalizedDescriptionKey: "ANEMLL LM head is missing output description `\(name)`."]
                )
            }
            backings[name] = try makeOutputBacking(description: description, sequenceLength: nil, fallbackShape: fallbackShape)
        }
        return backings
    }

    private static func makeOutputBacking(
        description: MLFeatureDescription,
        sequenceLength: Int?,
        fallbackShape: [Int],
        shapeOverride: [Int]? = nil
    ) throws -> MLMultiArray {
        guard let constraint = description.multiArrayConstraint else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "ANEMLL output `\(description.name)` is not a multi-array."]
            )
        }
        var shape = shapeOverride ?? constraint.shape.map(\.intValue)
        if shape.isEmpty {
            shape = fallbackShape
        }
        if let sequenceLength, shape.count >= 2 {
            shape[1] = sequenceLength
        }
        if let pixelBufferBacking = try makePixelBufferBacking(shape: shape, dataType: constraint.dataType) {
            return pixelBufferBacking
        }
        return try makeMultiArray(shape: shape, dataType: constraint.dataType)
    }

    private static func resolvePrefillCapabilities(
        embeddingsModel: MLModel,
        chunks: [ANEMLLChunkModels],
        batchSize: Int,
        pipeline: ANEMLLPipelineDescriptor
    ) throws -> (
        strategy: ANEMLLPrefillStrategy,
        supportsUpdateMaskPrefill: Bool,
        embedInputLengths: ANEMLLAllowedSequenceLengths
    ) {
        let embedInputLengths = allowedSequenceLengths(
            from: embeddingsModel.modelDescription.inputDescriptionsByName["input_ids"],
            axis: 1
        )
        guard embedInputLengths.supports(1) else {
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL embeddings input `input_ids` must support sequence length 1 for infer. " +
                    "Available lengths: \(embedInputLengths.summary)"
            )
        }

        let hasFallbackChunks = chunks.contains {
            $0.availableFunctions == ["single_model_fallback"]
        }

        if hasFallbackChunks {
            for (index, chunk) in chunks.enumerated() {
                try validateSequenceLength(
                    description: chunk.inferModel.modelDescription.inputDescriptionsByName["hidden_states"],
                    axis: 1,
                    requiredLength: 1,
                    featureName: "hidden_states",
                    modelName: "chunk \(index + 1) infer"
                )
                try validateSequenceLength(
                    description: chunk.inferModel.modelDescription.inputDescriptionsByName["position_ids"],
                    axis: 0,
                    requiredLength: 1,
                    featureName: "position_ids",
                    modelName: "chunk \(index + 1) infer"
                )
                try validateSequenceLength(
                    description: chunk.inferModel.modelDescription.inputDescriptionsByName["causal_mask"],
                    axis: 2,
                    requiredLength: 1,
                    featureName: "causal_mask",
                    modelName: "chunk \(index + 1) infer"
                )
            }

            return (
                strategy: .inferOnly,
                supportsUpdateMaskPrefill: false,
                embedInputLengths: embedInputLengths
            )
        }

        guard embedInputLengths.supports(batchSize) else {
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL embeddings input `input_ids` must support sequence length \(batchSize) for chunked prefill. " +
                    "Available lengths: \(embedInputLengths.summary)"
            )
        }

        for (index, chunk) in chunks.enumerated() {
            try validateSequenceLength(
                description: chunk.inferModel.modelDescription.inputDescriptionsByName["hidden_states"],
                axis: 1,
                requiredLength: 1,
                featureName: "hidden_states",
                modelName: "chunk \(index + 1) infer"
            )
            try validateSequenceLength(
                description: chunk.inferModel.modelDescription.inputDescriptionsByName["position_ids"],
                axis: 0,
                requiredLength: 1,
                featureName: "position_ids",
                modelName: "chunk \(index + 1) infer"
            )
            try validateSequenceLength(
                description: chunk.inferModel.modelDescription.inputDescriptionsByName["causal_mask"],
                axis: 2,
                requiredLength: 1,
                featureName: "causal_mask",
                modelName: "chunk \(index + 1) infer"
            )
            try validateSequenceLength(
                description: chunk.prefillModel.modelDescription.inputDescriptionsByName["hidden_states"],
                axis: 1,
                requiredLength: batchSize,
                featureName: "hidden_states",
                modelName: "chunk \(index + 1) prefill"
            )
            try validateSequenceLength(
                description: chunk.prefillModel.modelDescription.inputDescriptionsByName["position_ids"],
                axis: 0,
                requiredLength: batchSize,
                featureName: "position_ids",
                modelName: "chunk \(index + 1) prefill"
            )
            try validateSequenceLength(
                description: chunk.prefillModel.modelDescription.inputDescriptionsByName["causal_mask"],
                axis: 2,
                requiredLength: batchSize,
                featureName: "causal_mask",
                modelName: "chunk \(index + 1) prefill"
            )
            if chunk.supportsUpdateMask {
                try validateSequenceLength(
                    description: chunk.prefillModel.modelDescription.inputDescriptionsByName["update_mask"],
                    axis: 3,
                    requiredLength: batchSize,
                    featureName: "update_mask",
                    modelName: "chunk \(index + 1) prefill"
                )
            }
        }

        let supportsUpdateMaskPrefill = pipeline.updateMaskPrefill
            && chunks.allSatisfy { $0.supportsUpdateMask }
            && embedInputLengths.supports(batchSize)

        return (
            strategy: supportsUpdateMaskPrefill ? .paddedBatchesWithUpdateMask : .fullBatchesWithInferRemainder,
            supportsUpdateMaskPrefill: supportsUpdateMaskPrefill,
            embedInputLengths: embedInputLengths
        )
    }

    private static func validateSequenceLength(
        description: MLFeatureDescription?,
        axis: Int,
        requiredLength: Int,
        featureName: String,
        modelName: String
    ) throws {
        let allowedLengths = allowedSequenceLengths(from: description, axis: axis)
        guard allowedLengths.supports(requiredLength) else {
            throw StatefulCMLCompatibilityError(
                reason: "ANEMLL \(modelName) input `\(featureName)` must support sequence length \(requiredLength). " +
                    "Available lengths: \(allowedLengths.summary)"
            )
        }
    }

    private static func allowedSequenceLengths(
        from description: MLFeatureDescription?,
        axis: Int
    ) -> ANEMLLAllowedSequenceLengths {
        guard let constraint = description?.multiArrayConstraint else {
            return .unknown
        }
        return allowedSequenceLengths(from: constraint, axis: axis)
    }

    private static func allowedSequenceLengths(
        from constraint: MLMultiArrayConstraint,
        axis: Int
    ) -> ANEMLLAllowedSequenceLengths {
        let shapeConstraint = constraint.shapeConstraint

        switch shapeConstraint.type {
        case .enumerated:
            let shapes = shapeConstraint.enumeratedShapes.map { $0.map(\.intValue) }
            return ANEMLLAllowedSequenceLengths.fromEnumeratedShapes(shapes, axis: axis)
        case .range:
            let sizeRangeForDimension = shapeConstraint.sizeRangeForDimension
            guard sizeRangeForDimension.count > axis,
                  let nsRange = sizeRangeForDimension[axis] as? NSRange else {
                if constraint.shape.indices.contains(axis) {
                    return .enumerated([constraint.shape[axis].intValue])
                }
                return .unknown
            }
            return .fromRange(
                min: nsRange.location,
                max: nsRange.location + max(nsRange.length - 1, 0)
            )
        case .unspecified:
            if constraint.shape.indices.contains(axis) {
                return .enumerated([constraint.shape[axis].intValue])
            }
            return .unknown
        @unknown default:
            if constraint.shape.indices.contains(axis) {
                return .enumerated([constraint.shape[axis].intValue])
            }
            return .unknown
        }
    }

    private static func resolveHiddenStateBackingShape(
        embeddingsDescription: MLFeatureDescription?,
        inputDescription: MLFeatureDescription?,
        outputDescription: MLFeatureDescription?
    ) -> [Int] {
        ANEMLLHiddenStateShapeResolver.resolve(
            inputShape: preferredShape(from: inputDescription),
            embeddingShape: preferredShape(from: embeddingsDescription),
            outputShape: preferredShape(from: outputDescription)
        )
    }

    private static func preferredShape(from description: MLFeatureDescription?) -> [Int] {
        guard let constraint = description?.multiArrayConstraint else {
            return []
        }
        return preferredShape(from: constraint)
    }

    private static func preferredShape(from constraint: MLMultiArrayConstraint) -> [Int] {
        let fallbackShape = constraint.shape.map(\.intValue)
        let shapeConstraint = constraint.shapeConstraint

        switch shapeConstraint.type {
        case .enumerated:
            let shapes = shapeConstraint.enumeratedShapes
            guard let firstShape = shapes.first else {
                return fallbackShape
            }
            return (0..<firstShape.count).map { index in
                shapes.map { $0[index].intValue }.max() ?? firstShape[index].intValue
            }
        case .range:
            let sizeRangeForDimension = shapeConstraint.sizeRangeForDimension
            guard sizeRangeForDimension.count > 0 else {
                return fallbackShape
            }
            return (0..<sizeRangeForDimension.count).map { index in
                guard let nsRange = sizeRangeForDimension[index] as? NSRange else {
                    return index < fallbackShape.count ? max(fallbackShape[index], 1) : 1
                }
                let maxValue = nsRange.location + max(nsRange.length - 1, 0)
                if maxValue > 0 {
                    return maxValue
                }
                if index < fallbackShape.count {
                    return max(fallbackShape[index], 1)
                }
                return 1
            }
        case .unspecified:
            return fallbackShape
        @unknown default:
            return fallbackShape
        }
    }
}

@available(iOS 18.0, visionOS 2.0, *)
private final class StatefulCausalLanguageModel {
    private enum Mode {
        case prefilling
        case extending
    }

    let model: MLModel
    let modelName: String
    let contract: StatefulCMLContract
    private var mode: Mode = .prefilling
    private var state: MLState?
    private var wrappedPredictionFailure = false

    init(model: MLModel, modelName: String, contract: StatefulCMLContract) {
        self.model = model
        self.modelName = modelName
        self.contract = contract
        self.state = model.makeState()
    }

    func resetState() async {
        state = model.makeState()
        mode = .prefilling
        wrappedPredictionFailure = false
    }

    func predictNextTokenScores(_ tokens: MLTensor, config _: GenerationConfig) async throws -> MLTensor {
        guard let state else {
            throw NSError(
                domain: "Noema.CoreML",
                code: -19,
                userInfo: [NSLocalizedDescriptionKey: "Encountered uninitialized CML state. Ensure resetState() runs before generation."]
            )
        }

        let tokenArray = await tokens.shapedArray(of: Int32.self)
        let tokenScalars = tokenArray.scalars
        let tokenCount = tokenScalars.count
        try contract.validateTokenCount(tokenCount)

        try CoreMLGenerationEngine.throwIfCancelled()

        if mode == .prefilling {
            // Process prompt tokens one at a time (compatibilitySingleQuery):
            // each call feeds a [1,1] token with a growing causal-mask width,
            // letting the KV cache accumulate one entry per step via MLState.
            var lastLogitsValue: MLMultiArray?
            for i in 0..<tokenCount {
                try CoreMLGenerationEngine.throwIfCancelled()

                let singleInput = MLShapedArray<Int32>(scalars: [tokenScalars[i]], shape: [1, 1])
                let logicalWidth = contract.maskWidth(for: i + 1)
                let causalMask = try makeCausalMaskIfNeeded(
                    logicalWidth: logicalWidth,
                    logicalQueryLength: 1
                )

                let provider = try makeFeatureProvider(
                    tokens: MLMultiArray(singleInput),
                    causalMask: causalMask
                )

                let prediction: any MLFeatureProvider
                do {
                    prediction = try await model.prediction(from: provider, using: state)
                } catch {
                    throw wrapPredictionFailure(
                        error,
                        mode: .prefilling,
                        promptTokenCount: tokenCount,
                        logicalMaskWidth: logicalWidth,
                        causalMask: causalMask,
                        prefillStep: i + 1
                    )
                }

                if i == tokenCount - 1 {
                    lastLogitsValue = prediction.featureValue(for: contract.logits.name)?.multiArrayValue
                }
            }

            guard let logitsValue = lastLogitsValue else {
                throw wrapPredictionFailure(
                    NSError(
                        domain: "Noema.CoreML",
                        code: -21,
                        userInfo: [NSLocalizedDescriptionKey: "CML prediction failed: missing logits output."]
                    ),
                    mode: .prefilling,
                    promptTokenCount: tokenCount,
                    logicalMaskWidth: contract.maskWidth(for: tokenCount),
                    causalMask: try makeCausalMaskIfNeeded(
                        logicalWidth: contract.maskWidth(for: tokenCount),
                        logicalQueryLength: 1
                    ),
                    prefillStep: tokenCount
                )
            }

            mode = .extending
            return try contract.nextTokenScores(from: logitsValue, tokenIndex: 0)
        } else {
            let lastToken = tokenScalars[tokenScalars.count - 1]
            let inputIDs = MLShapedArray<Int32>(scalars: [lastToken], shape: [1, 1])

            let logicalWidth = contract.maskWidth(for: tokenCount)
            let causalMask = try makeCausalMaskIfNeeded(
                logicalWidth: logicalWidth,
                logicalQueryLength: 1
            )

            let provider = try makeFeatureProvider(
                tokens: MLMultiArray(inputIDs),
                causalMask: causalMask
            )

            let prediction: any MLFeatureProvider
            do {
                prediction = try await model.prediction(from: provider, using: state)
            } catch {
                throw wrapPredictionFailure(
                    error,
                    mode: .extending,
                    promptTokenCount: tokenCount,
                    logicalMaskWidth: logicalWidth,
                    causalMask: causalMask
                )
            }
            try CoreMLGenerationEngine.throwIfCancelled()

            guard let logitsValue = prediction.featureValue(for: contract.logits.name)?.multiArrayValue else {
                throw wrapPredictionFailure(
                    NSError(
                        domain: "Noema.CoreML",
                        code: -21,
                        userInfo: [NSLocalizedDescriptionKey: "CML prediction failed: missing logits output."]
                    ),
                    mode: .extending,
                    promptTokenCount: tokenCount,
                    logicalMaskWidth: logicalWidth,
                    causalMask: causalMask
                )
            }

            mode = .extending
            return try contract.nextTokenScores(from: logitsValue, tokenIndex: 0)
        }
    }

    private func makeCausalMaskIfNeeded(logicalWidth: Int, logicalQueryLength: Int) throws -> MLMultiArray? {
        guard contract.causalMask != nil else { return nil }
        return try contract.makeCausalMask(logicalWidth: logicalWidth, logicalQueryLength: logicalQueryLength)
    }

    private func makeFeatureProvider(tokens: MLMultiArray, causalMask: MLMultiArray?) throws -> MLDictionaryFeatureProvider {
        var features: [String: Any] = [contract.inputIDs.name: tokens]
        if let maskName = contract.causalMask?.name, let causalMask {
            features[maskName] = causalMask
        }
        return try MLDictionaryFeatureProvider(dictionary: features)
    }

    private func wrapPredictionFailure(
        _ error: Error,
        mode: Mode,
        promptTokenCount: Int,
        logicalMaskWidth: Int,
        causalMask: MLMultiArray?,
        prefillStep: Int? = nil
    ) -> Error {
        guard !wrappedPredictionFailure else { return error }
        wrappedPredictionFailure = true

        let modeLabel = (mode == .prefilling) ? "prefill" : "extend"
        let maskShape = causalMask.map { $0.shape.map(\.intValue).map(String.init).joined(separator: "x") } ?? "<none>"
        let description = [
            "CML prediction failed.",
            "mode=\(modeLabel)",
            prefillStep.map { "prefillStep=\($0)" },
            "promptTokens=\(promptTokenCount)",
            "logicalMaskWidth=\(logicalMaskWidth)",
            "actualMaskShape=\(maskShape)",
            "computeUnits=\(model.configuration.computeUnits.diagnosticName)",
            contract.summary,
            "underlyingError=\(error.localizedDescription)"
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        return NSError(
            domain: "Noema.CoreML",
            code: -27,
            userInfo: [
                NSLocalizedDescriptionKey: description,
                NSUnderlyingErrorKey: error
            ]
        )
    }
}

@available(iOS 18.0, visionOS 2.0, *)
extension AnyLLMClient {
    init(_ client: CoreMLLLMClient) {
        self.init(
            textStream: { input in
                try await client.textStream(from: input)
            },
            cancel: {
                Task { await client.cancelActive() }
            },
            unload: {
                Task { await client.unload() }
            },
            reset: {
                await client.hardResetConversation()
            },
            syncSystemPrompt: { prompt in
                await client.syncSystemPrompt(prompt)
            },
            tokenCount: { text in
                try await client.countTokens(in: text)
            }
        )
    }
}
#endif
