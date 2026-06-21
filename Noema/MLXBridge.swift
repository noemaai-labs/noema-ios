// MLXBridge.swift
import Foundation
import CoreGraphics
import ImageIO
#if canImport(MLXLLM)
import MLXLLM
#endif
#if canImport(MLXLMCommon)
import MLXLMCommon
#endif
#if canImport(MLXVLM) 
import MLXVLM
#endif
#if canImport(MLX)
import MLX
#endif

enum MLXBridgeError: Error, LocalizedError {
    case modelNotFound
    case invalidModel
    case backendUnavailable
    case imagesUnsupported
    case notVLM
    case notImplemented
    case unsupportedVLMType(String)
    case missingPreprocessorConfig
    case vlmLoadingFailed(String)
    var errorDescription: String? {
        switch self {
        case .modelNotFound: return "MLX model directory not found"
        case .invalidModel: return "Invalid or unsupported MLX model"
        case .backendUnavailable: return "MLX backend not available - dependencies are installed but API may need updates"
        case .imagesUnsupported: return "This MLX model cannot accept images"
        case .notVLM: return "Requested VLM client for text-only model"
        case .notImplemented: return "MLX backend ready - API implementation needs fine-tuning for your mlx-swift-examples version"
        case .unsupportedVLMType(let type): return "Unsupported VLM model type '\(type)'. Supported types: paligemma, qwen2_vl, qwen2_5_vl, qwen3_vl, idefics3, gemma3, smolvlm"
        case .missingPreprocessorConfig: return "VLM model is missing preprocessor_config.json - this file is required for vision models"
        case .vlmLoadingFailed(let details): return "VLM loading failed: \(details)"
        }
    }
}

@inline(__always)
private func postMLXLoadProgress(_ value: Double) {
    let clamped = min(0.97, max(0.0, value))
    NotificationCenter.default.post(
        name: .mlxModelLoadProgress,
        object: nil,
        userInfo: ["progress": clamped]
    )
}

enum MLXBridge {
    // Debug helper to check MLX availability
    static func checkMLXAvailability() {
        print("[MLXBridge] Checking MLX availability...")
        
        #if canImport(MLXLLM)
        print("[MLXBridge] ✅ MLXLLM import successful")
        #else
        print("[MLXBridge] ❌ MLXLLM import failed")
        #endif
        
        #if canImport(MLXLMCommon)
        print("[MLXBridge] ✅ MLXLMCommon import successful")
        #else
        print("[MLXBridge] ❌ MLXLMCommon import failed")
        #endif
        
        #if canImport(MLX)
        print("[MLXBridge] ✅ MLX core import successful")
        #else
        print("[MLXBridge] ❌ MLX core import failed")
        #endif
        
        #if canImport(MLXVLM)
        print("[MLXBridge] ✅ MLXVLM import successful")
        #else
        print("[MLXBridge] ❌ MLXVLM import failed")
        #endif
        
        if #available(iOS 16.0, macOS 13.0, *) {
            print("[MLXBridge] ✅ Platform requirements met (iOS 16.0+ / macOS 13.0+)")
        } else {
            print("[MLXBridge] ❌ Platform requirements not met")
        }
        
