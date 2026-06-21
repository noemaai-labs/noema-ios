// ToolCapableMLXClient.swift
#if os(iOS) || os(macOS) || os(visionOS)
import Foundation

// MARK: - XML-style tool call structure (for models that use XML tags)

public struct XMLToolCall: Codable {
    public let name: String
    public let arguments: [String: AnyCodable]

    public init(name: String, arguments: [String: AnyCodable]) {
        self.name = name
        self.arguments = arguments
    }

    private enum CodingKeys: String, CodingKey { case name, tool_name, tool, arguments, args }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let n = try c.decodeIfPresent(String.self, forKey: .name) {
            self.name = n
        } else if let tn = try c.decodeIfPresent(String.self, forKey: .tool_name) {
            self.name = tn
        } else {
            self.name = try c.decode(String.self, forKey: .tool)
        }
        if let a = try c.decodeIfPresent([String: AnyCodable].self, forKey: .arguments) {
            self.arguments = a
        } else if let a = try c.decodeIfPresent([String: AnyCodable].self, forKey: .args) {
            self.arguments = a
        } else if let aStr = try c.decodeIfPresent(String.self, forKey: .arguments) ?? c.decodeIfPresent(String.self, forKey: .args) {
            if let data = aStr.data(using: .utf8), let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.arguments = any.mapValues { AnyCodable($0) }
            } else {
                self.arguments = [:]
            }
        } else {
            self.arguments = [:]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // When encoding, use canonical keys: name + arguments
        try c.encode(name, forKey: .name)
        try c.encode(arguments, forKey: .arguments)
    }
}

// MARK: - Tool-capable MLX client with JSON grammar support

public final class ToolCapableMLXClient: ToolCapableLLM {
    private let client: AnyLLMClient
    private let modelName: String
    
    public init(client: AnyLLMClient, modelName: String = "mlx-model") {
        self.client = client
        self.modelName = modelName
    }
    
    // MARK: - ToolCapableLLM Implementation
    
    public func generateWithTools(
        messages: [ToolChatMessage],
        tools: [ToolSpec]?,
        temperature: Float
    ) async throws -> ToolChatMessage {
        // MLX doesn't have native tool calling, so we use JSON grammar approach.
        // Build a tool-aware prompt and stream until we likely have a complete JSON object.
        let response = try await generateWithPrompt(
            prompt: buildPromptFromMessages(messages, tools: tools),
            stopTokens: nil,
            temperature: temperature
        )

        // Normalize common formatting issues (e.g., fenced code blocks) to maximize JSON detection success.
        let cleaned = normalizeGeneratedJSON(response)
        return ToolChatMessage.assistant(cleaned)
    }
    
    public func generateWithPrompt(
        prompt: String,
        stopTokens: [String]?,
        temperature: Float
    ) async throws -> String {
        return try await generateWithMLXClient(
            prompt: prompt,
            temperature: temperature
        )
    }
    
    // MARK: - MLX Implementation
    
