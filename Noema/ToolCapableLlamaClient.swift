// ToolCapableLlamaClient.swift
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation

// MARK: - Tool-capable llama.cpp client with server mode support

public final class ToolCapableLlamaClient: ToolCapableLLM, @unchecked Sendable {
    private let mode: LlamaMode
    private let modelName: String
    
    public enum LlamaMode {
        case server(baseURL: URL)
        case inProcess(client: NoemaLlamaClient)
    }
    
    public init(mode: LlamaMode, modelName: String = "llama-model") {
        self.mode = mode
        self.modelName = modelName
    }
    
    // MARK: - ToolCapableLLM Implementation
    
    public func generateWithTools(
        messages: [ToolChatMessage],
        tools: [ToolSpec]?,
        temperature: Float
    ) async throws -> ToolChatMessage {
        switch mode {
        case .server(let baseURL):
            return try await generateWithServerMode(
                baseURL: baseURL,
                messages: messages,
                tools: tools,
                temperature: temperature
            )
        case .inProcess:
            // For in-process mode, build a JSON-focused prompt with tool catalog and guidance
            let response = try await generateWithPrompt(
                prompt: buildPromptFromMessages(messages, tools: tools),
                stopTokens: ["\n\n"],
                temperature: temperature
            )
            return ToolChatMessage.assistant(response)
        }
    }

    public func generateWithPrompt(
        prompt: String,
        stopTokens: [String]?,
        temperature: Float
    ) async throws -> String {
        switch mode {
        case .server(let baseURL):
            return try await generateWithServerPrompt(
                baseURL: baseURL,
                prompt: prompt,
                temperature: temperature
            )
        case .inProcess(let client):
            return try await generateWithInProcessClient(
                client: client,
                prompt: prompt,
                temperature: temperature
            )
        }
    }
    
    // MARK: - Server Mode Implementation
    
    private func generateWithServerMode(
        baseURL: URL,
        messages: [ToolChatMessage],
        tools: [ToolSpec]?,
        temperature: Float
    ) async throws -> ToolChatMessage {
        let request = ChatRequest(
            model: modelName,
            messages: messages,
            tools: tools,
            toolChoice: tools?.isEmpty == false ? "auto" : nil,
            stream: false,
            temperature: temperature
        )
        
        let url = baseURL.appendingPathComponent("v1/chat/completions")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")

        let requestData = try JSONEncoder().encode(request)
        urlRequest.httpBody = requestData
        urlRequest.timeoutInterval = 60

        await logger.log("[ToolCapableLlamaClient] Sending request to \(url)")

        if NetworkKillSwitch.shouldBlock(request: urlRequest) {
            throw URLError(.notConnectedToInternet)
        }

        let usesLoopback = NetworkKillSwitch.isLoopback(url: url)
        let session: URLSession
        if usesLoopback {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.connectionProxyDictionary = [AnyHashable: Any]()
            session = URLSession(configuration: configuration)
        } else {
            NetworkKillSwitch.track(session: URLSession.shared)
            session = URLSession.shared
        }
        defer {
            if usesLoopback {
                session.finishTasksAndInvalidate()
            }
        }

        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolError.executionFailed("Invalid response type")
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw ToolError.executionFailed("Server error: \(errorMessage)")
        }
        
        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        
        guard let choice = chatResponse.choices.first else {
            throw ToolError.executionFailed("No choices in response")
        }
        
        await logger.log("[ToolCapableLlamaClient] Received response with \(choice.message.tool_calls?.count ?? 0) tool calls")
        