        print("[MLXBridge] Implementation: Real MLX API integration with ModelContainer and streaming generation")
    }
    
    static func isVLMModel(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        let dir = isDir.boolValue ? url : url.deletingLastPathComponent()
        
        // Step 1: Check for vision-specific artifact files
        let visionArtifacts = [
            "vision_model.safetensors",
            "vision_weights.npz", 
            "vision.json",
            "vit_config.json",
            "vision_config.json",
            "clip_vision_model.safetensors",
            "vision_encoder.safetensors",
            "visual_encoder.safetensors",
            "image_processor.json",
            "processor_config.json",
            "preprocessor_config.json",
            // SmolVLM / MLX-vlm common artifacts
            "projector.json",
            "projector.safetensors",
            "open_clip_config.json",
            "siglip_config.json"
        ]
        
        for artifact in visionArtifacts {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(artifact).path) {
                return true
            }
        }
        
        // Step 2: Parse config.json for vision-related configuration
        let cfg = dir.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: cfg),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // If config.json is missing or malformed, fallback to directory name patterns
            return fallbackDirectoryNameDetection(dir: dir)
        }
        
        // Check for explicit VLM type indicators in config
        if let type = json["type"] as? String, type.lowercased() == "vlm" {
            return true
        }
        
        // Check model_type for VLM indicators (avoid over-broad matches like generic "gemma3n")
        if let mt = (json["model_type"] as? String)?.lowercased() {
            let vlmModelTypes = [
                "vision_language_model",
                "vision-language",
                "vlm",
                "qwen_vl", "qwen-vl", "qwen2-vl",
                "pixtral",
                "llava", "minicpm", "internvl", "phi-3-vision", "glm-4v",
                // IDEFICS family (used by SmolVLM)
                "idefics3",
                // SmolVLM family markers occasionally show up in model_type
                "smolvlm", "smol-vlm"
            ]
            if vlmModelTypes.contains(where: { mt.contains($0) }) { return true }
        }
        
        // Check for vision encoder configuration block
        if json["vision_encoder"] != nil || json["vision"] != nil {
            return true
        }
        
        // Check for comprehensive vision-related configuration keys
        let visionKeys: [String] = [
            "vision_encoder", "vision_config", "vision_tower",
            "image_processor", "mm_projector_type", "multi_modal_projector", 
            "image_token_index", "image_grid_pinpoints", "image_size",
            "clip_vision_model", "siglip_vision_model",
            "vision_model_name", "vision_feature_layer", "vision_feature_select_strategy",
            "mm_vision_tower", "mm_vision_select_layer", "mm_vision_select_feature",
            // SmolVLM / mlx-vlm configs
            "projector_type", "projector_hidden_size", "vision_backbone", "image_embed_dim"
        ]
        if visionKeys.contains(where: { json[$0] != nil }) { return true }
        
        // Check architectures array for vision capability indicators
        if let arch = json["architectures"] as? [String] {
            if arch.contains(where: { s in
                let l = s.lowercased()
                return l.contains("vision") || l.contains("vlm") || l.contains("vl-") || 
                       l.contains("llava") || l.contains("gemma-3") || l.contains("clip") ||
                       l.contains("multimodal") || l.contains("mm")
            }) { return true }
        }
        
        // Step 3: Fallback to directory name patterns if config doesn't indicate VLM
        return fallbackDirectoryNameDetection(dir: dir)
    }
    
    private static func fallbackDirectoryNameDetection(dir: URL) -> Bool {
        let name = dir.lastPathComponent.lowercased()
        let vlmPatterns = [
            "-vl", "vlm", "vision", "clip", "vlxm", 
            // Do not rely on generic gemma-3 name substrings to avoid false positives for LM-only variants
            // "gemma-3n", "gemma-3",
            "llava", "minicpm",
            "internvl", "qwen-vl", "pixtral", "phi-3-vision",
            "multimodal", "mm-", "-mm",
            // SmolVLM patterns
            "smolvlm", "smol-vlm"
        ]
        return vlmPatterns.contains(where: { name.contains($0) })
    }

    static func makeTextClient(url: URL, settings: ModelSettings? = nil) async throws -> AnyLLMClient {
        let dir = directoryForMLX(url)

        print("[MLXBridge] makeTextClient called with url: \(url.path)")
        print("[MLXBridge] Model directory: \(dir.path)")

        // Check availability first
        checkMLXAvailability()

        // Sanitize known problematic fields before handing the directory to MLX.
        sanitizeMLXConfigIfNeeded(at: dir)

#if canImport(MLX)
        // Disable MLX on devices without reliable GPU offload; CPU-only MLX is too slow
        if !DeviceGPUInfo.supportsGPUOffload {
            let msg = "MLX models require A13+ GPU. Use a GGUF model on this device."
            print("[MLXBridge] \(msg)")
            return AnyLLMClient.makeFailing(message: msg)
        }
        // Note: MLX Swift does not expose a global default dtype setter.
        // On pre‑A13 devices we avoid BF16 by preferring FP16 models at load time.
        // Keep this branch for future adjustments if MLX adds such API.
        _ = DeviceGPUInfo.requiresFloat16
#endif

        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
            print("[MLXBridge] config.json not found at: \(dir.appendingPathComponent("config.json").path)")
            throw MLXBridgeError.invalidModel
        }
        
        if #available(macOS 13.0, iOS 16.0, *) {
            let client = try await MLXTextClient(
                modelDirectory: dir,
                settings: settings
            )
            return AnyLLMClient(client)
        } else {
            print("[MLXBridge] Platform version too old")
            return AnyLLMClient.makeFailing(message: "MLX text backend requires macOS 13.0+ or iOS 16.0+")
        }
    }

    static func makeVLMClient(url: URL, settings: ModelSettings? = nil) async throws -> AnyLLMClient {
        let dir = directoryForMLX(url)

        print("[MLXBridge] makeVLMClient called with url: \(url.path)")
        print("[MLXBridge] VLM Model directory: \(dir.path)")

        // Check availability first
        checkMLXAvailability()

        // Sanitize known problematic fields before handing the directory to MLX.
        sanitizeMLXConfigIfNeeded(at: dir)

        // Early validation of VLM requirements
        let validation = validateVLMDirectory(at: dir)
        print("[MLXBridge] VLM validation - model_type: \(validation.modelType ?? "nil"), issues: \(validation.issues)")

        if !validation.issues.isEmpty {
            for issue in validation.issues {
                print("[MLXBridge] VLM issue: \(issue)")
            }
        }

#if canImport(MLX)
        // Disable MLX on devices without reliable GPU offload; CPU-only MLX is too slow
        if !DeviceGPUInfo.supportsGPUOffload {
            let msg = "MLX VLM requires A13+ GPU. Use a GGUF VLM on this device."
            print("[MLXBridge] \(msg)")
            return AnyLLMClient.makeFailing(message: msg)
        }
        // Note: MLX Swift does not expose a global default dtype setter.
        // On pre‑A13 devices we avoid BF16 by preferring FP16 models at load time.
        _ = DeviceGPUInfo.requiresFloat16
#endif

        // Do not hard-fail if detection is uncertain; continue with VLM client and let runtime decide
        if !isVLMModel(at: dir) {
            print("[MLXBridge] VLM detection is uncertain; proceeding with cautious VLM/text fallback")
        }

        if #available(macOS 13.0, iOS 16.0, *) {
            let client = try await MLXVLMClient(modelDirectory: dir, settings: settings)
            return AnyLLMClient(client)
        } else {
            print("[MLXBridge] Platform version too old for VLM")
            return AnyLLMClient.makeFailing(message: "MLX VLM backend requires macOS 13.0+ or iOS 16.0+")
        }
    }

    private static func directoryForMLX(_ url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    /// MLX's config decoder treats `quantization.mode` as a numeric/enum. Some community
    /// configs (e.g., Olmo-3-7B-Think-6bit) ship it as a string ("affine"), causing a
    /// type-mismatch crash. We rewrite the config in-place to drop string-valued modes.
    private static func sanitizeMLXConfigIfNeeded(at dir: URL) {
        let cfgPath = dir.appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: cfgPath.path),
              let data = try? Data(contentsOf: cfgPath),
              var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        var changed = false

        func stripStringMode(in key: String) -> Bool {
            guard var block = json[key] as? [String: Any] else { return false }
            guard let mode = block["mode"] as? String else { return false }
            // Only remove when it's a string; leave numeric/enum values intact.
            print("[MLXBridge] Stripping string quantization mode (\(mode)) from \(key)")
            block.removeValue(forKey: "mode")
            json[key] = block
            return true
        }

        if stripStringMode(in: "quantization") { changed = true }
        if stripStringMode(in: "quantization_config") { changed = true }

        // Also handle nested quantization in text_config and vision_config (common in VLM models)
        for nestedKey in ["text_config", "vision_config"] {
            if var nested = json[nestedKey] as? [String: Any],
               var quant = nested["quantization"] as? [String: Any],
               quant["mode"] is String {
                print("[MLXBridge] Stripping nested quantization mode from \(nestedKey)")
                quant.removeValue(forKey: "mode")
                nested["quantization"] = quant
                json[nestedKey] = nested
                changed = true
            }
        }

        guard changed, let newData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) else {
            return
        }
        do {
            try newData.write(to: cfgPath, options: .atomic)
            print("[MLXBridge] Wrote sanitized config.json to \(cfgPath.path)")
        } catch {
            print("[MLXBridge] Failed to write sanitized config.json: \(error)")
        }
    }

    // MARK: - VLM Validation Helpers

    /// Supported VLM model types in mlx-swift-lm
    private static let supportedVLMTypes: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl",
        "idefics3", "gemma3", "smolvlm", "fastvlm", "llava_qwen2"
    ]

    /// Check if a model type string is a supported VLM type
    static func isKnownVLMType(_ modelType: String) -> Bool {
        let normalized = modelType.lowercased()
        return supportedVLMTypes.contains(normalized)
    }

    /// Validates VLM model directory has all required files and returns diagnostic info
    static func validateVLMDirectory(at dir: URL) -> (isValid: Bool, modelType: String?, issues: [String]) {
        let fm = FileManager.default
        var issues: [String] = []
        var modelType: String?

        // Check config.json
        let configPath = dir.appendingPathComponent("config.json")
        guard fm.fileExists(atPath: configPath.path) else {
            issues.append("Missing config.json")
            return (false, nil, issues)
        }

        // Parse model_type from config.json
        if let data = try? Data(contentsOf: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            modelType = json["model_type"] as? String

            if let mt = modelType {
                if !isKnownVLMType(mt) {
                    issues.append("model_type '\(mt)' is not a supported VLM type")
                }
            } else {
                issues.append("config.json missing model_type field")
            }
        } else {
            issues.append("Failed to parse config.json")
        }

        // Check preprocessor_config.json (required for VLM)
        let preprocessorPath = dir.appendingPathComponent("preprocessor_config.json")
        if !fm.fileExists(atPath: preprocessorPath.path) {
            issues.append("Missing preprocessor_config.json (required for VLM models)")
        }

        // Check for weight files
        let hasWeights = fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path) ||
                         fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors.index.json").path)
        if !hasWeights {
            issues.append("No model weights found (model.safetensors or model.safetensors.index.json)")
        }

        // Check for sharded model with potential placeholder conflict
        let indexPath = dir.appendingPathComponent("model.safetensors.index.json")
        let singlePath = dir.appendingPathComponent("model.safetensors")
        if fm.fileExists(atPath: indexPath.path) && fm.fileExists(atPath: singlePath.path) {
            if let attrs = try? fm.attributesOfItem(atPath: singlePath.path),
               let size = attrs[.size] as? Int64,
               size < 1000 {
                // This is likely a placeholder file that can cause loading issues
                print("[MLXBridge] Warning: Found small model.safetensors (\(size) bytes) alongside index file - this may cause issues")
                issues.append("Potential placeholder model.safetensors file detected (\(size) bytes) - consider removing it")
            }
        }

        return (issues.isEmpty, modelType, issues)
    }

    /// Lists model directory contents for debugging
    static func logModelDirectoryContents(at dir: URL) {
        print("[MLXBridge] === Model Directory Contents ===")
        print("[MLXBridge] Path: \(dir.path)")

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            print("[MLXBridge] Failed to list directory contents")
            return
        }

        let fm = FileManager.default
        for file in contents.sorted() {
            let filePath = dir.appendingPathComponent(file).path
            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int64 {
                let sizeStr = size > 1_000_000 ? "\(size / 1_000_000) MB" : "\(size) bytes"
                print("[MLXBridge]   \(file) (\(sizeStr))")
            } else {
                print("[MLXBridge]   \(file)")
            }
        }
        print("[MLXBridge] ================================")
    }
}