    private func generateWithMLXClient(
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
    
    private func buildPromptFromMessages(_ messages: [ToolChatMessage], tools: [ToolSpec]? = nil) -> String {
        // Detect the appropriate tool calling strategy for this model
        let strategy = detectToolCallStrategy(modelName: modelName)
        
        switch strategy {
        case .xmlTags:
            return buildXMLStylePromptFromMessages(messages, tools: tools)
        case .jsonGrammar:
            return buildJSONGrammarPromptFromMessages(messages, tools: tools)
        case .openAI:
            // For now, default to XML style for MLX models
            return buildXMLStylePromptFromMessages(messages, tools: tools)
        }
    }
    
    private enum ToolCallStrategy {
        case xmlTags      // Qwen, tool-specific fine-tuned models  
        case jsonGrammar  // Llama, Mistral, Gemma, Phi and other generic models
        case openAI       // OpenAI-style API models (for future llama.cpp server mode)
    }
    
    private func detectToolCallStrategy(modelName: String) -> ToolCallStrategy {
        // The XML-style prompt is too complex for smaller MLX models.
        // Default to the more robust and direct JSON grammar approach.
        return .jsonGrammar
    }
    
    private func buildXMLStylePromptFromMessages(_ messages: [ToolChatMessage], tools: [ToolSpec]? = nil) -> String {
        // Build comprehensive system message using active system preset (if any) plus tool catalog/instructions
        let existingSystem = messages.first(where: { $0.role == "system" })?.content
        let availability = ToolAvailability(
            webSearch: tools?.contains(where: { $0.function.name == "noema.web.retrieve" }) == true
                && WebToolGate.isAvailable(currentFormat: .mlx),
            python: tools?.contains(where: { $0.function.name == "noema.python.execute" }) == true
                && PythonToolGate.isAvailable(currentFormat: .mlx),
            memory: tools?.contains(where: { $0.function.name == "noema.memory" }) == true
                && MemoryToolGate.isAvailable(currentFormat: .mlx),
            calculator: tools?.contains(where: { $0.function.name == "noema.math.calculate" }) == true,
            unitConverter: tools?.contains(where: { $0.function.name == "noema.units.convert" }) == true
        )
        var systemContent = existingSystem?.isEmpty == false ? existingSystem! : SystemPromptResolver.general(
            currentFormat: .mlx,
            isVisionCapable: true,
            hasAttachedImages: false,
            toolAvailabilityOverride: availability
        )
        if let tools, !tools.isEmpty {
            let toolSchemas = generateXMLToolSchemas(tools)
            let detailedInstructions = generateDetailedToolInstructions(tools)
            systemContent += "\n\n<tools>\n\(toolSchemas)\n</tools>\n\n" + detailedInstructions
        }

        let sanitizedMessages = messages.filter { $0.role != "system" }
        return renderPromptWithSystemContent(systemContent, messages: sanitizedMessages)
    }
    
    private func generateXMLToolSchemas(_ tools: [ToolSpec]) -> String {
        let toolSchemaStrings = tools.map { tool in
            // Convert ToolSpec to JSON string format expected by XML-style tool calling models
            let toolJSON: [String: Any] = [
                "type": "function",
                "function": [
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": [
                        "type": "object",
                        "properties": tool.function.parameters.properties.mapValues { param in
                            var paramDict: [String: Any] = [
                                "type": param.type,
                                "description": param.description
                            ]
                            if let enumValues = param.enum {
                                paramDict["enum"] = enumValues
                            }
                            return paramDict
                        },
                        "required": tool.function.parameters.required
                    ]
                ]
            ]
            
            // Convert to JSON string
            if let jsonData = try? JSONSerialization.data(withJSONObject: toolJSON, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            } else {
                // Fallback to manual JSON construction if serialization fails
                return "{\"type\":\"function\",\"function\":{\"name\":\"\(tool.function.name)\",\"description\":\"\(tool.function.description)\"}}"
            }
        }
        
        return toolSchemaStrings.joined(separator: "\n")
    }
    
    private func generateToolCatalogFromSpecs(_ tools: [ToolSpec]) -> String {
        let toolDescriptions = tools.map { tool in
            let parametersList = tool.function.parameters.properties.map { name, param in
                let required = tool.function.parameters.required.contains(name) ? " (required)" : " (optional)"
                return "  - \(name): \(param.type)\(required) - \(param.description)"
            }.joined(separator: "\n")
            
            return """
            Tool: \(tool.function.name)
            Description: \(tool.function.description)
            Parameters:
            \(parametersList)
            """
        }.joined(separator: "\n\n")
        
        return """
        Available tools:
        
        \(toolDescriptions)
        
        To use a tool, respond with ONLY this JSON format:
        {"tool_name": "tool.name", "arguments": {"param": "value"}}
        
        Otherwise, provide your final answer directly.
        """
    }
    
    private func containsCompleteJSON(_ text: String) -> Bool {
        // Check for XML-style tool call format with XML tags
        if containsCompleteXMLToolCall(text) {
            return true
        }
        
        // Fallback: Simple heuristic to detect complete JSON tool calls
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Check if it looks like a JSON object
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            // Try to parse it
            if let data = trimmed.data(using: .utf8),
               let _ = try? JSONSerialization.jsonObject(with: data) {
                return true
            }
        }
        
