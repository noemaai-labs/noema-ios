import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// Converts the tools' flat JSON Schema strings into `GenerationSchema`s.
/// Supports the subset the registered tools use: objects with typed properties,
/// string enums, string/integer/number/boolean scalars, and arrays with typed
/// items (nested objects recurse). Returns nil for anything it cannot express —
/// callers must skip the tool rather than advertise a broken schema.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
enum AFMJSONSchemaConverter {
    static func generationSchema(name: String, jsonSchema: String) -> GenerationSchema? {
        guard let data = jsonSchema.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let root = dynamicSchema(name: name, node: object) else { return nil }
        return try? GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(name: String, node: [String: Any]) -> DynamicGenerationSchema? {
        if let choices = node["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(
                name: name,
                description: node["description"] as? String,
                anyOf: choices
            )
        }
        switch node["type"] as? String {
        case "object":
            let propertyNodes = node["properties"] as? [String: Any] ?? [:]
            let required = Set(node["required"] as? [String] ??  [])
            var properties: [DynamicGenerationSchema.Property] = []
            for key in propertyNodes.keys.sorted() {
                guard let subNode = propertyNodes[key] as? [String: Any],
                      let subSchema = dynamicSchema(name: "\(name).\(key)", node: subNode) else { return nil }
                properties.append(DynamicGenerationSchema.Property(
                    name: key,
                    description: subNode["description"] as? String,
                    schema: subSchema,
                    isOptional: !required.contains(key)
                ))
            }
            return DynamicGenerationSchema(
                name: name,
                description: node["description"] as? String,
                properties: properties
            )
        case "array":
            // Untyped arrays (no "items") degrade to arrays of strings.
            let itemNode = node["items"] as? [String: Any] ?? ["type": "string"]
            guard let item = dynamicSchema(name: "\(name).item", node: itemNode) else { return nil }
            return DynamicGenerationSchema(arrayOf: item)
        case "string", nil:
            return DynamicGenerationSchema(type: String.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        default:
            return nil
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
struct AFMLoopbackToolAdapter: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    private let wrapped: any LoopbackTool
    private let recorder: AFMToolRecorder?

    /// Returns nil when the tool's JSON schema cannot be expressed as a
    /// `GenerationSchema`; the caller skips the tool rather than crash or
    /// advertise a schema the model cannot fill.
    init?(wrapping tool: any LoopbackTool, recorder: AFMToolRecorder?) {
        guard let schema = AFMJSONSchemaConverter.generationSchema(
            name: tool.name,
            jsonSchema: tool.schema
        ) else { return nil }
        self.name = tool.name
        self.description = tool.description
        self.parameters = schema
        self.wrapped = tool
        self.recorder = recorder
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let argsJSON = arguments.jsonString
        let callID = UUID().uuidString
        let startedAt = Date()
        let requestParams = Self.requestParams(fromJSON: argsJSON)
        await recorder?.record(
            AFMToolCallSummary(
                id: callID,
                toolName: name,
                requestParams: requestParams,
                phase: .executing,
                result: nil,
                error: nil,
                timestamp: startedAt
            )
        )

        let payload: String
        do {
            let payloadData = try await wrapped.call(args: Data(argsJSON.utf8))
            payload = String(data: payloadData, encoding: .utf8)
                ?? #"{"error":"Tool returned unreadable output."}"#
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            payload = #"{"error":"\#(message.replacingOccurrences(of: "\"", with: "'"))"}"#
        }
        let error = AFMWebSearchExecution.errorMessage(from: payload)
        await recorder?.record(
            AFMToolCallSummary(
                id: callID,
                toolName: name,
                requestParams: requestParams,
                phase: error == nil ? .completed : .failed,
                result: payload,
                error: error,
                timestamp: startedAt,
                completedAt: Date()
            )
        )
        // The full payload (including any rendered chart image base64) is
        // recorded for the UI; the model sees the stripped version so images
        // never bloat the context window — same split as ToolMiddleware.
        return stripHeavyBase64ForModel(payload)
    }

    private static func requestParams(fromJSON json: String) -> [String: AnyCodable] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var params: [String: AnyCodable] = [:]
        for (key, value) in object where !(value is NSNull) {
            params[key] = AnyCodable(value)
        }
        return params
    }
}
#endif