        return choice.message
    }
    
    private func generateWithServerPrompt(
        baseURL: URL,
        prompt: String,
        temperature: Float
    ) async throws -> String {
        let messages = [ToolChatMessage.user(prompt)]
        let response = try await generateWithServerMode(
            baseURL: baseURL,
            messages: messages,
            tools: nil,
            temperature: temperature
        )
        return response.content ?? ""
    }
    
    // MARK: - In-Process Mode Implementation
    
    private func generateWithInProcessClient(
        client: NoemaLlamaClient,
        prompt: String,
        temperature: Float
    ) async throws -> String {
        var fullResponse = ""
        let input = LLMInput.plain(prompt)
        for try await token in try await client.textStream(from: input) {
            fullResponse += token
        }
        return fullResponse
    }
    
    private func buildPromptFromMessages(_ messages: [ToolChatMessage]) -> String {
        return messages.compactMap { message in
            switch message.role {
            case "system":
                return "System: \(message.content ?? "")"
            case "user":
                return "User: \(message.content ?? "")"
            case "assistant":
                return "Assistant: \(message.content ?? "")"
            case "tool":
                return "Tool Result: \(message.content ?? "")"
            default:
                return nil
            }
        }.joined(separator: "\n") + "\nAssistant: "
    }

    private func buildPromptFromMessages(_ messages: [ToolChatMessage], tools: [ToolSpec]?) -> String {
        // Resolve system content via centralized resolver so we always match
        // ChatVM/systemPromptText and current tool armed state.
        // For llama.cpp, we can't see UI attachments here, so conservatively mark vision-capable
        // and assume no attached images for tool loop prompts.
        let availability = ToolAvailability(
            webSearch: tools?.contains(where: { $0.function.name == "noema.web.retrieve" }) == true
                && WebToolGate.isAvailable(currentFormat: .gguf),
            python: tools?.contains(where: { $0.function.name == "noema.python.execute" }) == true
                && PythonToolGate.isAvailable(currentFormat: .gguf),
            memory: tools?.contains(where: { $0.function.name == "noema.memory" }) == true
                && MemoryToolGate.isAvailable(currentFormat: .gguf),
            calculator: tools?.contains(where: { $0.function.name == "noema.math.calculate" }) == true,
            unitConverter: tools?.contains(where: { $0.function.name == "noema.units.convert" }) == true
        )
        var systemContent: String = SystemPromptResolver.general(
            currentFormat: .gguf,
            isVisionCapable: true,
            hasAttachedImages: false,
            toolAvailabilityOverride: availability
        )

        // If tools are available, add concise instructions and catalog.
        if let tools, !tools.isEmpty, availability.any {
            let catalog = generateJSONGrammarToolCatalog(tools)
            let usage = """
            Use tools only when they would materially improve the answer; otherwise answer directly.
            - Use `noema.web.retrieve` for fresh/current information.
            - Use `noema.math.calculate` for quick deterministic arithmetic or single-expression math.
            - Use `noema.units.convert` for deterministic unit conversions.
            - Use `noema.python.execute` for calculations, data processing, parsing, algorithms, or other computational work.
            - Use `noema.memory` for durable, cross-conversation facts such as stable user preferences or recurring project constraints.

            To call a tool, respond with ONLY one of these formats (no extra text):
            - JSON: {"tool_name": "tool.name", "arguments": {"param": "value"}}
            - XML: <tool_call>{"name": "tool.name", "arguments": {"param": "value"}}</tool_call>

            Requirements:
            1) First decide if a tool is needed; if not, answer normally.
            2) Valid JSON object inside either form.
            3) Use exact tool name from the catalog.
            4) Include required parameters; optional when helpful.
            5) Make exactly ONE tool call, then wait for the result.
            6) You may mention tools inside <think>, but finish reasoning and close the tag before emitting the <tool_call> tag or JSON object that actually triggers the call.
            7) Do NOT use code fences (```); emit only the JSON or the <tool_call> wrapper. Do not mix formats.
            8) Prefer calculator or unit conversion for simple math/conversion tasks; use Python for multi-step computation, data processing, or code-friendly analysis.
            9) For Python, always send runnable Python 3 and use print() for output.

            Available tools:
            """ + catalog
            systemContent += "\n\n" + usage
        }

        let sanitizedMessages = messages.filter { $0.role != "system" }
        return renderPromptWithSystemContent(systemContent, messages: sanitizedMessages)
    }

    private func generateJSONGrammarToolCatalog(_ tools: [ToolSpec]) -> String {
        return tools.map { tool in
            let params = tool.function.parameters.properties.map { name, param in
                "  - \(name) (\(param.type)): \(param.description)"
            }.joined(separator: "\n")
            return "- \(tool.function.name): \(tool.function.description)\nParameters:\n\(params)"
        }.joined(separator: "\n")
    }
}

// MARK: - Enhanced LlamaBackend with Tool Support