// MARK: - Prompt form shared by the MLX clients

/// Sendable intermediate between Noema's `ChatMessage` history and MLX's
/// `Chat.Message` (which is not Sendable and only exists when MLX is linked).
struct MLXChatTurn: Sendable, Equatable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
    }

    var role: Role
    var content: String
    var imagePaths: [String] = []
}

extension MLXBridge {
    static let gpuCacheLimitBytes = 20 * 1024 * 1024

    /// Folds a `ChatMessage` history into structured turns. Tool results have
    /// no first-class role in most chat templates, so they are folded into a
    /// user turn the model can read.
    static func chatTurns(from messages: [ChatMessage]) -> [MLXChatTurn] {
        messages.map { message in
            switch message.role.lowercased() {
            case "system":
                return MLXChatTurn(role: .system, content: message.content)
            case "assistant", "🤖":
                return MLXChatTurn(role: .assistant, content: message.content)
            case "tool":
                return MLXChatTurn(role: .user, content: "Tool result:\n\(message.content)")
            default:
                return MLXChatTurn(role: .user, content: message.content)
            }
        }
    }
}

#if canImport(MLXLMCommon)
extension MLXBridge {
    /// Maps Noema's sampling settings onto MLX generation parameters. Library
    /// defaults are kept when no settings are available.
    static func generateParameters(settings: ModelSettings?, maxOutputTokens: Int?) -> GenerateParameters {
        var parameters = GenerateParameters()
        if let settings {
            parameters.temperature = Float(settings.temperature)
            parameters.topP = Float(settings.topP)
            parameters.topK = max(0, settings.topK)
            parameters.minP = Float(settings.minP)
            parameters.repetitionPenalty = settings.repetitionPenalty > 1.0 ? settings.repetitionPenalty : nil
            parameters.repetitionContextSize = max(1, settings.repeatLastN)
            parameters.presencePenalty = settings.presencePenalty != 0 ? settings.presencePenalty : nil
            parameters.frequencyPenalty = settings.frequencyPenalty != 0 ? settings.frequencyPenalty : nil
        }
        parameters.maxTokens = maxOutputTokens
        return parameters
    }