        return false
    }
    
    private func containsCompleteXMLToolCall(_ text: String) -> Bool {
        // Check if text contains complete <tool_call>...</tool_call> tags
        return text.contains("<tool_call>") && text.contains("</tool_call>")
    }
    
    // Parse tool call from XML format with XML tags (works with Qwen, Claude, etc.)
    private func parseXMLToolCall(_ response: String) throws -> XMLToolCall {
        // Extract JSON from between <tool_call> tags; be tolerant if closing tag is missing
        guard let startTag = response.range(of: "<tool_call>") else {
            throw ToolError.parseError("No <tool_call> tags found in response")
        }
        let innerSlice: Substring = {
            if let endTag = response.range(of: "</tool_call>") {
                return response[startTag.upperBound..<endTag.lowerBound]
            } else {
                return response[startTag.upperBound...]
            }
        }()
        var inner = String(innerSlice).trimmingCharacters(in: .whitespacesAndNewlines)

        // Strip optional code fences around JSON
        if inner.hasPrefix("```") {
            if let nl = inner.firstIndex(of: "\n") { inner = String(inner[inner.index(after: nl)...]) } else { inner = inner.replacingOccurrences(of: "```", with: "") }
        }
        if inner.hasSuffix("```") { inner.removeLast(3) }
        inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure there is a complete JSON object before attempting to decode
        guard let open = inner.firstIndex(of: "{"),
              let close = findMatchingBrace(in: inner, startingFrom: open) else {
            throw ToolError.parseError("Incomplete JSON inside <tool_call>")
        }
        var jsonString = String(inner[open...close])

        // Attempt strict decode first; if it fails, remove trailing commas and retry
        if let data = jsonString.data(using: .utf8), let call = try? JSONDecoder().decode(XMLToolCall.self, from: data) {
            return call
        }
        jsonString = removeTrailingCommas(jsonString)
        if let data2 = jsonString.data(using: .utf8), let call2 = try? JSONDecoder().decode(XMLToolCall.self, from: data2) {
            return call2
        }
        throw ToolError.parseError("Could not parse XML tool call JSON: \(jsonString)")
    }

    // Local helpers duplicated to avoid dep-cycles
    private func findMatchingBrace(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
        guard text[startIndex] == "{" else { return nil }
        var braceCount = 0
        var inString = false
        var escapeNext = false
        for index in text.indices[startIndex...] {
            let char = text[index]
            if escapeNext { escapeNext = false; continue }
            if char == "\\" && inString { escapeNext = true; continue }
            if char == "\"" { inString.toggle(); continue }
            if !inString {
                if char == "{" { braceCount += 1 }
                else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 { return index }
                }
            }
        }
        return nil
    }

    private func removeTrailingCommas(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var inString = false
        var escape = false
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if escape { out.append(c); escape = false; i = s.index(after: i); continue }
            if c == "\\" && inString { out.append(c); escape = true; i = s.index(after: i); continue }
            if c == "\"" { inString.toggle(); out.append(c); i = s.index(after: i); continue }
            if !inString && c == "," {
                var j = s.index(after: i)
                while j < s.endIndex, s[j].isWhitespace { j = s.index(after: j) }
                if j < s.endIndex, s[j] == "}" || s[j] == "]" { i = j; continue }
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }
    
    private func generateDetailedToolInstructions(_ tools: [ToolSpec]) -> String {
        let toolCount = tools.count
        let toolNames = tools.map { $0.function.name }.joined(separator: ", ")
        
        var instructions = """
        ## TOOLS READY AND AVAILABLE NOW

        IMPORTANT: You have \(toolCount) tool\(toolCount == 1 ? "" : "s") IMMEDIATELY AVAILABLE: \(toolNames)
        These tools are ALWAYS accessible - use them without hesitation!

        ### WHEN TO USE TOOLS:
        - Use web search for current information, recent events, or facts that may have changed.
        - Use calculator for quick deterministic arithmetic or single-expression math.
        - Use unit conversion for deterministic common-unit conversions.
        - Use Python for calculations, statistics, parsing, transformations, algorithms, or any other computational work.
        - If a tool would clearly improve accuracy, use it instead of guessing.
        
        ### EXACT TOOL FORMAT:
        <tool_call>
        {"name": "tool_name", "arguments": {"param1": "value1", "param2": "value2"}}
        </tool_call>
        
        ### CRITICAL REQUIREMENTS:
        1. Use EXACT tool name from schema
        2. Use "name" as JSON key (required for XML-style calling)
        3. Include required parameters plus helpful optional ones
        4. Properly quote and escape all string values
        5. NO other text when making tool call
        6. Wait for tool_response before continuing
        7. When the tool returns results, base your answer on them rather than guessing.
        
        ### For Qwen and Tool-Capable Models:
        - This XML format is your native tool calling method
        - Don't overthink - tools are ready for immediate use
        - Act confidently and use tools when they can help
        
        """
        
        // Add specific examples for each tool
        for tool in tools {
            instructions += "\n### \(tool.function.name.uppercased()) TOOL:\n"
            instructions += "**Purpose:** \(tool.function.description)\n"
            
            // Required parameters
            let requiredParams = tool.function.parameters.required
            if !requiredParams.isEmpty {
                instructions += "**Required Parameters:**\n"
                for param in requiredParams {
                    if let paramInfo = tool.function.parameters.properties[param] {
                        instructions += "- `\(param)` (\(paramInfo.type)): \(paramInfo.description)\n"
                    }
                }
            }
            
            // Optional parameters  
            let allParams = Set(tool.function.parameters.properties.keys)
            let optionalParams = allParams.subtracting(requiredParams)
            if !optionalParams.isEmpty {
                instructions += "**Optional Parameters:**\n"
                for param in optionalParams.sorted() {
                    if let paramInfo = tool.function.parameters.properties[param] {
                        instructions += "- `\(param)` (\(paramInfo.type)): \(paramInfo.description)\n"
                    }
                }
            }
            
            // Add specific examples based on tool type
            if tool.function.name == "noema.web.retrieve" {
                instructions += """
                **Example Usage:**
                <tool_call>
                {"name": "noema.web.retrieve", "arguments": {"query": "latest AI developments 2024", "count": 5, "safesearch": "moderate"}}
                </tool_call>
                
                **Notes:**
                - `count` can range from 1-5 (default: 3)
                - Use 5 only for very diverse queries and only if needed
                - `safesearch` options: "strict" (default), "moderate", "off"
                - Choose safesearch level based on content appropriateness needs
                
                """
            } else if tool.function.name == "noema.python.execute" {
                instructions += """
                **Example Usage:**
                <tool_call>
                {"name": "noema.python.execute", "arguments": {"code": "values = [2, 4, 8]\\nprint(sum(values) / len(values))"}}
                </tool_call>
                
                **Notes:**
                - Always send runnable Python 3 code
                - Use `print()` for any value you want returned
                - The runtime is sandboxed with a 30-second timeout and no network access
                
                """
            } else if tool.function.name == "noema.math.calculate" {
                instructions += """
                **Example Usage:**
                <tool_call>
                {"name": "noema.math.calculate", "arguments": {"expression": "sqrt(144) + 3 * 2"}}
                </tool_call>
                
                **Notes:**
                - Use for quick deterministic arithmetic, constants, and common math functions
                - Trigonometric functions use radians
                
                """
            } else if tool.function.name == "noema.units.convert" {
                instructions += """
                **Example Usage:**
                <tool_call>
                {"name": "noema.units.convert", "arguments": {"value": 10, "from_unit": "km", "to_unit": "mi"}}
                </tool_call>
                
                **Notes:**
                - Use source and target units from the same family
                - Supports length, mass, temperature, volume, time, data-size, and speed units
                
                """
            }
        }
        
        instructions += """
        ### After Tool Results:
        - Tool results will be provided in <tool_response> tags
        - Analyze the results and provide a helpful response to the user
        - Include relevant citations when using web search results (e.g., [1], [2])
        - If a tool returns an error, explain the issue and suggest alternatives
        
        ### Response Guidelines:
        - Be concise and relevant in your final response
        - Use the tool results to enhance your answer with current/accurate information
        - Treat web search findings as the authoritative/latest facts for current-information queries
        - Treat calculator and unit-conversion outputs as authoritative for the requested expression or conversion
        - Treat Python outputs as authoritative for the computation you executed
        - If multiple search results are returned, synthesize the most relevant information
        - Always maintain a helpful and professional tone
        
        ### IMPORTANT - USAGE GUIDELINES:
        - Tools are available RIGHT NOW - use them as soon as needed
        - If you're unsure whether to search, go ahead and search
        - Don't spend time reasoning about whether tools are available - they ARE
        - Only call a tool ONCE per query and wait for the response before calling again
        - Act decisively when tools can help
        """
        
        return instructions
    }
    
    private func buildJSONGrammarPromptFromMessages(_ messages: [ToolChatMessage], tools: [ToolSpec]? = nil) -> String {
        // Build a strong, explicit system instruction and serialize using model-aware templates
        let existingSystem = messages.first(where: { $0.role == "system" })?.content
        let availability = ToolAvailability(
            webSearch: tools?.contains(where: { $0.function.name == "noema.web.retrieve" }) == true
                && WebToolGate.isAvailable(currentFormat: .mlx),
            python: tools?.contains(where: { $0.function.name == "noema.python.execute" }) == true
                && PythonToolGate.isAvailable(currentFormat: .mlx),
            memory: tools?.contains(where: { $0.function.name == "noema.memory" }) == true
                && MemoryToolGate.isAvailable(currentFormat: .mlx),
            calculator: tools?.contains(where: { $0.function.name == "noema.math.calculate" }) == true,
            unitConverter: tools?.contains(where: { $0.function.name == "noema.units.convert" }) == true
        )
        var systemContent = existingSystem?.isEmpty == false ? existingSystem! : SystemPromptResolver.general(
            currentFormat: .mlx,
            isVisionCapable: true,
            hasAttachedImages: false,
            toolAvailabilityOverride: availability
        )
        if let tools, !tools.isEmpty, availability.any {
            if messages.last?.role == "tool" {
                systemContent += "\n\nAnalyze the provided tool results, treat them as authoritative, and generate a helpful, natural language response to the user's original question."
            } else {
                let allowed = tools.map { $0.function.name }
                let constraint = MLXJSONConstraints.createToolCallConstraint(toolNames: allowed)
                let jsonUsage = """
                TOOLS ARE ARMED AND AVAILABLE.
                Use `noema.web.retrieve` for fresh/current information.
                Use `noema.math.calculate` for quick deterministic arithmetic or single-expression math.
                Use `noema.units.convert` for deterministic unit conversions.
                Use `noema.python.execute` for calculations, code execution, parsing, algorithms, and other computational work.
                Use `noema.memory` for durable user preferences, project constraints, and other cross-conversation facts.

                Use tools when they will materially improve accuracy. If they are not needed, answer directly without calling tools.

                To use a tool, you MUST respond with ONLY a JSON object and absolutely no other text.
                The JSON object MUST have this exact structure:
                {"tool_name": "name_of_the_tool", "arguments": { "parameter": "value" }}

                CRITICAL REQUIREMENTS:
                1) First decide if a tool is necessary. If yes, call exactly one. If no, answer directly.
                2) Your tool-call response MUST be a valid JSON object (no backticks, no prose).
                3) Do NOT include any other text before or after the JSON object.
                4) Use the EXACT tool name from the catalog below in "tool_name".
                5) Include all required parameters; optional parameters when helpful.
                6) Make exactly ONE tool call, then WAIT for the tool result before continuing.
                7) You may mention tools inside your Chain of Thought, but finish reasoning before emitting the <tool_call> tag or JSON object that actually triggers the call.
                8) Prefer calculator or unit conversion for simple math/conversion tasks; use Python for multi-step computation, data processing, or code-friendly analysis.
                9) For Python, always send runnable Python 3 code and use print() for returned values.
                10) When a tool result arrives, base your final answer on it instead of guessing.
                11) Do not mix JSON and XML.

                Available tools (including web search if present):
                """ + generateJSONGrammarToolCatalog(tools) + "\n\n" + constraint
                systemContent += "\n\n" + jsonUsage
            }
        }

        let sanitizedMessages = messages.filter { $0.role != "system" }
        return renderPromptWithSystemContent(systemContent, messages: sanitizedMessages)
    }

    // Strip code fences and stray prose around a JSON object; also convert {"name":...,"arguments":...} ➜ {"tool_name":...,"arguments":...}
    private func normalizeGeneratedJSON(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove triple backtick fences if present
        if s.hasPrefix("```") {
            // Drop leading fence
            if let range = s.range(of: "\n") { s = String(s[range.upperBound...]) }
        }
        if s.hasSuffix("```") {
            // Drop trailing fence
            if let range = s.range(of: "```", options: .backwards) { s.removeSubrange(range) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Extract JSON block if the model wrapped it with extra commentary
        if let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") {
            s = String(s[start...end])
        }
        // Replace key "name" with "tool_name" only at the top level when the sibling key "arguments" exists
        if let data = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var top = obj
            if top["tool_name"] == nil, let n = top["name"] as? String, top["arguments"] != nil {
                top.removeValue(forKey: "name")
                top["tool_name"] = n
                if let outData = try? JSONSerialization.data(withJSONObject: top),
                   let out = String(data: outData, encoding: .utf8) {
                    return out
                }
            }
        }
        return s
    }

    private func generateJSONGrammarToolCatalog(_ tools: [ToolSpec]) -> String {
        // Generates a simple text description of tools for the prompt.
        return tools.map { tool in
            let params = tool.function.parameters.properties.map { name, param in
                "      \(name) (\(param.type)): \(param.description)"
            }.joined(separator: "\n")
            return """
            - \(tool.function.name): \(tool.function.description)\n        Parameters:\n\(params)
            """
        }.joined(separator: "\n")
    }
}