struct EnhancedLlamaBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.gguf]
    private var toolClient: ToolCapableLlamaClient?
    private var originalClient: NoemaLlamaClient?
    private var useServerMode: Bool = false
    private var preferXMLInProcess: Bool = false
    private var preferDeepseekInProcess: Bool = false
    
    mutating func load(_ installed: InstalledModel) async throws {
        // Check if server mode is requested via environment
        let serverURL = ProcessInfo.processInfo.environment["LLAMA_SERVER_URL"]
        
        if let urlString = serverURL, let url = URL(string: urlString) {
            // Use server mode
            useServerMode = true
            toolClient = ToolCapableLlamaClient(
                mode: .server(baseURL: url),
                modelName: installed.displayName
            )
            await logger.log("[EnhancedLlamaBackend] Using server mode with URL: \(url)")
        } else {
            // Use in-process mode
            useServerMode = false
            let client = try await NoemaLlamaClient.llama(url: installed.url)
            originalClient = client
            toolClient = ToolCapableLlamaClient(
                mode: .inProcess(client: client),
                modelName: installed.displayName
            )
            await logger.log("[EnhancedLlamaBackend] Using in-process mode")

            // Prefer DeepSeek-markers tool loop for DeepSeek-R1 Distill on Qwen; else XML for Qwen family
            let lowerName = installed.displayName.lowercased()
            if lowerName.contains("deepseek") && lowerName.contains("distill") && (lowerName.contains("qwen") || lowerName.contains("llama")) {
                preferDeepseekInProcess = true
            } else if lowerName.contains("qwen") {
                preferXMLInProcess = true
            }
        }
    }
    
    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        // For compatibility with existing code, use original streaming behavior
        if let originalClient = originalClient {
            return AsyncThrowingStream { continuation in
                // Stream tokens from the in-process client; respect cancellation via onTermination
                Task {
                    do {
                        let input = LLMInput.plain(request.prompt)
                        for try await token in try await originalClient.textStream(from: input) {
                            continuation.yield(.token(token))
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in
                    originalClient.cancel()
                }
            }
        }
        
        // For server mode, we'll need to implement streaming differently
        guard let toolClient = toolClient else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ToolError.executionFailed("Tool client not initialized"))
            }
        }
        let prompt = request.prompt
        return AsyncThrowingStream { continuation in
            let feeder = _TokenEventFeeder(continuation: continuation)
            Task {
                do {
                    let response = try await toolClient.generateWithPrompt(
                        prompt: prompt,
                        stopTokens: nil,
                        temperature: 0.7
                    )
                    let words = response.split(separator: " ")
                    for word in words {
                        await feeder.yield(.token(String(word) + " "))
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    await feeder.finish()
                } catch {
                    await feeder.finish(error: error)
                }
            }
            continuation.onTermination = { _ in
                // Nothing to cancel in server mode here; the request is awaited as a single response.
            }
        }
    }
    
    mutating func unload() {
        originalClient = nil
        toolClient = nil
    }
    
    // MARK: - Tool Loop Integration
    
    func runToolLoop(
        messages: inout [ToolChatMessage]
    ) async throws -> String {
        let registry = await ToolRegistry.shared
        guard let toolClient = toolClient else {
            throw ToolError.executionFailed("Tool client not initialized")
        }
        
        let toolLoop = ToolLoop(
            llm: toolClient,
            registry: registry,
            maxToolTurns: 4,
            temperature: 0.7
        )
        
        if useServerMode {
            return try await toolLoop.runWithOpenAITools(messages: &messages)
        } else if preferDeepseekInProcess {
            return try await toolLoop.runWithDeepseekMarkers(messages: &messages)
        } else if preferXMLInProcess {
            return try await toolLoop.runWithXMLGrammar(messages: &messages)
        } else {
            return try await toolLoop.runWithJSONGrammar(messages: &messages)
        }
    }
}

// Helper actor to safely feed events into an AsyncThrowingStream from async contexts
private actor _TokenEventFeeder {
    private let continuation: AsyncThrowingStream<TokenEvent, Error>.Continuation
    init(continuation: AsyncThrowingStream<TokenEvent, Error>.Continuation) {
        self.continuation = continuation
    }
    func yield(_ event: TokenEvent) {
        continuation.yield(event)
    }
    func finish() {
        continuation.finish()
    }
    func finish(error: Error) {
        continuation.finish(throwing: error)
    }
}

extension ToolCapableLlamaClient {
    private func renderPromptWithSystemContent(_ system: String, messages: [ToolChatMessage]) -> String {
#if canImport(UIKit) || os(visionOS)
        let family = ModelKind.detect(id: modelName)
        let history: [ChatVM.Msg] = messages.map { message in
            let text = message.content ?? ""
            return ChatVM.Msg(role: message.role, text: text)
        }
        let (prompt, _, _) = PromptBuilder.build(template: nil, family: family, history: history, system: system)
        return prompt
#else
        return renderFallbackPrompt(system: system, messages: messages)
#endif
    }

    private func renderFallbackPrompt(system: String, messages: [ToolChatMessage]) -> String {
        var lines: [String] = []
        let trimmedSystem = system.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            lines.append("System: \(trimmedSystem)")
        }
        for message in messages {
            let role = message.role.capitalized
            let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if content.isEmpty {
                lines.append("\(role):")
            } else {
                lines.append("\(role): \(content)")
            }
        }
        lines.append("Assistant: ")
        return lines.joined(separator: "\n")
    }
}

#endif
