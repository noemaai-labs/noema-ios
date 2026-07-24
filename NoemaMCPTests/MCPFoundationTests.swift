#if os(macOS)
import XCTest
@testable import Noema

@MainActor
final class MCPFoundationTests: XCTestCase {
    func testEmptyConfigurationUsesPasteReadyMCPServersObject() {
        XCTAssertEqual(
            MCPConfigurationStore.emptyConfigurationText,
            "{\n  \"mcpServers\": {}\n}"
        )
    }

    func testServersDefaultToAutomaticConnectionLifecycle() throws {
        let source = #"{"mcpServers":{"remote":{"url":"https://example.test/mcp"}}}"#
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let server = try XCTUnwrap(MCPConfigurationStore.decodeServers(from: document).first)
        XCTAssertTrue(server.policy.enabled)
        XCTAssertFalse(server.policy.startOnDemand)
    }

    func testPerToolPermissionsDecodeFromNoemaPolicy() throws {
        let source = #"{"mcpServers":{"remote":{"url":"https://example.test/mcp","_noema":{"allowAllTools":false,"disabledTools":["delete_item"],"alwaysAllowedTools":["read_item"]}}}}"#
        let document = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let server = try XCTUnwrap(MCPConfigurationStore.decodeServers(from: document).first)

        XCTAssertFalse(server.policy.allowAllTools)
        XCTAssertFalse(server.policy.isToolEnabled("delete_item"))
        XCTAssertTrue(server.policy.isToolEnabled("read_item"))
        XCTAssertTrue(server.policy.alwaysAllowsTool("read_item"))
        XCTAssertFalse(server.policy.alwaysAllowsTool("delete_item"))
    }

    func testConfigurationRoundTripPreservesUnknownFields() throws {
        let source = #"{"mcpServers":{"notes":{"url":"https://example.test/mcp","futureField":{"nested":[1,true,"x"]},"_noema":{"trusted":true,"futurePolicy":"keep"}}}}"#
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let servers = try MCPConfigurationStore.decodeServers(from: decoded)
        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers[0].raw["futureField"]?["nested"]?.arrayValue?.count, 3)
        XCTAssertEqual(servers[0].raw["_noema"]?["futurePolicy"]?.stringValue, "keep")
        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: encoded), decoded)
    }

    func testInvalidConfigurationNeverDecodesAsLiveDocument() throws {
        let invalidJSON = Data(#"{"mcpServers":{"broken":{"url":}}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: invalidJSON))

        let missingTransport = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"mcpServers":{"broken":{"unknown":true}}}"#.utf8)
        )
        XCTAssertThrowsError(try MCPConfigurationStore.decodeServers(from: missingTransport))
    }

    func testCommandTokenizerNeverEvaluatesShellSyntax() throws {
        XCTAssertEqual(
            try MCPCommandTokenizer.tokenize(#"npx -y "@modelcontextprotocol/server-filesystem" "/path/to/My Files""#),
            ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/path/to/My Files"]
        )
        XCTAssertThrowsError(try MCPCommandTokenizer.tokenize("npx package && open /tmp"))
        XCTAssertThrowsError(try MCPCommandTokenizer.tokenize("node server.js | tee output"))
    }

    func testEnvironmentReferencesAreDeterministic() throws {
        setenv("NOEMA_MCP_TEST_VALUE", "private-value", 1)
        defer { unsetenv("NOEMA_MCP_TEST_VALUE") }
        XCTAssertEqual(
            try MCPReferenceResolver.resolve("Bearer ${env:NOEMA_MCP_TEST_VALUE}"),
            "Bearer private-value"
        )
        XCTAssertThrowsError(try MCPReferenceResolver.resolve("${env:NOEMA_MCP_TEST_MISSING}"))
    }

    func testAliasesAreStableAndCollisionSafe() {
        let first = MCPAlias.make(serverID: "My Server", toolName: "files/read")
        XCTAssertEqual(first, MCPAlias.make(serverID: "My Server", toolName: "files/read"))
        XCTAssertTrue(first.hasPrefix("mcp_my_server_files_read_"))
        let collided = MCPAlias.make(serverID: "My Server", toolName: "files/read", existing: [first])
        XCTAssertNotEqual(first, collided)
        XCTAssertTrue(collided.hasSuffix("_2"))
    }

    func testJSONSchema202012RoundTripsWithoutReduction() throws {
        let source = #"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":["object","null"],"properties":{"mode":{"oneOf":[{"const":"fast"},{"const":"safe"}]},"count":{"type":"integer","minimum":0}},"unevaluatedProperties":false}"#
        let schema = try JSONDecoder().decode(ToolSpec.JSONSchema.self, from: Data(source.utf8))
        let encoded = try JSONEncoder().encode(schema)
        let roundTrip = try JSONDecoder().decode(ToolSpec.JSONSchema.self, from: encoded)
        XCTAssertEqual(roundTrip.value, schema.value)
        XCTAssertNotNil(roundTrip.value["properties"]?["mode"]?["oneOf"])
    }

    func testOldChatPermissionsDecodeWithNoMCPServersSelected() throws {
        let legacy = Data(#"{"webSearch":true,"python":false,"memory":true,"datasetRetrieval":false}"#.utf8)
        let permissions = try JSONDecoder().decode(ChatVM.ChatToolPermissions.self, from: legacy)
        XCTAssertTrue(permissions.selectedMCPServerIDs.isEmpty)
    }

    func testCatalogBudgetKeepsFullCatalogReachable() {
        let schema = ToolSpec.JSONSchema(type: "object", properties: [:], required: [])
        var tools = (0..<40).map { ToolSpec(name: "mcp_server_tool_\($0)", description: "Tool \($0)", parameters: schema) }
        tools.append(ToolSpec(name: MCPFindTool.toolName, description: "Find", parameters: schema))
        tools.append(ToolSpec(name: MCPCallTool.toolName, description: "Call", parameters: schema))
        let budgeted = MCPToolCatalogBudget.apply(to: tools, usablePromptTokens: 8_000)
        XCTAssertLessThanOrEqual(budgeted.count, 32)
        XCTAssertTrue(budgeted.contains { $0.function.name == MCPFindTool.toolName })
        XCTAssertTrue(budgeted.contains { $0.function.name == MCPCallTool.toolName })
    }
}
#endif