    static func chatMessages(from turns: [MLXChatTurn]) -> [Chat.Message] {
        turns.map { turn in
            let images: [UserInput.Image] = turn.imagePaths.map { .url(URL(fileURLWithPath: $0)) }
            switch turn.role {
            case .system:
                return .system(turn.content, images: images)
            case .assistant:
                return .assistant(turn.content, images: images)
            case .user:
                return .user(turn.content, images: images)
            }
        }
    }
}
#endif

// MARK: - MLX Text Client Implementation

@available(macOS 13.0, iOS 16.0, *)
public final class MLXTextClient: @unchecked Sendable {
    #if canImport(MLXLLM) && canImport(MLXLMCommon)
    private var modelContainer: ModelContainer?
    #endif
    private let modelDirectory: URL
    private let settings: ModelSettings?
    private var streamTask: Task<Void, Never>? = nil

    // Internal because ModelSettings is an internal type; in-module callers
    // construct clients via MLXBridge factories.
    init(
        modelDirectory: URL,
        settings: ModelSettings? = nil
    ) async throws {
        self.modelDirectory = modelDirectory
        self.settings = settings
        try await load()
    }
    
    deinit {
        unload()
    }
    
    private func load() async throws {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        print("[MLXBridge] Attempting to load MLX model from: \(modelDirectory.path)")
        postMLXLoadProgress(0.12)
        
        // Check what files are actually in the model directory
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: modelDirectory.path)
            print("[MLXBridge] Model directory contents: \(contents)")
            
