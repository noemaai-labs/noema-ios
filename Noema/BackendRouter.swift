// BackendRouter.swift
import Foundation

struct GenerateRequest: Sendable { let prompt: String }
enum TokenEvent: Sendable { case token(String) }

protocol InferenceBackend {
    static var supported: Set<ModelFormat> { get }
    mutating func load(_ installed: InstalledModel) async throws
    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error>
    mutating func unload()
}

struct LlamaBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.gguf]
    private var client: NoemaLlamaClient?
    mutating func load(_ installed: InstalledModel) async throws {
        client = try await NoemaLlamaClient.llama(url: installed.url)
    }
    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = client else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1, 
                    userInfo: [NSLocalizedDescriptionKey: "LlamaBackend client not loaded"]))
                return
            }
            
            Task {
                do {
                    let input = LLMInput.plain(request.prompt)
                    for try await token in try await client.textStream(from: input) {
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    mutating func unload() { client = nil }
}

struct MLXBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.mlx]
    private var client: AnyLLMClient?
    mutating func load(_ installed: InstalledModel) async throws {
        if MLXBridge.isVLMModel(at: installed.url) {
            client = try await MLXBridge.makeVLMClient(url: installed.url)
        } else {
            client = try await MLXBridge.makeTextClient(url: installed.url, settings: nil)
        }
    }
    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = client else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1, 
                    userInfo: [NSLocalizedDescriptionKey: "MLXBackend client not loaded"]))
                return
            }
            
            Task {
                do {
                    let input = LLMInput.plain(request.prompt)
                    for try await token in try await client.textStream(from: input) {
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    mutating func unload() { client = nil }
}

struct AFMBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.afm]
    private var client: AnyLLMClient?

    mutating func load(_ installed: InstalledModel) async throws {
        let afmClient = AFMLLMClient()
        try await afmClient.load()
        client = AnyLLMClient(
            textStream: { input in
                try await afmClient.textStream(from: input)
            },
            cancel: nil,
            unload: { afmClient.unload() },
            syncSystemPrompt: { prompt in
                await afmClient.syncSystemPrompt(prompt)
            }
        )
    }

    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = client else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "AFMBackend client not loaded"]))
                return
            }

            Task {
                do {
                    let input = LLMInput.plain(request.prompt)
                    for try await token in try await client.textStream(from: input) {
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    mutating func unload() {
        client?.unload()
        client = nil
    }
}

struct CoreAIBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.coreai]
    private var client: AnyLLMClient?

    mutating func load(_ installed: InstalledModel) async throws {
        let resolved = try CoreAIModelResolver.resolve(modelURL: installed.url)
        let coreaiClient = CoreAILLMClient(resolved: resolved)
        try await coreaiClient.load()
        client = AnyLLMClient(
            textStream: { input in
                try await coreaiClient.textStream(from: input)
            },
            cancel: nil,
            unload: { coreaiClient.unload() },
            syncSystemPrompt: { prompt in
                await coreaiClient.syncSystemPrompt(prompt)
            }
        )
    }

    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = client else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "CoreAIBackend client not loaded"]))
                return
            }

            Task {
                do {
                    let input = LLMInput.plain(request.prompt)
                    for try await token in try await client.textStream(from: input) {
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    mutating func unload() {
        client?.unload()
        client = nil
    }
}

#if os(iOS) || os(visionOS)
@available(iOS 18.0, visionOS 2.0, *)
struct CoreMLBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.ane]
    private var client: AnyLLMClient?

    mutating func load(_ installed: InstalledModel) async throws {
        let resolved = try ANEModelResolver.resolve(modelURL: installed.url)
        let settings = ModelSettings
            .resolvedANEModelSettings(modelID: installed.modelID, modelURL: resolved.modelRoot)
            .settings
        let coreMLClient = try CoreMLLLMClient(resolvedModel: resolved, settings: settings)
        try await coreMLClient.load()
        client = AnyLLMClient(coreMLClient)
    }

    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = client else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "CoreMLBackend client not loaded"]))
                return
            }

            Task {
                do {
                    let input = LLMInput.plain(request.prompt)
                    for try await token in try await client.textStream(from: input) {
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    mutating func unload() {
        client?.unload()
        client = nil
    }
}
#endif

@available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *)
struct ExecuTorchBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.et]
    private var client: AnyLLMClient?

    mutating func load(_ installed: InstalledModel) async throws {
        let artifacts = try ETModelResolver.resolveLoadArtifacts(for: installed.url)

        let effectiveSettings: ModelSettings = {
            var settings = ModelSettings.default(for: .et)
            settings.etBackend = ETBackendDetector.effectiveBackend(
                userSelected: installed.etBackend,
                detected: nil
            )
            return settings
        }()

        let etClient = ExecuTorchLLMClient(
            modelPath: artifacts.pteURL.path,
            tokenizerPath: artifacts.tokenizerURL.path,
            isVision: installed.isMultimodal,
            settings: effectiveSettings
        )
        try await etClient.load()
        client = AnyLLMClient(etClient)
    }

    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = client else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "ExecuTorchBackend client not loaded"]))
                return
            }

            Task {
                do {
                    let input = LLMInput.plain(request.prompt)
                    for try await token in try await client.textStream(from: input) {
                        continuation.yield(.token(token))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    mutating func unload() {
        client?.unload()
        client = nil
    }
}

final class BackendRouter {
    private var backend: (any InferenceBackend)?
    func open(model: InstalledModel) async throws -> any InferenceBackend {
        if let current = backend { var c = current; c.unload() }
        if LlamaBackend.supported.contains(model.format) {
            var b = LlamaBackend()
            try await b.load(model)
            backend = b
            return b
        }
        if MLXBackend.supported.contains(model.format) {
            if !DeviceGPUInfo.supportsGPUOffload {
                throw NSError(
                    domain: "Noema",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "MLX models require A13+ GPU on this device. For best performance, use ET models; otherwise use GGUF."]
                )
            }
            var b = MLXBackend()
            try await b.load(model)
            backend = b
            return b
        }
        if AFMBackend.supported.contains(model.format) {
            var b = AFMBackend()
            try await b.load(model)
            backend = b
            return b
        }
        if CoreAIBackend.supported.contains(model.format) {
            var b = CoreAIBackend()
            try await b.load(model)
            backend = b
            return b
        }
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) {
            if ExecuTorchBackend.supported.contains(model.format) {
                var b = ExecuTorchBackend()
                try await b.load(model)
                backend = b
                return b
            }
        }
        #if os(iOS) || os(visionOS)
        if #available(iOS 18.0, visionOS 2.0, *) {
            if CoreMLBackend.supported.contains(model.format) {
                var b = CoreMLBackend()
                try await b.load(model)
                backend = b
                return b
            }
        }
        #endif
        throw NSError(domain: "Noema", code: -1, userInfo: [NSLocalizedDescriptionKey: "Requested backend unavailable on this build"])
    }
}
