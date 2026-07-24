import Foundation

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var schema: String { get } // JSON Schema string (for tool-calling models)
    func call(args: Data) async throws -> Data // JSON in → JSON out
}

/// Alias for files that also import FoundationModels, whose own `Tool`
/// protocol shadows the bare name.
public typealias LoopbackTool = Tool

enum ToolDryRunSupport {
    static let defaultsKey = "toolDryRunEnabled"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }

    static func resultString(toolName: String, arguments: [String: Any]) -> String {
        let payload: [String: Any] = [
            "dry_run": true,
            "tool": toolName,
            "arguments": arguments,
            "message": "Dry-run mode is on. The tool call was recorded but not executed."
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return #"{"dry_run":true,"message":"Dry-run mode is on. The tool call was recorded but not executed."}"#
        }
        return string
    }
}

// Enhanced tool registry with catalog generation and validation
@MainActor
public final class ToolRegistry {
    public static let shared = ToolRegistry()
    private struct Entry {
        let tool: Tool
        let source: String
    }
    private var entries: [String: Entry] = [:]
    private static let builtInSource = "noema.builtin"
    
    public func register(_ tool: Tool) {
        register(tool, source: Self.builtInSource)
    }

    /// Atomically installs a complete source-owned catalog. This is used by MCP
    /// connections so a list-change notification can never leave a half-old catalog.
    public func replaceTools(from source: String, with tools: [Tool]) {
        entries = entries.filter { $0.value.source != source }
        for tool in tools { entries[tool.name] = Entry(tool: tool, source: source) }
        Task { await logger.log("[ToolRegistry] Replaced source \(source) with \(tools.count) tools") }
    }

    public func unregisterTools(from source: String) {
        entries = entries.filter { $0.value.source != source }
        Task { await logger.log("[ToolRegistry] Unregistered tool source: \(source)") }
    }

    public func register(_ tool: Tool, source: String) {
        entries[tool.name] = Entry(tool: tool, source: source)
        Task {
            await logger.log("[ToolRegistry] Registered tool: \(tool.name)")
        }
    }
    
    public func tool(named name: String) -> Tool? {
        entries[name]?.tool
    }

    public func source(forToolNamed name: String) -> String? { entries[name]?.source }
    
    public var registeredToolNames: [String] {
        Array(entries.keys).sorted()
    }
    
    // MARK: - OpenAI-style Tool Specs Generation
    
    public func generateToolSpecs() throws -> [ToolSpec] {
        // Name-sorted, never dictionary-enumeration order: the spec array's order
        // reaches the rendered prompt verbatim (llama.cpp parses request JSON as
        // ordered_json), and catalog rebuilds (MCP replaceTools, cache
        // invalidation) would otherwise reshuffle it — breaking the prompt's
        // stable prefix and with it slot-KV reuse across turns and launches.
        try entries.values
            .sorted { $0.tool.name < $1.tool.name }
            .map { entry in
                let schemaData = Data(entry.tool.schema.utf8)
                let schema = try JSONDecoder().decode(ToolSpec.JSONSchema.self, from: schemaData)
                return ToolSpec(name: entry.tool.name, description: entry.tool.description, parameters: schema)
            }
    }
    
    // MARK: - Tool Catalog for Prompting
    
    public func generateToolCatalog() -> String {
        // Same determinism contract as generateToolSpecs: prose catalogs land in
        // the system prompt, which is the prompt's leading KV segment.
        let toolDescriptions = entries.values.sorted { $0.tool.name < $1.tool.name }.map { entry in
            let tool = entry.tool
            return """
            Tool: \(tool.name)
            Description: \(tool.description)
            Schema: \(tool.schema)
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
    
    // MARK: - Tool Execution with Validation
    
    public func executetool(name: String, arguments: [String: Any]) async throws -> String {
        guard let tool = entries[name]?.tool else {
            throw ToolError.unknownTool(name)
        }
        
        // Global guardrails: clamp web search count to max 5 regardless of model request
        var sanitizedArguments = arguments
        if name == "noema.web.retrieve" {
            if let rawCount = sanitizedArguments["count"] as? Int {
                sanitizedArguments["count"] = max(1, min(rawCount, 5))
            } else if let rawCountString = sanitizedArguments["count"] as? String, let parsed = Int(rawCountString) {
                sanitizedArguments["count"] = max(1, min(parsed, 5))
            }
        }

        try validateArguments(sanitizedArguments, against: tool.schema, for: name)
        
        let argsData = try JSONSerialization.data(withJSONObject: sanitizedArguments)
        let resultData = try await tool.call(args: argsData)
        
        guard let resultString = String(data: resultData, encoding: .utf8) else {
            throw ToolError.executionFailed("Failed to encode result for tool \(name)")
        }
        
        return resultString
    }

    // Convenience method to avoid sending non-Sendable dictionaries across actors
    public func executeToolJSON(name: String, argumentsJSON: String) async throws -> String {
        guard let data = argumentsJSON.data(using: .utf8) else {
            throw ToolError.parseError("Invalid UTF-8 in arguments")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.parseError("Arguments must be a JSON object")
        }
        return try await executetool(name: name, arguments: obj)
    }
    
    private func validateArguments(_ arguments: [String: Any], against schemaString: String, for toolName: String) throws {
        let schemaData = Data(schemaString.utf8)
        guard let schemaObject = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any] else {
            throw ToolError.invalidArguments("Invalid schema format for tool \(toolName)")
        }
        let properties = schemaObject["properties"] as? [String: Any] ?? [:]
        let required = schemaObject["required"] as? [String] ?? []
        
        // Check required parameters
        for requiredParam in required {
            guard arguments[requiredParam] != nil else {
                throw ToolError.invalidArguments("Missing required parameter '\(requiredParam)' for tool \(toolName)")
            }
        }
        
        // Validate parameter types (basic validation)
        for (paramName, paramValue) in arguments {
            guard let paramSchema = properties[paramName] as? [String: Any] else {
                if schemaObject["additionalProperties"] as? Bool == false {
                    throw ToolError.invalidArguments("Parameter '\(paramName)' is not allowed for tool \(toolName)")
                }
                continue
            }
            let expectedTypes: [String]
            if let expected = paramSchema["type"] as? String { expectedTypes = [expected] }
            else if let expected = paramSchema["type"] as? [String] { expectedTypes = expected }
            else { expectedTypes = [] }
            
            func matches(_ expectedType: String) -> Bool {
                switch expectedType {
            case "string":
                    return paramValue is String
            case "integer":
                    if let number = paramValue as? NSNumber { return number.doubleValue.rounded() == number.doubleValue }
                    return paramValue is Int
            case "number":
                    return paramValue is NSNumber
            case "boolean":
                    return paramValue is Bool
            case "array":
                    return paramValue is [Any]
            case "object":
                    return paramValue is [String: Any]
            case "null":
                    return paramValue is NSNull
            default:
                    return true // Future JSON Schema types remain forward-compatible.
                }
            }
            
            if !expectedTypes.isEmpty, !expectedTypes.contains(where: matches) {
                throw ToolError.invalidArguments("Parameter '\(paramName)' has the wrong type for tool \(toolName)")
            }
            if let allowed = paramSchema["enum"] as? [Any],
               !allowed.contains(where: { String(describing: $0) == String(describing: paramValue) }) {
                throw ToolError.invalidArguments("Parameter '\(paramName)' is not one of the allowed values for tool \(toolName)")
            }
        }
    }
}