            // Check for required MLX files
            let configPath = modelDirectory.appendingPathComponent("config.json")
            let hasConfig = FileManager.default.fileExists(atPath: configPath.path)
            print("[MLXBridge] config.json exists: \(hasConfig)")
            
            if !hasConfig {
                print("[MLXBridge] Missing config.json file - this may not be a properly formatted MLX model")
                throw MLXBridgeError.invalidModel
            }
            postMLXLoadProgress(0.3)
        } catch {
            print("[MLXBridge] Error checking model directory: \(error)")
            throw MLXBridgeError.modelNotFound
        }
        
        if #available(iOS 16.0, macOS 13.0, *) {
            do {
                // Set GPU cache limit for MLX only when GPU offload is supported
                #if canImport(MLX)
                if DeviceGPUInfo.supportsGPUOffload {
                    MLX.GPU.set(cacheLimit: MLXBridge.gpuCacheLimitBytes)
                }
                #endif

                // Create a model configuration pointing directly to the provided model directory
                print("[MLXBridge] Creating configuration from directory: \(modelDirectory.path)")
                let configuration = ModelConfiguration(directory: modelDirectory)
                postMLXLoadProgress(0.55)
                
                print("[MLXBridge] Attempting to load model container...")
                modelContainer = try await LLMModelFactory.shared.loadContainer(configuration: configuration)
                print("[MLXBridge] Model container loaded successfully")
                postMLXLoadProgress(0.95)
                
                print("[MLXBridge] Successfully loaded MLX model")
            } catch {
                print("[MLXBridge] Failed to load MLX model: \(error)")
                throw error
            }
        } else {
            throw MLXBridgeError.backendUnavailable
        }
        #else
        print("[MLXBridge] MLXLLM not available in build - canImport check failed")
        throw MLXBridgeError.backendUnavailable
        #endif
    }
    
    func unload() {
        streamTask?.cancel()
        streamTask = nil
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        modelContainer = nil
        #endif
        #if canImport(MLX)
        MLX.GPU.set(cacheLimit: 0)
        #endif
    }
}

