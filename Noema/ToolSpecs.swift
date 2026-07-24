import Foundation

// MARK: - Lossless JSON

/// A Sendable, lossless JSON value used for MCP schemas, structured tool output,
/// configuration extensions, and future protocol fields. Unlike `AnyCodable`, this
/// preserves arbitrary nested JSON without reducing JSON Schema to a small subset.
public enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public init(foundationValue value: Any) throws {
        switch value {
        case let value as [String: Any]: self = .object(try value.mapValues(JSONValue.init(foundationValue:)))
        case let value as [Any]: self = .array(try value.map(JSONValue.init(foundationValue:)))
        case let value as String: self = .string(value)
        case let value as Bool: self = .bool(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else if value.doubleValue.rounded() == value.doubleValue { self = .integer(value.int64Value) }
            else { self = .number(value.doubleValue) }
        case _ as NSNull: self = .null
        default: throw ToolError.invalidArguments("Value is not valid JSON")
        }
    }

    public var foundationValue: Any {
        switch self {
        case .object(let value): return value.mapValues(\.foundationValue)
        case .array(let value): return value.map(\.foundationValue)
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        }
    }

    public var sendableValue: any Sendable {
        switch self {
        case .object(let value): return value.mapValues { $0.sendableValue }
        case .array(let value): return value.map { $0.sendableValue }
        case .string(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return JSONValue.null
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}

// MARK: - OpenAI-style Tool Specifications for llama.cpp server mode

public struct ToolSpec: Codable, Sendable {
    public let type = "function"
    public let function: Function

    private enum CodingKeys: String, CodingKey { case type, function }

    public struct Function: Codable, Sendable {
        public let name: String
        public let description: String
        public let parameters: JSONSchema
    }

    /// A complete JSON Schema 2020-12 document. Compatibility projections keep
    /// older prompt renderers working while the encoded representation remains lossless.
    public struct JSONSchema: Codable, Sendable, Hashable {
        public let value: JSONValue

        public init(value: JSONValue) { self.value = value }

        public init(type: String, properties: [String: Parameter], required: [String]) {
            var object: [String: JSONValue] = [
                "type": .string(type),
                "properties": .object(properties.mapValues(\.value))
            ]
            if !required.isEmpty { object["required"] = .array(required.map(JSONValue.string)) }
            self.value = .object(object)
        }

        public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
        public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }

        public var type: String { value["type"]?.stringValue ?? "object" }
        public var required: [String] { value["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
        public var properties: [String: Parameter] {
            (value["properties"]?.objectValue ?? [:]).mapValues(Parameter.init(value:))
        }

        public struct Parameter: Codable, Sendable, Hashable {
            public let value: JSONValue
            public init(value: JSONValue) { self.value = value }

            public init(type: String, description: String, maximum: Int? = nil, minimum: Int? = nil, defaultValue: AnyCodable? = nil, enumValues: [String]? = nil) {
                var object: [String: JSONValue] = ["type": .string(type), "description": .string(description)]
                if let maximum { object["maximum"] = .integer(Int64(maximum)) }
                if let minimum { object["minimum"] = .integer(Int64(minimum)) }
                if let defaultValue, let converted = try? JSONValue(foundationValue: defaultValue.value) { object["default"] = converted }
                if let enumValues { object["enum"] = .array(enumValues.map(JSONValue.string)) }
                value = .object(object)
            }

            public init(from decoder: Decoder) throws { value = try JSONValue(from: decoder) }
            public func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
            public var type: String { value["type"]?.stringValue ?? "any" }
            public var description: String { value["description"]?.stringValue ?? "" }
            public var maximum: Int? { value["maximum"]?.integerValue.map(Int.init) }
            public var minimum: Int? { value["minimum"]?.integerValue.map(Int.init) }
            public var `enum`: [String]? { value["enum"]?.arrayValue?.compactMap(\.stringValue) }
        }
    }

    public init(name: String, description: String, parameters: JSONSchema) {
        function = Function(name: name, description: description, parameters: parameters)
    }

    public func asToolDictionary() -> [String: any Sendable] {
        [
            "type": type,
            "function": [
                "name": function.name,
                "description": function.description,
                "parameters": function.parameters.value.sendableValue
            ] as [String: any Sendable]
        ]
    }
}

extension JSONValue {
    var prettyPrinted: String {
        guard JSONSerialization.isValidJSONObject(foundationValue),
              let data = try? JSONSerialization.data(withJSONObject: foundationValue, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: foundationValue) }
        return text
    }

    var integerValue: Int64? {
        switch self {
        case .integer(let value): value
        case .number(let value) where value.rounded() == value: Int64(value)
        default: nil
        }
    }
}

// MARK: - Tool Call Request/Response Structures

public struct ToolChatMessage: Codable {
    public let role: String
    public let content: String?
    public let tool_calls: [ToolCall]?
    public let tool_call_id: String?

    public init(role: String, content: String? = nil, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role; self.content = content; tool_calls = toolCalls; tool_call_id = toolCallId
    }
    public static func system(_ content: String) -> ToolChatMessage { .init(role: "system", content: content) }
    public static func user(_ content: String) -> ToolChatMessage { .init(role: "user", content: content) }
    public static func assistant(_ content: String, toolCalls: [ToolCall]? = nil) -> ToolChatMessage { .init(role: "assistant", content: content, toolCalls: toolCalls) }
    public static func tool(result: String, callId: String) -> ToolChatMessage { .init(role: "tool", content: result, toolCallId: callId) }
}

public struct ToolCall: Codable, Sendable {
    public let id: String
    public let type = "function"
    public let function: ToolFunction
    private enum CodingKeys: String, CodingKey { case id, type, function }

    public struct ToolFunction: Codable, Sendable { public let name: String; public let arguments: String }
    public init(id: String, name: String, arguments: String) { self.id = id; function = .init(name: name, arguments: arguments) }
}

public struct ChatRequest: Codable {
    public let model: String; public let messages: [ToolChatMessage]; public let tools: [ToolSpec]?
    public let tool_choice: String?; public let stream: Bool; public let max_tokens: Int?; public let temperature: Float?
    public init(model: String, messages: [ToolChatMessage], tools: [ToolSpec]? = nil, toolChoice: String? = "auto", stream: Bool = true, maxTokens: Int? = nil, temperature: Float? = nil) {
        self.model = model; self.messages = messages; self.tools = tools; tool_choice = toolChoice
        self.stream = stream; max_tokens = maxTokens; self.temperature = temperature
    }
}

public struct ChatResponse: Codable {
    public let choices: [Choice]
    public struct Choice: Codable { public let message: ToolChatMessage; public let finish_reason: String? }
}

public struct SimpleToolCall: Codable {
    public let tool_name: String; public let arguments: [String: AnyCodable]
    public init(toolName: String, arguments: [String: AnyCodable]) { tool_name = toolName; self.arguments = arguments }
}

public enum ToolError: Error {
    case unknownTool(String); case invalidArguments(String); case executionFailed(String); case tooManyTurns; case parseError(String)
}
