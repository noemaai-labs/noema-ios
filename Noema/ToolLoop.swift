// ToolLoop.swift
import Foundation

// Protocol for LLM backends that support tool calling
public protocol ToolCapableLLM {
    func generateWithTools(
        messages: [ToolChatMessage],
        tools: [ToolSpec]?,
        temperature: Float
    ) async throws -> ToolChatMessage

    func generateWithPrompt(
        prompt: String,
        stopTokens: [String]?,
        temperature: Float
    ) async throws -> String
}

// Main tool loop for managing conversation flow
public final class ToolLoop {
    private let llm: ToolCapableLLM
    private let registry: ToolRegistry
    private let maxToolTurns: Int
    private let temperature: Float
    
    public init(
        llm: ToolCapableLLM,
        registry: ToolRegistry,
        maxToolTurns: Int = 4,
        temperature: Float = 0.7
    ) {
        self.llm = llm
        self.registry = registry
        self.maxToolTurns = maxToolTurns
        self.temperature = temperature
    }
    
    // MARK: - OpenAI-style Tool Calling (for llama.cpp server mode)
    
    public func runWithOpenAITools(messages: inout [ToolChatMessage]) async throws -> String {
        // Pull tool specs and gate by availability
        let allSpecs: [ToolSpec] = try await MainActor.run { [registry] in
            try registry.generateToolSpecs()
        }
        let availableNames = await ToolManager.shared.availableTools
        let tools: [ToolSpec] = allSpecs.filter { availableNames.contains($0.function.name) }
        let allowedNameSet = Set(availableNames)
        
        // Ensure the system prompt explicitly advertises tool availability to GGUF/llama.cpp.
        // Always inject or augment the system message so local models know they can use tools.
        // Always build from the current active system prompt so we don't carry
        // over stale tool instructions when tools are unarmed/off.
        let hasSystem = messages.contains(where: { $0.role == "system" })
        var sys = activeSystemPrompt(from: nil)
        let hasWebSearch = tools.contains(where: { $0.function.name == "noema.web.retrieve" }) && WebToolGate.isAvailable()
        let hasPython = tools.contains(where: { $0.function.name == "noema.python.execute" }) && PythonToolGate.isAvailable()
        let hasMemory = tools.contains(where: { $0.function.name == "noema.memory" }) && MemoryToolGate.isAvailable()
        let hasCalculator = tools.contains(where: { $0.function.name == "noema.math.calculate" })
        let hasUnitConverter = tools.contains(where: { $0.function.name == "noema.units.convert" })

        if !tools.isEmpty && (hasWebSearch || hasPython || hasMemory || hasCalculator || hasUnitConverter) {
            let alreadyMentionsTools = sys.contains("noema.web.retrieve") || sys.contains("noema.python.execute") || sys.contains("noema.memory") || sys.contains("noema.math.calculate") || sys.contains("noema.units.convert") || sys.contains("<tool_call>") || sys.contains("TOOL_CALL:")
            if !alreadyMentionsTools {
                var toolGuidance = "\n\n## TOOLS (ARMED)\n"

                if hasWebSearch {
                    toolGuidance += "Use the web search tool `noema.web.retrieve` ONLY when the question requires fresh/current information. Otherwise, answer directly without calling tools.\n"
                }
                if hasCalculator {
                    toolGuidance += "Use the calculator tool `noema.math.calculate` for quick deterministic arithmetic or single-expression math. Prefer it over Python for simple calculations.\n"
                }
                if hasUnitConverter {
                    toolGuidance += "Use the unit conversion tool `noema.units.convert` for deterministic conversions between common length, mass, temperature, volume, time, data-size, and speed units.\n"
                }
                if hasPython {
                    toolGuidance += "Use the Python tool `noema.python.execute` when code execution would help answer the question. USE IT FOR: math calculations, numerical analysis, statistical computations, data processing, text manipulation, algorithms, physics/chemistry/engineering problems, plotting/visualization, or any STEM-related task. Always use print() to produce output. Code runs sandboxed: 30s timeout, no network access, no file I/O outside temp. If a question involves numbers, formulas, or computational work, prefer using Python over manual calculation.\n"
                }
                if hasMemory {
                    toolGuidance += "Use the memory tool `noema.memory` for durable, reusable facts that should persist across conversations, such as stable user preferences or recurring project constraints. Do not save transient turn-specific details. Replace any example values with the actual memory title and fact for the current conversation.\n"
                }

                toolGuidance += "\nExact formats you may use (no extra prose when calling):\n"
                if hasWebSearch {
                    toolGuidance += "- JSON: {\"tool_name\": \"noema.web.retrieve\", \"arguments\": {\"query\": \"...\", \"count\": 3, \"safesearch\": \"moderate\"}}\n"
                }
                if hasCalculator {
                    toolGuidance += "- JSON: {\"tool_name\": \"noema.math.calculate\", \"arguments\": {\"expression\": \"sqrt(144) + 3 * 2\"}}\n"
                }
                if hasUnitConverter {
                    toolGuidance += "- JSON: {\"tool_name\": \"noema.units.convert\", \"arguments\": {\"value\": 10, \"from_unit\": \"km\", \"to_unit\": \"mi\"}}\n"
                }
                if hasPython {
                    toolGuidance += "- JSON: {\"tool_name\": \"noema.python.execute\", \"arguments\": {\"code\": \"print(2+2)\"}}\n"
                }
                if hasMemory {
                    toolGuidance += "- JSON: {\"tool_name\": \"noema.memory\", \"arguments\": {\"operation\": \"create\", \"title\": \"<memory title>\", \"content\": \"<durable fact to remember>\"}}\n"
                }
                toolGuidance += "- XML: <tool_call>{\"name\": \"TOOL_NAME\", \"arguments\": {...}}</tool_call>\n"
                toolGuidance += "Rules: Decide first. If needed, make exactly one tool call, wait for results, and you may mention tools inside chain-of-thought (<think>) sections, but finish reasoning and close the tag before emitting the <tool_call> (or JSON tool object) that triggers the call. Do NOT use code fences (```); emit only the JSON or the <tool_call> wrapper. Do not mix formats; choose JSON or XML, not both."
                if hasWebSearch {
                    toolGuidance += " Treat returned web search results as authoritative—cite them like [1], [2]."
                }
                if hasPython {
                    toolGuidance += " Treat returned Python results as authoritative for the computation you executed."
                }
                if hasCalculator {
                    toolGuidance += " Treat returned calculator results as authoritative for the expression you evaluated."
                }
                if hasUnitConverter {
                    toolGuidance += " Treat returned conversion results as authoritative for the requested unit conversion."
                }

                sys += toolGuidance
            }
        }
        if hasSystem {
            if let idx = messages.firstIndex(where: { $0.role == "system" }) {
                messages[idx] = ToolChatMessage.system(sys)
            }
        } else {
            messages.insert(ToolChatMessage.system(sys), at: 0)
        }

        for turn in 0..<maxToolTurns {
            await logger.log("[ToolLoop] Turn \(turn + 1)/\(maxToolTurns)")

            let response = try await llm.generateWithTools(
                messages: messages,
                tools: tools.isEmpty ? nil : tools,
                temperature: temperature
            )
            
            messages.append(response)
            
            // Check if we have tool calls to execute
            if let toolCalls = response.tool_calls, !toolCalls.isEmpty {
                await logger.log("[ToolLoop] Processing \(toolCalls.count) tool call(s)")
                
                for toolCall in toolCalls {
                    do {
                        // Execute on main actor with JSON string to avoid sending non-Sendable across actors
                        let argsJSON = toolCall.function.arguments
                        let result = try await executeToolJSON(name: toolCall.function.name, argumentsJSON: argsJSON)
                        
                        let toolMessage = ToolChatMessage.tool(result: result, callId: toolCall.id)
                        messages.append(toolMessage)
                        
                        await logger.log("[ToolLoop] Tool \(toolCall.function.name) executed successfully")
                    } catch {
                        await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                        let errorResult = "Error: \(error.localizedDescription)"
                        let toolMessage = ToolChatMessage.tool(result: errorResult, callId: toolCall.id)
                        messages.append(toolMessage)
                    }
                }
                continue // Continue the loop for next turn
            }
            
            // Fallback: some backends may emit raw JSON/XML tool calls in the content
            if let raw = response.content?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                if let toolCall = try? parseXMLToolCall(raw), allowedNameSet.contains(toolCall.name) {
                    await logger.log("[ToolLoop] Fallback XML tool call: \(toolCall.name)")
                    do {
                        let dict: [String: Any] = toolCall.arguments.reduce(into: [:]) { acc, pair in
                            acc[pair.key] = pair.value.value
                        }
                        let data = try JSONSerialization.data(withJSONObject: dict)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let callId = UUID().uuidString
                        let call = ToolCall(id: callId, name: toolCall.name, arguments: json)
                        messages[messages.count - 1] = ToolChatMessage.assistant("", toolCalls: [call])
                        let result = try await executeToolJSON(name: toolCall.name, argumentsJSON: json)
                        let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                        messages.append(toolMessage)
                        continue
                    } catch {
                        await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                        let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                        messages.append(ToolChatMessage.assistant(errorMessage))
                        return errorMessage
                    }
                }

                if let toolCall = try? parseSimpleToolCall(raw), allowedNameSet.contains(toolCall.tool_name) {
                    await logger.log("[ToolLoop] Fallback JSON tool call: \(toolCall.tool_name)")
                    do {
                        let dict: [String: Any] = toolCall.arguments.reduce(into: [:]) { acc, pair in
                            acc[pair.key] = pair.value.value
                        }
                        let data = try JSONSerialization.data(withJSONObject: dict)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let callId = UUID().uuidString
                        let call = ToolCall(id: callId, name: toolCall.tool_name, arguments: json)
                        messages[messages.count - 1] = ToolChatMessage.assistant("", toolCalls: [call])
                        let result = try await executeToolJSON(name: toolCall.tool_name, argumentsJSON: json)
                        let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                        messages.append(toolMessage)
                        continue
                    } catch {
                        await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                        let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                        messages.append(ToolChatMessage.assistant(errorMessage))
                        return errorMessage
                    }
                }

                if let (name, args) = try? parseNameArgsToolCall(raw), allowedNameSet.contains(name) {
                    await logger.log("[ToolLoop] Fallback alt JSON tool call: \(name)")
                    do {
                        let dict: [String: Any] = args.reduce(into: [:]) { acc, pair in
                            acc[pair.key] = pair.value.value
                        }
                        let data = try JSONSerialization.data(withJSONObject: dict)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let callId = UUID().uuidString
                        let call = ToolCall(id: callId, name: name, arguments: json)
                        messages[messages.count - 1] = ToolChatMessage.assistant("", toolCalls: [call])
                        let result = try await executeToolJSON(name: name, argumentsJSON: json)
                        let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                        messages.append(toolMessage)
                        continue
                    } catch {
                        await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                        let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                        messages.append(ToolChatMessage.assistant(errorMessage))
                        return errorMessage
                    }
                }
            }

            // No tool calls, return final response
            return response.content ?? ""
        }
        