/// Prompt form resolved from `LLMInput`. `.chat` lets the model's own chat
/// template format the conversation exactly once; `.raw` is an
/// already-formatted completion prompt that must NOT be re-templated.
enum MLXPromptForm: Sendable, Equatable {
    case chat([MLXChatTurn])
    case raw(String)
}

extension MLXTextClient {
    public func textStream(from input: LLMInput) async throws -> AsyncThrowingStream<String, Error> {
        #if canImport(MLXLLM) && canImport(MLXLMCommon)
        guard let container = modelContainer else {
            throw MLXBridgeError.backendUnavailable
        }

        let form: MLXPromptForm
        switch input.content {
        case .plain(let text):
            form = .raw(text)
        case .messages(let messages):
            form = .chat(MLXBridge.chatTurns(from: messages))
        case .multimodal(let text, let images):
            // Explicitly reject images for text-only MLX models to avoid misleading behavior
            if !images.isEmpty {
                throw MLXBridgeError.imagesUnsupported
            }
            form = .raw(text)
        case .multimodalMessages(let messages, let images):
            if !images.isEmpty {
                throw MLXBridgeError.imagesUnsupported
            }
            form = .chat(MLXBridge.chatTurns(from: messages))
        }

        let parameters = MLXBridge.generateParameters(
            settings: settings,
            maxOutputTokens: input.generationOptions.maxOutputTokens
        )

        return AsyncThrowingStream<String, Error> { [weak self] continuation in
            let task = Task {
                do {
                    try await container.perform { (context: ModelContext) in
                        let lmInput: LMInput
                        switch form {
                        case .chat(let turns):
                            let userInput = UserInput(chat: MLXBridge.chatMessages(from: turns))
                            lmInput = try await context.processor.prepare(input: userInput)
                        case .raw(let text):
                            let tokens = context.tokenizer.encode(text: text)
                            lmInput = LMInput(tokens: MLXArray(tokens))
                        }
                        let stream = try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                        for await generation in stream {
                            if Task.isCancelled { break }
                            if let chunk = generation.chunk {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self?.streamTask = task
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        #else
        return AsyncThrowingStream<String, Error> { continuation in
            continuation.finish(throwing: MLXBridgeError.backendUnavailable)
        }
        #endif
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }
}

// MARK: - MLX VLM Client Implementation

@available(macOS 13.0, iOS 16.0, *)
public final class MLXVLMClient: @unchecked Sendable {
    #if canImport(MLXVLM) && canImport(MLXLMCommon)
    private var modelContainer: ModelContainer?
    #endif
    private var modelTypeHint: String?
    private let modelDirectory: URL
    private let settings: ModelSettings?
    private var streamTask: Task<Void, Never>? = nil

    // Internal because ModelSettings is an internal type; in-module callers
    // construct clients via MLXBridge factories.
    init(modelDirectory: URL, settings: ModelSettings? = nil) async throws {
        self.modelDirectory = modelDirectory
        self.settings = settings
        try await load()
    }
    
    deinit {
        unload()
    }
    
    private func load() async throws {
        print("[MLXBridge] Attempting to load VLM model from: \(modelDirectory.path)")
        postMLXLoadProgress(0.12)

        // Log directory contents for debugging
        MLXBridge.logModelDirectoryContents(at: modelDirectory)

        // Validate VLM directory structure and required files
        let validation = MLXBridge.validateVLMDirectory(at: modelDirectory)
        modelTypeHint = validation.modelType?.lowercased()

        if !validation.issues.isEmpty {
            print("[MLXBridge] VLM validation issues:")
            for issue in validation.issues {
                print("[MLXBridge]   - \(issue)")
            }
        }
        postMLXLoadProgress(0.3)

        // Check for critical issues that would prevent loading
        if let mt = validation.modelType, !MLXBridge.isKnownVLMType(mt) {
            print("[MLXBridge] ERROR: Unsupported VLM type '\(mt)'")
            throw MLXBridgeError.unsupportedVLMType(mt)
        }

        // Check for missing preprocessor_config.json
        let preprocessorPath = modelDirectory.appendingPathComponent("preprocessor_config.json")
        if !FileManager.default.fileExists(atPath: preprocessorPath.path) {
            print("[MLXBridge] ERROR: Missing preprocessor_config.json")
            throw MLXBridgeError.missingPreprocessorConfig
        }
        postMLXLoadProgress(0.45)

        #if canImport(MLXVLM) && canImport(MLXLMCommon)
        if #available(iOS 16.0, macOS 13.0, *) {
            // Set GPU cache limit for MLX only when GPU offload is supported
            #if canImport(MLX)
            if DeviceGPUInfo.supportsGPUOffload {
                MLX.GPU.set(cacheLimit: MLXBridge.gpuCacheLimitBytes)
            }
            #endif

            let configuration = ModelConfiguration(directory: modelDirectory)
            print("[MLXBridge] Created ModelConfiguration for directory: \(modelDirectory.path)")
            print("[MLXBridge] Calling VLMModelFactory.shared.loadContainer()...")
            postMLXLoadProgress(0.65)

            do {
                // Use VLMModelFactory from MLXVLM to load vision-language models
                modelContainer = try await VLMModelFactory.shared.loadContainer(configuration: configuration)
                print("[MLXBridge] VLM container loaded successfully")
                postMLXLoadProgress(0.95)
            } catch {
                let errorStr = String(describing: error)
                print("[MLXBridge] Failed to load VLM container: \(errorStr)")

                // Provide actionable error messages based on error type
                let userMessage: String
                if errorStr.contains("Invalid json header") || errorStr.contains("Invalid header") || errorStr.contains("load_safetensors") {
                    userMessage = """
                        VLM safetensors loading failed. This can happen if:
                        1. Model files are corrupted or incomplete - try re-downloading
                        2. Model is from an incompatible source - try mlx-community models instead
                        3. Sharded model files are malformed
                        Original error: \(errorStr)
                        """
                } else if errorStr.contains("model_type") || errorStr.contains("registry") || errorStr.contains("unknown model") {
                    userMessage = "VLM model type not recognized. Supported types: paligemma, qwen2_vl, qwen2_5_vl, qwen3_vl, idefics3, gemma3, smolvlm"
                } else if errorStr.contains("preprocessor") || errorStr.contains("processor") {
                    userMessage = "VLM processor configuration error. Ensure preprocessor_config.json is present and valid."
                } else {
                    userMessage = "VLM loading failed: \(errorStr)"
                }

                throw MLXBridgeError.vlmLoadingFailed(userMessage)
            }
        } else {
            throw MLXBridgeError.backendUnavailable
        }
        #else
        throw MLXBridgeError.backendUnavailable
        #endif
    }
    
    func unload() {
        streamTask?.cancel()
        streamTask = nil
        #if canImport(MLXVLM) && canImport(MLXLMCommon)
        modelContainer = nil
        #endif
        #if canImport(MLX)
        MLX.GPU.set(cacheLimit: 0)
        #endif
    }
}

extension MLXVLMClient {
    /// MLX VLM currently supports a single image. Returns the first supported
    /// image (resized to at most 448px on the long side, as in MLX examples),
    /// or throws when only unsupported attachments were provided.
    private static func preparedImagePath(from imagePaths: [String]) throws -> String? {
        guard !imagePaths.isEmpty else { return nil }

        let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "bmp", "tif", "tiff", "heic", "heif"]
        let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "webm", "mkv"]

        guard let rawImagePath = imagePaths.first(where: { path in
            supportedImageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
        }) else {
            if imagePaths.contains(where: { videoExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) {
                throw NSError(domain: "Noema", code: -7001, userInfo: [NSLocalizedDescriptionKey: "Video attachments are not supported by the MLX VLM backend in this build."])
            }
            throw MLXBridgeError.imagesUnsupported
        }

        let inputURL = URL(fileURLWithPath: rawImagePath)
        return (Self.resizeImageForVLM(inputURL, maxPixel: 448) ?? inputURL).path
    }

    /// Attaches the image to the last user turn so the model's chat template
    /// places the image tokens inside the right message.
    private static func attachImage(_ imagePath: String, to turns: [MLXChatTurn]) -> [MLXChatTurn] {
        var result = turns
        if let index = result.lastIndex(where: { $0.role == .user }) {
            result[index].imagePaths.append(imagePath)
        } else {
            result.append(MLXChatTurn(role: .user, content: "", imagePaths: [imagePath]))
        }
        return result
    }

    public func textStream(from input: LLMInput) async throws -> AsyncThrowingStream<String, Error> {
        #if canImport(MLXVLM) && canImport(MLXLMCommon)
        guard let container = modelContainer else {
            throw MLXBridgeError.backendUnavailable
        }

        let form: MLXPromptForm
        switch input.content {
        case .plain(let text):
            form = .raw(text)
        case .messages(let messages):
            form = .chat(MLXBridge.chatTurns(from: messages))
        case .multimodal(let text, let imagePaths):
            var turns = [MLXChatTurn(role: .user, content: text)]
            if let imagePath = try Self.preparedImagePath(from: imagePaths) {
                turns = Self.attachImage(imagePath, to: turns)
            }
            form = .chat(turns)
        case .multimodalMessages(let messages, let imagePaths):
            var turns = MLXBridge.chatTurns(from: messages)
            if let imagePath = try Self.preparedImagePath(from: imagePaths) {
                turns = Self.attachImage(imagePath, to: turns)
            }
            form = .chat(turns)
        }

        let parameters = MLXBridge.generateParameters(
            settings: settings,
            maxOutputTokens: input.generationOptions.maxOutputTokens
        )

        return AsyncThrowingStream<String, Error> { [weak self] continuation in
            let task = Task {
                do {
                    try await container.perform { (context: ModelContext) in
                        let lmInput: LMInput
                        switch form {
                        case .chat(let turns):
                            let userInput = UserInput(chat: MLXBridge.chatMessages(from: turns))
                            lmInput = try await context.processor.prepare(input: userInput)
                        case .raw(let text):
                            let tokens = context.tokenizer.encode(text: text)
                            lmInput = LMInput(tokens: MLXArray(tokens))
                        }
                        let stream = try MLXLMCommon.generate(
                            input: lmInput,
                            parameters: parameters,
                            context: context
                        )
                        for await generation in stream {
                            if Task.isCancelled { break }
                            if let chunk = generation.chunk {
                                continuation.yield(chunk)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            self?.streamTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        return AsyncThrowingStream<String, Error> { continuation in
            continuation.finish(throwing: MLXBridgeError.backendUnavailable)
        }
        #endif
    }

    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Best-effort resize to a square within `maxPixel` using CGImageSource thumbnailing.
    /// Returns a temporary JPEG URL, or nil on failure.
    private static func resizeImageForVLM(_ url: URL, maxPixel: Int) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let outURL = tmpDir.appendingPathComponent("noema_vlm_\(UUID().uuidString).jpg")
        guard let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, thumb, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return outURL
    }
}
