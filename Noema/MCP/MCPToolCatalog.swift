#if os(macOS)
import Foundation

enum MCPToolCatalogBudget {
    static func apply(to tools: [ToolSpec], usablePromptTokens: Int) -> [ToolSpec] {
        let mcp = tools.filter { $0.function.name.hasPrefix("mcp_") }
        guard !mcp.isEmpty else { return tools }
        let encodedBytes = tools.reduce(0) { partial, tool in partial + ((try? JSONEncoder().encode(tool).count) ?? 0) }
        let estimatedTokens = max(1, encodedBytes / 4)
        guard tools.count > 32 || estimatedTokens > max(1, usablePromptTokens / 5) else { return tools }

        let builtIn = tools.filter { !$0.function.name.hasPrefix("mcp_") && $0.function.name != MCPFindTool.toolName && $0.function.name != MCPCallTool.toolName }
        let pinned = Array(mcp.sorted { $0.function.name < $1.function.name }.prefix(max(0, 30 - builtIn.count)))
        let helpers = tools.filter { $0.function.name == MCPFindTool.toolName || $0.function.name == MCPCallTool.toolName }
        return Array((builtIn + pinned + helpers).prefix(32))
    }
}

struct MCPFindTool: Tool {
    static let toolName = "noema.mcp.find"
    let name = toolName
    let description = "Find an available MCP tool by name, server, or purpose when its full schema is not currently advertised."
    let schema = #"{"type":"object","properties":{"query":{"type":"string","description":"What capability or tool to find"}},"required":["query"],"additionalProperties":false}"#

    func call(args: Data) async throws -> Data {
        let value = try JSONDecoder().decode(JSONValue.self, from: args)
        let query = value["query"]?.stringValue?.lowercased() ?? ""
        let matches = await MCPServerManager.shared.activeChatTools(matching: query)
        return try JSONEncoder().encode(JSONValue.array(matches.map { descriptor in
            .object([
                "server": .string(descriptor.serverID), "name": .string(descriptor.originalName),
                "alias": .string(descriptor.alias), "description": .string(descriptor.description)
            ])
        }))
    }
}

struct MCPCallTool: Tool {
    static let toolName = "noema.mcp.call"
    let name = toolName
    let description = "Call an MCP tool returned by noema.mcp.find using its exact alias."
    let schema = #"{"type":"object","properties":{"alias":{"type":"string","description":"Exact API-safe alias returned by noema.mcp.find"},"arguments":{"type":"object","description":"Arguments matching the tool schema","additionalProperties":true}},"required":["alias","arguments"],"additionalProperties":false}"#

    func call(args: Data) async throws -> Data {
        let value = try JSONDecoder().decode(JSONValue.self, from: args)
        guard let alias = value["alias"]?.stringValue, let arguments = value["arguments"] else {
            throw ToolError.invalidArguments("alias and arguments are required")
        }
        guard await MCPServerManager.shared.isToolSelectableForActiveChat(alias: alias) else {
            throw ToolError.executionFailed(String(localized: "This MCP server is not enabled for this chat."))
        }
        let result = try await MCPServerManager.shared.callTool(alias: alias, arguments: arguments, invocationID: UUID().uuidString)
        return try JSONEncoder().encode(result)
    }
}

#endif