        throw ToolError.tooManyTurns
    }
    
    // MARK: - JSON Grammar-based Tool Calling (for in-process backends)
    
    public func runWithJSONGrammar(messages: inout [ToolChatMessage]) async throws -> String {
        // Pull tool specs and gate by availability
        let allSpecs: [ToolSpec] = try await MainActor.run { [registry] in
            try registry.generateToolSpecs()
        }
        let availableNames = await ToolManager.shared.availableTools
        let tools: [ToolSpec] = allSpecs.filter { availableNames.contains($0.function.name) }
        let allowedNameSet = Set(availableNames)

        for turn in 0..<maxToolTurns {
            await logger.log("[ToolLoop] JSON Grammar Turn \(turn + 1)/\(maxToolTurns)")

            // Ask backend to build its JSON-focused prompt and generate
            let response = try await llm.generateWithTools(
                messages: messages,
                tools: tools.isEmpty ? nil : tools,
                temperature: temperature
            )

            messages.append(response)

            // Try XML-style first if model emitted tool tags in this mode
            let raw = (response.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.contains("<tool_call>") {
                if let toolCall = try? parseXMLToolCall(raw), allowedNameSet.contains(toolCall.name) {
                    await logger.log("[ToolLoop] Detected XML tool call inside JSON loop: \(toolCall.name)")
                    do {
                        let dict: [String: Any] = toolCall.arguments.reduce(into: [:]) { acc, pair in
                            acc[pair.key] = pair.value.value
                        }
                        let data = try JSONSerialization.data(withJSONObject: dict)
                        let json = String(data: data, encoding: .utf8) ?? "{}"
                        let callId = UUID().uuidString
                        let call = ToolCall(id: callId, name: toolCall.name, arguments: json)
                        messages[messages.count - 1] = ToolChatMessage.assistant("", toolCalls: [call])
                        let result = try await executeToolJSON(name: toolCall.name, argumentsJSON: json)
                        let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                        messages.append(toolMessage)
                        continue
                    } catch {
                        await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                        let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                        messages.append(ToolChatMessage.assistant(errorMessage))
                        return errorMessage
                    }
                }
            }

            // Try to parse as SimpleToolCall (JSON: {"tool_name":"...","arguments":{...}})
            if let toolCall = try? parseSimpleToolCall(raw), allowedNameSet.contains(toolCall.tool_name) {
                await logger.log("[ToolLoop] Detected JSON tool call: \(toolCall.tool_name)")

                do {
                    // Execute on main actor converting arguments back to JSON
                    let dict: [String: Any] = toolCall.arguments.reduce(into: [:]) { acc, pair in
                        acc[pair.key] = pair.value.value
                    }
                    let data = try JSONSerialization.data(withJSONObject: dict)
                    let json = String(data: data, encoding: .utf8) ?? "{}"
                    let callId = UUID().uuidString
                    let call = ToolCall(id: callId, name: toolCall.tool_name, arguments: json)
                    messages[messages.count - 1] = ToolChatMessage.assistant("", toolCalls: [call])
                    let result = try await executeToolJSON(name: toolCall.tool_name, argumentsJSON: json)

                    // Append tool result so the model can continue
                    let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                    messages.append(toolMessage)
                    continue // Next turn
                } catch {
                    await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                    let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                    messages.append(ToolChatMessage.assistant(errorMessage))
                    return errorMessage
                }
            }

            // Fallback: accept {"name":"...","arguments":{...}} shape and normalize like llama.cpp path
            if let (name, args) = try? parseNameArgsToolCall(raw), allowedNameSet.contains(name) {
                await logger.log("[ToolLoop] Detected alternate JSON tool call: \(name)")

                do {
                    let dict: [String: Any] = args.reduce(into: [:]) { acc, pair in
                        acc[pair.key] = pair.value.value
                    }
                    let data = try JSONSerialization.data(withJSONObject: dict)
                    let json = String(data: data, encoding: .utf8) ?? "{}"
                    let callId = UUID().uuidString
                    let call = ToolCall(id: callId, name: name, arguments: json)
                    messages[messages.count - 1] = ToolChatMessage.assistant("", toolCalls: [call])
                    let result = try await executeToolJSON(name: name, argumentsJSON: json)

                    // Append tool result so the model can continue
                    let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                    messages.append(toolMessage)
                    continue // Next turn
                } catch {
                    await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                    let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                    messages.append(ToolChatMessage.assistant(errorMessage))
                    return errorMessage
                }
            }

            // Not a tool call, return final response
            return response.content ?? ""
        }

        throw ToolError.tooManyTurns
    }

    // MARK: - DeepSeek Markers Tool Calling
    public func runWithDeepseekMarkers(messages: inout [ToolChatMessage]) async throws -> String {
        // Available tools and allowed names
        let allSpecs: [ToolSpec] = try await MainActor.run { [registry] in
            try registry.generateToolSpecs()
        }
        let availableNames = await ToolManager.shared.availableTools
        let tools: [ToolSpec] = allSpecs.filter { availableNames.contains($0.function.name) }
        let allowedNameSet = Set(availableNames)

        for turn in 0..<maxToolTurns {
            await logger.log("[ToolLoop] DeepSeek Markers Turn \(turn + 1)/\(maxToolTurns)")

            // Build DeepSeek-style prompt (BOS + system + DS tags for turns and tool outputs)
            let fullPrompt = buildDeepseekStylePrompt(messages: messages, tools: tools)

            // Generate a full response; in-process backends ignore stopTokens so we parse afterwards
            let response = try await llm.generateWithPrompt(
                prompt: fullPrompt,
                stopTokens: ["<｜tool▁calls▁end｜>", "<｜end▁of▁sentence｜>"],
                temperature: temperature
            )

            let raw = response.trimmingCharacters(in: .whitespacesAndNewlines)

            // Parse DeepSeek tool calls if present
            if let calls = try? parseDeepseekToolCalls(raw), !calls.isEmpty {
                await logger.log("[ToolLoop] Detected DeepSeek tool call(s): \(calls.map{ $0.function.name }.joined(separator: ", "))")
                // Execute each tool and append tool result messages
                for call in calls where allowedNameSet.contains(call.function.name) {
                    do {
                        let argsJSON = call.function.arguments
                        let result = try await executeToolJSON(name: call.function.name, argumentsJSON: argsJSON)
                        // Represent as assistant tool_calls then the tool result
                        let assistantMessage = ToolChatMessage.assistant("", toolCalls: [call])
                        let toolMessage = ToolChatMessage.tool(result: result, callId: call.id)
                        messages.append(contentsOf: [assistantMessage, toolMessage])
                    } catch {
                        await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                        let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                        messages.append(ToolChatMessage.assistant(errorMessage))
                        return errorMessage
                    }
                }
                continue // Next turn after injecting tool results
            }

            // No tool call detected; treat as final assistant response
            messages.append(ToolChatMessage.assistant(response))
            return response
        }
        throw ToolError.tooManyTurns
    }

    private func buildDeepseekStylePrompt(messages: [ToolChatMessage], tools: [ToolSpec]) -> String {
        // Canonical DeepSeek tags (fallback defaults)
        let bos = "<｜begin▁of▁sentence｜>"
        let userTag = "<｜User｜>"
        let assistantTag = "<｜Assistant｜>"
        let eosTag = "<｜end▁of▁sentence｜>"

        // Merge active system prompt and optionally list available tools as text
        let existingSystem = messages.first(where: { $0.role == "system" })?.content
        var systemContent = activeSystemPrompt(from: existingSystem)
        if !tools.isEmpty {
            let names = tools.map { $0.function.name }.joined(separator: ", ")
            systemContent += "\n\nAvailable tools: \(names)\nUse tools via DeepSeek tags when needed."
        }

        var p = bos + systemContent
        var insideToolOutputs = false
        var firstOutput = true

        func closeOutputsIfOpen() { if insideToolOutputs { p += "<｜tool▁outputs▁end｜>"; insideToolOutputs = false; firstOutput = true } }

        for m in messages {
            switch m.role.lowercased() {
            case "system":
                // Already merged into systemContent above
                continue
            case "user":
                closeOutputsIfOpen()
                p += userTag + (m.content ?? "") + assistantTag
            case "assistant":
                closeOutputsIfOpen()
                // If historical assistant content exists, end with eos
                if let c = m.content, !c.isEmpty { p += c + eosTag }
                // If assistant carried tool_calls historically, render as DeepSeek calls
                if let tcs = m.tool_calls, !tcs.isEmpty {
                    p += "<｜tool▁calls▁begin｜>"
                    for (i, tc) in tcs.enumerated() {
                        if i == 0 {
                            p += "<｜tool▁call▁begin｜>function<｜tool▁sep｜>\(tc.function.name)\n```json\n\(tc.function.arguments)\n```<｜tool▁call▁end｜>"
                        } else {
                            p += "\n<｜tool▁call▁begin｜>function<｜tool▁sep｜>\(tc.function.name)\n```json\n\(tc.function.arguments)\n```<｜tool▁call▁end｜>"
                        }
                    }
                    p += "<｜tool▁calls▁end｜>" + eosTag
                }
            case "tool":
                let c = m.content ?? ""
                if !insideToolOutputs { p += "<｜tool▁outputs▁begin｜>"; insideToolOutputs = true; firstOutput = true }
                if firstOutput {
                    p += "<｜tool▁output▁begin｜>" + c + "<｜tool▁output▁end｜>"
                    firstOutput = false
                } else {
                    p += "\n<｜tool▁output▁begin｜>" + c + "<｜tool▁output▁end｜>"
                }
            default:
                closeOutputsIfOpen()
                p += (m.content ?? "")
            }
        }

        // Close any open tool outputs block
        if insideToolOutputs { p += "<｜tool▁outputs▁end｜>" }
        return p
    }

    private func parseDeepseekToolCalls(_ response: String) throws -> [ToolCall] {
        var results: [ToolCall] = []
        guard let beginRange = response.range(of: "<｜tool▁calls▁begin｜>") else { return results }
        let tail = response[beginRange.upperBound...]
        // Split segments by call markers
        let parts = tail.components(separatedBy: "<｜tool▁call▁begin｜>")
        for part in parts.dropFirst() { // first segment is before first call
            // type<｜tool▁sep｜>name then newline and ```json
            guard let sepRange = part.range(of: "<｜tool▁sep｜>") else { continue }
            let afterType = part[sepRange.upperBound...]
            // name up to newline
            guard let nameEnd = afterType.firstIndex(of: "\n") else { continue }
            let name = String(afterType[..<nameEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            // capture JSON between ```json and ```
            guard let fenceStart = part.range(of: "```json")?.upperBound,
                  let fenceEnd = part.range(of: "```", range: fenceStart..<part.endIndex)?.lowerBound else { continue }
            let json = String(part[fenceStart..<fenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            let id = UUID().uuidString
            results.append(ToolCall(id: id, name: name, arguments: json))
        }
        return results
    }
    
    public func runWithXMLGrammar(messages: inout [ToolChatMessage]) async throws -> String {
        // Pull tool specs and gate by availability
        let allSpecs: [ToolSpec] = try await MainActor.run { [registry] in
            try registry.generateToolSpecs()
        }
        let availableNames = await ToolManager.shared.availableTools
        let tools: [ToolSpec] = allSpecs.filter { availableNames.contains($0.function.name) }
        
        for turn in 0..<maxToolTurns {
            await logger.log("[ToolLoop] XML Grammar Turn \(turn + 1)/\(maxToolTurns)")
            
            // Build XML-style prompt with ChatML tokens and XML tool tags
            let fullPrompt = buildXMLStylePrompt(messages: messages, tools: tools)
            
            let response = try await llm.generateWithPrompt(
                prompt: fullPrompt,
                stopTokens: ["<|im_end|>", "<|im_start|>user", "</tool_call>"],
                temperature: temperature
            )

            let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to parse as XML tool call first
            if let callRange = trimmedResponse.range(of: "<tool_call>"),
               let toolCall = try? parseXMLToolCall(trimmedResponse) {
                await logger.log("[ToolLoop] Detected XML tool call: \(toolCall.name)")

                do {
                    // Execute on main actor converting to JSON to avoid crossing actor boundaries with non-Sendable
                    let dict: [String: Any] = toolCall.arguments.reduce(into: [:]) { acc, pair in
                        acc[pair.key] = pair.value.value
                    }
                    let data = try JSONSerialization.data(withJSONObject: dict)
                    let json = String(data: data, encoding: .utf8) ?? "{}"
                    let callId = UUID().uuidString
                    let call = ToolCall(id: callId, name: toolCall.name, arguments: json)
                    let preservedText = preservedAssistantContent(from: trimmedResponse, before: callRange.lowerBound)
                    let assistantMessage = ToolChatMessage(
                        role: "assistant",
                        content: preservedText,
                        toolCalls: [call]
                    )
                    let result = try await executeToolJSON(name: toolCall.name, argumentsJSON: json)
                    let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                    messages.append(contentsOf: [assistantMessage, toolMessage])

                    await logger.log("[ToolLoop] Tool \(toolCall.name) executed successfully")
                    continue // Continue the loop for next turn
                } catch {
                    await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                    let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                    messages.append(ToolChatMessage.assistant(errorMessage))
                    return errorMessage
                }
            }

            // Fallback: try to parse as legacy SimpleToolCall format
            if let toolCall = try? parseSimpleToolCall(trimmedResponse) {
                await logger.log("[ToolLoop] Detected legacy tool call: \(toolCall.tool_name)")

                do {
                    let dict: [String: Any] = toolCall.arguments.reduce(into: [:]) { acc, pair in
                        acc[pair.key] = pair.value.value
                    }
                    let data = try JSONSerialization.data(withJSONObject: dict)
                    let json = String(data: data, encoding: .utf8) ?? "{}"
                    let callId = UUID().uuidString
                    let call = ToolCall(id: callId, name: toolCall.tool_name, arguments: json)
                    let preservedText: String? = {
                        if let data = trimmedResponse.data(using: .utf8),
                           (try? JSONDecoder().decode(SimpleToolCall.self, from: data)) != nil {
                            return nil
                        }
                        let jsonStartIndex =
                            trimmedResponse.range(of: "{\"tool_name\"")?.lowerBound ??
                            trimmedResponse.range(of: "{\"name\"")?.lowerBound ??
                            trimmedResponse.firstIndex(of: "{")
                        return preservedAssistantContent(
                            from: trimmedResponse,
                            before: jsonStartIndex
                        )
                    }()
                    let assistantMessage = ToolChatMessage(
                        role: "assistant",
                        content: preservedText,
                        toolCalls: [call]
                    )
                    let result = try await executeToolJSON(name: toolCall.tool_name, argumentsJSON: json)
                    let toolMessage = ToolChatMessage.tool(result: result, callId: callId)
                    messages.append(contentsOf: [assistantMessage, toolMessage])

                    await logger.log("[ToolLoop] Tool \(toolCall.tool_name) executed successfully")
                    continue
                } catch {
                    await logger.log("[ToolLoop] Tool execution failed: \(error.localizedDescription)")
                    let errorMessage = "Tool execution failed: \(error.localizedDescription)"
                    messages.append(ToolChatMessage.assistant(errorMessage))
                    return errorMessage
                }
            }
            
            // Not a tool call, return final response
            messages.append(ToolChatMessage.assistant(response))
            return response
        }
        
        throw ToolError.tooManyTurns
    }
    
    // MARK: - Helper Methods

    private func executeToolJSON(name: String, argumentsJSON: String) async throws -> String {
        if ToolDryRunSupport.isEnabled {
            let arguments: [String: Any]
            if let data = argumentsJSON.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                arguments = object
            } else {
                arguments = [:]
            }
            await logger.log("[ToolLoop] Dry-run recorded \(name)")
            return ToolDryRunSupport.resultString(toolName: name, arguments: arguments)
        }
        return try await registry.executeToolJSON(name: name, argumentsJSON: argumentsJSON)
    }
    
    private func activeSystemPrompt(from existing: String?) -> String {
        // Resolve through centralized resolver to include current tool guidance.
        let resolved = SystemPromptResolver.general()
        if let s = existing, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return s + "\n\n" + resolved
        }
        return resolved
    }

    private func buildXMLStylePrompt(messages: [ToolChatMessage], tools: [ToolSpec]) -> String {
        var prompt = ""
        
        // Build comprehensive system message by merging the active system preset (or provided system message)
        // with the tool catalog and XML tool-call instructions
        let existingSystem = messages.first(where: { $0.role == "system" })?.content
        var systemContent = activeSystemPrompt(from: existingSystem)
        
        if !tools.isEmpty {
            let toolSchemas = generateXMLToolSchemas(tools)
            systemContent += "\n\n<tools>\n\(toolSchemas)\n</tools>\n\n"

            // Always include detailed tool usage instructions
            let detailedInstructions = generateDetailedToolInstructions(tools)
            systemContent += detailedInstructions
        }
        
        prompt += "<|im_start|>system\n\(systemContent)<|im_end|>\n"
        
        // Add conversation history
        for message in messages {
            switch message.role {
            case "system":
                // System messages are already handled above
                break
            case "user":
                prompt += "<|im_start|>user\n\(message.content ?? "")<|im_end|>\n"
            case "assistant":
                var assistantSegments: [String] = []
                if let content = message.content, !content.isEmpty {
                    assistantSegments.append(content)
                }
                if let toolCalls = message.tool_calls, !toolCalls.isEmpty {
                    for call in toolCalls {
                        assistantSegments.append(renderXMLToolCall(call))
                    }
                }
                let assistantBody = assistantSegments.joined(separator: "\n")
                prompt += "<|im_start|>assistant\n\(assistantBody)<|im_end|>\n"
            case "tool":
                // Tool results should be formatted as user messages with tool_response tags
                prompt += "<|im_start|>user\n<tool_response>\n\(message.content ?? "")\n</tool_response><|im_end|>\n"
            default:
                break
            }
        }
        
        prompt += "<|im_start|>assistant\n"
        return prompt
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

    private func renderXMLToolCall(_ call: ToolCall) -> String {
        let trimmedArguments = call.function.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArguments: Any
        if trimmedArguments.isEmpty {
            normalizedArguments = [String: Any]()
        } else if let data = trimmedArguments.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data) {
            normalizedArguments = jsonObject
        } else {
            normalizedArguments = trimmedArguments
        }

        let payload: [String: Any] = [
            "name": call.function.name,
            "arguments": normalizedArguments
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let jsonString = String(data: data, encoding: .utf8) {
            return "<tool_call>\n\(jsonString)\n</tool_call>"
        }

        let escapedName = call.function.name.replacingOccurrences(of: "\"", with: "\\\"")
        let fallbackArguments = trimmedArguments.replacingOccurrences(of: "\"", with: "\\\"")
        return "<tool_call>\n{\"name\":\"\(escapedName)\",\"arguments\":\"\(fallbackArguments)\"}\n</tool_call>"
    }

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
        // Strip code fences if present
        if inner.hasPrefix("```") {
            if let nl = inner.firstIndex(of: "\n") { inner = String(inner[inner.index(after: nl)...]) } else { inner = inner.replacingOccurrences(of: "```", with: "") }
        }
        if inner.hasSuffix("```") { inner.removeLast(3) }
        inner = inner.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ensure complete object
        guard let open = inner.firstIndex(of: "{"), let close = findMatchingBrace(in: inner, startingFrom: open) else {
            throw ToolError.parseError("Incomplete JSON inside <tool_call>")
        }
        let jsonString = String(inner[open...close])

        // Try strict then relaxed (remove trailing commas)
        if let data = jsonString.data(using: .utf8), let call = try? JSONDecoder().decode(XMLToolCall.self, from: data) {
            return call
        }
        let relaxed = removeTrailingCommas(jsonString)
        if let data2 = relaxed.data(using: .utf8), let call2 = try? JSONDecoder().decode(XMLToolCall.self, from: data2) {
            return call2
        }
        throw ToolError.parseError("Could not parse XML tool call JSON: \(jsonString)")
    }

    private func preservedAssistantContent(from response: String, before marker: String.Index?) -> String? {
        guard let marker else { return nil }
        let prefix = response[..<marker]
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    // Lightweight helpers (duplicated to avoid over-exposing file-private ones)
    private func findMatchingBrace(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
        guard startIndex < text.endIndex, text[startIndex] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escape = false
        var i = startIndex
        while i < text.endIndex {
            let c = text[i]
            if escape { escape = false; i = text.index(after: i); continue }
            if c == "\\" && inString { escape = true; i = text.index(after: i); continue }
            if c == "\"" { inString.toggle(); i = text.index(after: i); continue }
            if !inString {
                if c == "{" { depth += 1 }
                else if c == "}" { depth -= 1; if depth == 0 { return i } }
            }
            i = text.index(after: i)
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
        - Use web search for current information, recent events, latest news, or facts that may have changed.
        - Use calculator for quick deterministic arithmetic or single-expression math.
        - Use unit conversion for deterministic common-unit conversions.
        - Use Python for calculations, statistics, parsing, transformations, algorithms, or other computational work.
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
        
        ### AFTER TOOL RESPONSES:
        - The moment a <tool_response> arrives, start a fresh <think> block that analyzes the new information
        - Reference the tool data explicitly before writing your final answer
        - Never skip this follow-up reasoning step

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
                {"name": "noema.python.execute", "arguments": {"code": "numbers = [3, 5, 9]\\nprint(sum(numbers))"}}
                </tool_call>
                
                **Notes:**
                - Always send runnable Python 3 code
                - Use `print()` for values you want returned
                - The runtime is sandboxed: 30s timeout, no network access, no file access outside a temp directory
                
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
        - Treat web search results as authoritative for current-information queries
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
    
    private func parseArgumentsJSON(_ argumentsString: String) throws -> [String: Any] {
        guard let data = argumentsString.data(using: .utf8) else {
            throw ToolError.parseError("Invalid UTF-8 in arguments")
        }
        
        guard let arguments = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.parseError("Arguments must be a JSON object")
        }
        
        return arguments
    }
    
    private func parseSimpleToolCall(_ response: String) throws -> SimpleToolCall {
        // Try to parse JSON from the response
        guard let data = response.data(using: .utf8) else {
            throw ToolError.parseError("Invalid UTF-8 in response")
        }
        
        // First try to decode directly
        if let toolCall = try? JSONDecoder().decode(SimpleToolCall.self, from: data) {
            return toolCall
        }
        
        // If that fails, try to extract JSON from the response
        if let jsonStart = response.firstIndex(of: "{"),
           let jsonEnd = response.lastIndex(of: "}") {
            let jsonString = String(response[jsonStart...jsonEnd])
            if let jsonData = jsonString.data(using: .utf8),
               let toolCall = try? JSONDecoder().decode(SimpleToolCall.self, from: jsonData) {
                return toolCall
            }
        }
        
        throw ToolError.parseError("Could not parse tool call from response: \(response)")
    }

    // Accepts an alternative JSON shape {"name":"…","arguments":{…}} and returns components if present
    private func parseNameArgsToolCall(_ response: String) throws -> (String, [String: AnyCodable]) {
        struct NameArgs: Codable { let name: String; let arguments: [String: AnyCodable] }
        guard let data = response.data(using: .utf8) else {
            throw ToolError.parseError("Invalid UTF-8 in response")
        }
        if let call = try? JSONDecoder().decode(NameArgs.self, from: data) {
            return (call.name, call.arguments)
        }
        if let jsonStart = response.firstIndex(of: "{"),
           let jsonEnd = response.lastIndex(of: "}") {
            let jsonString = String(response[jsonStart...jsonEnd])
            if let jsonData = jsonString.data(using: .utf8),
               let call = try? JSONDecoder().decode(NameArgs.self, from: jsonData) {
                return (call.name, call.arguments)
            }
        }
        throw ToolError.parseError("Could not parse alternate tool call from response: \(response)")
    }
}

// MARK: - JSON Grammar Generation

public struct JSONGrammar {
    public static func toolCallGrammar(toolNames: [String]) -> String {
        let toolNameOptions = toolNames.map { "\"\($0)\"" }.joined(separator: " | ")
        
        return """
        root ::= "{" ws "\"tool_name\"" ws ":" ws tool_name ws "," ws "\"arguments\"" ws ":" ws arguments ws "}"
        tool_name ::= \(toolNameOptions)
        arguments ::= object
        object ::= "{" ws (string ws ":" ws value (ws "," ws string ws ":" ws value)*)? ws "}"
        array ::= "[" ws (value (ws "," ws value)*)? ws "]"
        value ::= object | array | string | number | ("true" | "false" | "null")
        string ::= "\\"" ([^"\\\\] | "\\\\" (["\\\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F]))* "\\""
        number ::= ("-"? ([0-9] | [1-9] [0-9]*)) ("." [0-9]+)? ([eE] [-+]? [0-9]+)?
        ws ::= [ \t\n\r]*
        """
    }
}
