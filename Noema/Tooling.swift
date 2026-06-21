// Tooling.swift
import Foundation

public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var schema: String { get } // JSON Schema string (for tool-calling models)
    func call(args: Data) async throws -> Data // JSON in → JSON out
}

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
    private var tools: [String: Tool] = [:]
    
    public func register(_ tool: Tool) {
        tools[tool.name] = tool
        Task {
            await logger.log("[ToolRegistry] Registered tool: \(tool.name)")
        }
    }
    
    public func tool(named name: String) -> Tool? {
        return tools[name]
    }
    
    public var registeredToolNames: [String] {
        return Array(tools.keys).sorted()
    }
    
    // MARK: - OpenAI-style Tool Specs Generation
    
    public func generateToolSpecs() throws -> [ToolSpec] {
        return try tools.values.map { tool in
            let schemaData = Data(tool.schema.utf8)
            let jsonObject = try JSONSerialization.jsonObject(with: schemaData)
            
            guard let schemaDict = jsonObject as? [String: Any],
                  let type = schemaDict["type"] as? String,
                  type == "object",
                  let properties = schemaDict["properties"] as? [String: Any] else {
                throw ToolError.invalidArguments("Invalid schema for tool \(tool.name)")
            }
            
            let required = schemaDict["required"] as? [String] ?? []
            
            let parameters = try properties.mapValues { propValue -> ToolSpec.JSONSchema.Parameter in
                guard let propDict = propValue as? [String: Any],
                      let propType = propDict["type"] as? String,
                      let description = propDict["description"] as? String else {
                    throw ToolError.invalidArguments("Invalid property in schema for tool \(tool.name)")
                }
                
                let maximum = propDict["maximum"] as? Int
                let minimum = propDict["minimum"] as? Int
                let defaultValue = propDict["default"].map { AnyCodable($0) }
                let enumValues = propDict["enum"] as? [String]
                
                return ToolSpec.JSONSchema.Parameter(
                    type: propType,
                    description: description,
                    maximum: maximum,
                    minimum: minimum,
                    defaultValue: defaultValue,
                    enumValues: enumValues
                )
            }
            
            let jsonSchema = ToolSpec.JSONSchema(
                type: "object",
                properties: parameters,
                required: required
            )
            
            return ToolSpec(name: tool.name, description: tool.description, parameters: jsonSchema)
        }
    }
    
    // MARK: - Tool Catalog for Prompting
    
    public func generateToolCatalog() -> String {
        let toolDescriptions = tools.values.map { tool in
            """
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
        guard let tool = tools[name] else {
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

        // Validate arguments against schema
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
        guard let schemaObject = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any],
              let properties = schemaObject["properties"] as? [String: Any],
              let required = schemaObject["required"] as? [String] else {
            throw ToolError.invalidArguments("Invalid schema format for tool \(toolName)")
        }
        
        // Check required parameters
        for requiredParam in required {
            guard arguments[requiredParam] != nil else {
                throw ToolError.invalidArguments("Missing required parameter '\(requiredParam)' for tool \(toolName)")
            }
        }
        
        // Validate parameter types (basic validation)
        for (paramName, paramValue) in arguments {
            guard let paramSchema = properties[paramName] as? [String: Any],
                  let expectedType = paramSchema["type"] as? String else {
                continue
            }
            
            let isValidType: Bool
            switch expectedType {
            case "string":
                isValidType = paramValue is String
            case "integer":
                isValidType = paramValue is Int
            case "number":
                isValidType = paramValue is NSNumber
            case "boolean":
                isValidType = paramValue is Bool
            case "array":
                isValidType = paramValue is [Any]
            case "object":
                isValidType = paramValue is [String: Any]
            default:
                isValidType = true // Unknown type, skip validation
            }
            
            if !isValidType {
                throw ToolError.invalidArguments("Parameter '\(paramName)' should be of type \(expectedType) for tool \(toolName)")
            }
        }
    }
}