extension ToolCapableMLXClient {
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

// MARK: - Enhanced MLXBackend with Tool Support

struct EnhancedMLXBackend: InferenceBackend {
    static let supported: Set<ModelFormat> = [.mlx]
    private var toolClient: ToolCapableMLXClient?
    private var originalClient: AnyLLMClient?
    private var preferDeepseekInProcess: Bool = false
    
    mutating func load(_ installed: InstalledModel) async throws {
        // Use MLXBridge for both text-only and VLM models
        let client: AnyLLMClient
        if MLXBridge.isVLMModel(at: installed.url) {
            client = try await MLXBridge.makeVLMClient(url: installed.url)
        } else {
            client = try await MLXBridge.makeTextClient(url: installed.url, settings: nil)
        }
        
        originalClient = client
        toolClient = ToolCapableMLXClient(
            client: client,
            modelName: installed.displayName
        )
        
        await logger.log("[EnhancedMLXBackend] Loaded MLX model: \(installed.displayName)")
        let lower = installed.displayName.lowercased()
        if lower.contains("deepseek") && lower.contains("distill") && (lower.contains("qwen") || lower.contains("llama")) {
            preferDeepseekInProcess = true
        }
    }
    
    func generate(streaming request: GenerateRequest) -> AsyncThrowingStream<TokenEvent, Error> {
        AsyncThrowingStream { continuation in
            guard let client = originalClient else {
                continuation.finish(throwing: NSError(domain: "Noema", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "EnhancedMLXBackend client not loaded"]))
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
        
        if preferDeepseekInProcess {
            return try await toolLoop.runWithDeepseekMarkers(messages: &messages)
        } else {
            return try await toolLoop.runWithJSONGrammar(messages: &messages)
        }
    }
}

// MARK: - JSON Grammar Utilities for MLX

public struct MLXJSONConstraints {
    public static func createToolCallConstraint(toolNames: [String]) -> String {
        // This would integrate with MLX's constraint system if available
        // For now, we return a description that could be used in prompting
        let toolNameOptions = toolNames.map { "\"\($0)\"" }.joined(separator: ", ")
        
        return """
        Respond with valid JSON only. Schema:
        {
          "tool_name": one of [\(toolNameOptions)],
          "arguments": {
            // object with tool-specific parameters
          }
        }
        """
    }
    
    public static func validateJSONResponse(_ response: String, allowedTools: [String]) -> Bool {
        guard let data = response.data(using: .utf8) else { return false }
        
        do {
            let toolCall = try JSONDecoder().decode(SimpleToolCall.self, from: data)
            return allowedTools.contains(toolCall.tool_name)
        } catch {
            return false
        }
    }
}

// MARK: - System Prompt Resolution (shared)

private func resolveActiveSystemPrompt(from existing: String?) -> String {
    // Always use the current default system prompt. Do not reuse historical
    // system messages, as they may contain stale tool instructions that no
    // longer reflect the current web search armed state.
    return SystemPromptResolver.general()
}

#endif
