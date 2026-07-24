import Foundation
import XCTest
@testable import Noema

final class AutopilotPhoneAFriendTests: XCTestCase {

    // MARK: - Helpers

    private func selection(_ name: String) -> StartupPreferences.RemoteSelection {
        StartupPreferences.RemoteSelection(
            backendID: UUID(),
            backendName: "Backend-\(name)",
            modelID: "test/\(name)",
            modelName: name
        )
    }

    private func localSelection(context: Int = 8192) -> AutopilotLocalEscalationSelection {
        AutopilotLocalEscalationSelection(
            modelID: "mlx-community/Big-30B",
            name: "Big-30B",
            quant: "4bit",
            format: .mlx,
            urlPath: "/models/mlx/Big-30B",
            contextLength: context
        )
    }

    private func inputs(
        localContext: Int = 8192,
        cloudContext: Int? = 200_000,
        hasImages: Bool = false,
        ragArmed: Bool = false,
        promptTokenEstimate: Int? = 500
    ) -> AutoRouteInputs {
        AutoRouteInputs(
            userMessage: "hello there",
            previousUserMessage: nil,
            conversationTurnCount: 2,
            historyTokenEstimate: 200,
            priorLocalRoutes: 0,
            priorCloudRoutes: 0,
            lastRoute: nil,
            localModel: LocalModelCard(
                name: "TestLocal-4B",
                format: .gguf,
                sizeGB: 4.0,
                quant: "Q4_K_M",
                parameterLabel: "4B",
                contextLength: localContext,
                isToolCapable: true,
                isMultimodal: false,
                moeSummary: nil,
                recentAvgTokPerSec: 32
            ),
            escalationModel: EscalationModelCard(
                name: "Big-30B",
                contextLength: cloudContext,
                promptPricePerMillion: nil,
                completionPricePerMillion: nil,
                isVisionCapable: false
            ),
            hasImages: hasImages,
            imageCount: hasImages ? 1 : 0,
            documentCount: 0,
            ragArmed: ragArmed,
            webSearchArmed: false,
            pythonArmed: false,
            promptTokenEstimate: promptTokenEstimate,
            batteryLevel: 0.8,
            isCharging: false,
            lowPowerMode: false,
            thermalState: .nominal
        )
    }

    private func localEscalationTargets() -> AutopilotResolvedTargets {
        AutopilotResolvedTargets(
            routerBackend: nil, // heuristic path — no network in tests
            routerModel: nil,
            escalationBackend: nil,
            escalationModel: nil,
            localEscalation: localSelection()
        )
    }

    private func localGates(offGrid: Bool = false,
                            offline: Bool = false,
                            killSwitch: Bool = false) -> PolicyGates {
        PolicyGates(
            offGrid: offGrid,
            offline: offline,
            killSwitch: killSwitch,
            enterpriseRemoteAllowed: false, // typical Off-Grid/enterprise shape
            enterpriseAllowsRouterBackend: false,
            enterpriseAllowsEscalationBackend: false,
            escalationIsLocal: true
        )
    }

    // MARK: - Config decode compatibility

    func testLegacyConfigBlobDecodesToRouterSystem() throws {
        let current = AutopilotConfig(
            enabled: true,
            routerSelection: selection("router"),
            escalationSelection: selection("cloud"),
            consentAcceptedAt: Date()
        )
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
        )
        // A blob persisted before the phone-a-friend release has none of the
        // new keys.
        json.removeValue(forKey: "system")
        json.removeValue(forKey: "escalationTarget")
        json.removeValue(forKey: "localEscalation")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: legacyData)
        XCTAssertEqual(decoded.system, .router)
        XCTAssertEqual(decoded.escalationTarget, .remote)
        XCTAssertNil(decoded.localEscalation)
        XCTAssertTrue(decoded.isConfigured)
        XCTAssertTrue(decoded.isReadyToArm)
    }

    func testConfigRoundTripsSystemAndLocalEscalation() throws {
        let config = AutopilotConfig(
            enabled: true,
            system: .phoneAFriend,
            escalationTarget: .localModel,
            localEscalation: localSelection()
        )
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    // MARK: - Readiness semantics

    func testRouterSystemRequiresRouterAndEscalation() {
        var config = AutopilotConfig(system: .router, escalationSelection: selection("cloud"))
        XCTAssertFalse(config.isConfigured, "router system without a router selection is not configured")
        config.routerSelection = selection("router")
        XCTAssertTrue(config.isConfigured)
        XCTAssertTrue(config.requiresCloudConsent)
        XCTAssertFalse(config.isReadyToArm, "cloud consent still missing")
        config.consentAcceptedAt = Date()
        XCTAssertTrue(config.isReadyToArm)
    }

    func testPhoneAFriendSystemNeedsNoRouterSelection() {
        var config = AutopilotConfig(system: .phoneAFriend, escalationSelection: selection("cloud"))
        XCTAssertTrue(config.isConfigured)
        XCTAssertTrue(config.requiresCloudConsent, "remote escalation still sends content to the cloud")
        XCTAssertFalse(config.isReadyToArm)
        config.consentAcceptedAt = Date()
        XCTAssertTrue(config.isReadyToArm)
    }

    func testFullyLocalPhoneAFriendNeedsNoCloudConsent() {
        var config = AutopilotConfig(
            system: .phoneAFriend,
            escalationTarget: .localModel,
            localEscalation: localSelection()
        )
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.requiresCloudConsent)
        XCTAssertTrue(config.isReadyToArm, "no consent needed when nothing leaves the device")
        config.localEscalation = nil
        XCTAssertFalse(config.isConfigured)
        XCTAssertFalse(config.isReadyToArm)
    }

    func testRouterSystemWithLocalEscalationConfigured() {
        let config = AutopilotConfig(
            system: .router,
            routerSelection: selection("router"),
            escalationTarget: .localModel,
            localEscalation: localSelection(),
            consentAcceptedAt: Date()
        )
        XCTAssertTrue(config.isConfigured)
        // The router brain itself is still a cloud call.
        XCTAssertTrue(config.requiresCloudConsent)
        XCTAssertTrue(config.isReadyToArm)
    }

    // MARK: - Router gates with a local escalation target

    func testOffGridDoesNotForceLocalWhenEscalationIsLocal() async {
        let config = AutopilotConfig(
            enabled: true,
            system: .router,
            escalationTarget: .localModel,
            localEscalation: localSelection()
        )
        let result = await AutopilotRouter.shared.decide(
            inputs(),
            config: config,
            targets: localEscalationTargets(),
            gates: localGates(offGrid: true, offline: true, killSwitch: true)
        )
        XCTAssertNotEqual(result.decision.reasonKey, AutopilotReasonKey.offGrid)
        XCTAssertNotEqual(result.decision.reasonKey, AutopilotReasonKey.killSwitch)
        XCTAssertNotEqual(result.decision.reasonKey, AutopilotReasonKey.enterprise)
        XCTAssertNotEqual(result.decision.decidedBy, .forced, "the heuristic should decide, not a network gate")
    }

    func testRagTurnsMayEscalateToLocalTarget() async {
        let config = AutopilotConfig(
            enabled: true,
            system: .router,
            escalationTarget: .localModel,
            localEscalation: localSelection(),
            allowCloudForRAGTurns: false
        )
        let result = await AutopilotRouter.shared.decide(
            inputs(ragArmed: true),
            config: config,
            targets: localEscalationTargets(),
            gates: localGates()
        )
        XCTAssertNotEqual(result.decision.reasonKey, AutopilotReasonKey.ragPrivacy,
                          "knowledge-base privacy gate must not veto an on-device escalation")
    }

    func testMissingLocalEscalationTargetForcesLocal() async {
        let config = AutopilotConfig(
            enabled: true,
            system: .router,
            escalationTarget: .localModel,
            localEscalation: nil
        )
        var targets = localEscalationTargets()
        targets.localEscalation = nil
        let result = await AutopilotRouter.shared.decide(
            inputs(),
            config: config,
            targets: targets,
            gates: localGates()
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.noEscalationTarget)
    }

    func testContextOverflowEscalatesToLocalTargetEvenWhenCloudPaused() async {
        let config = AutopilotConfig(
            enabled: true,
            system: .router,
            escalationTarget: .localModel,
            localEscalation: localSelection(),
            pauseCloudEscalation: true
        )
        let result = await AutopilotRouter.shared.decide(
            inputs(localContext: 4096, cloudContext: 200_000, promptTokenEstimate: 10_000),
            config: config,
            targets: localEscalationTargets(),
            gates: localGates()
        )
        XCTAssertEqual(result.decision.target, .cloud, "overflow must escalate to the stronger local model")
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.contextOverflow)
    }

    func testImagesStayLocalEvenWithLocalEscalation() async {
        let config = AutopilotConfig(
            enabled: true,
            system: .router,
            escalationTarget: .localModel,
            localEscalation: localSelection()
        )
        let result = await AutopilotRouter.shared.decide(
            inputs(hasImages: true),
            config: config,
            targets: localEscalationTargets(),
            gates: localGates()
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.imagesLocalOnly)
    }

    // MARK: - Route records

    func testRouteRecordRoundTripsPhoneAFriendFields() throws {
        let decision = AutoRouteDecision(
            target: .cloud,
            confidence: 1.0,
            reason: "needs the stronger model",
            reasonKey: AutopilotReasonKey.phoneAFriend,
            category: nil,
            estDifficulty: 4,
            latencyMs: 0,
            decidedBy: .phoneAFriend
        )
        let record = RouteDecisionRecord(
            decision: decision,
            escalationModelName: "Big-30B",
            escalationIsLocal: true
        )
        let decoded = try JSONDecoder().decode(RouteDecisionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.decidedBy, .phoneAFriend)
        XCTAssertEqual(decoded.escalationIsLocal, true)
        XCTAssertEqual(decoded.escalationModelName, "Big-30B")
    }

    func testRouteRecordRoundTripsPrivateCloudEscalation() throws {
        let decision = AutoRouteDecision(
            target: .cloud,
            confidence: 0.9,
            reason: "needs the stronger model",
            reasonKey: AutopilotReasonKey.cloudCapable,
            category: nil,
            estDifficulty: 4,
            latencyMs: 12,
            decidedBy: .pcc
        )
        let record = RouteDecisionRecord(
            decision: decision,
            escalationModelName: AppleFoundationModelKind.privateCloudCompute.modelName,
            escalationUsesPrivateCloudCompute: true
        )
        let decoded = try JSONDecoder().decode(RouteDecisionRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded.decidedBy, .pcc)
        XCTAssertEqual(decoded.escalationUsesPrivateCloudCompute, true)
        XCTAssertNil(decoded.escalationIsLocal)
    }

    func testLegacyRouteRecordDecodesWithoutEscalationIsLocal() throws {
        let decision = AutoRouteDecision.forced(.cloud, reasonKey: AutopilotReasonKey.cloudCapable)
        let record = RouteDecisionRecord(decision: decision, escalationModelName: "TestCloud")
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        json.removeValue(forKey: "escalationIsLocal")
        json.removeValue(forKey: "escalationUsesPrivateCloudCompute")
        let decoded = try JSONDecoder().decode(
            RouteDecisionRecord.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertNil(decoded.escalationIsLocal)
        XCTAssertNil(decoded.escalationUsesPrivateCloudCompute)
    }

    // MARK: - Dual-load advisor

    func testLocalEscalationSupportsMLXAndGGUFOnly() {
        XCTAssertTrue(AutopilotLocalEscalationPolicy.supports(.mlx))
        XCTAssertTrue(AutopilotLocalEscalationPolicy.supports(.gguf))
        XCTAssertFalse(AutopilotLocalEscalationPolicy.supports(.et))
        XCTAssertFalse(AutopilotLocalEscalationPolicy.supports(.afm))
    }

    func testGGUFEscalationCanCoexistWithNonGGUFResident() {
        XCTAssertTrue(
            AutopilotLocalEscalationPolicy.canCoexist(
                escalationFormat: .gguf,
                residentFormat: .mlx
            )
        )
        XCTAssertTrue(
            AutopilotLocalEscalationPolicy.canCoexist(
                escalationFormat: .gguf,
                residentFormat: nil
            )
        )
    }

    func testGGUFEscalationRejectsGGUFResident() {
        XCTAssertFalse(
            AutopilotLocalEscalationPolicy.canCoexist(
                escalationFormat: .gguf,
                residentFormat: .gguf
            )
        )
    }

    func testMLXEscalationStillCoexistsWithGGUFResident() {
        XCTAssertTrue(
            AutopilotLocalEscalationPolicy.canCoexist(
                escalationFormat: .mlx,
                residentFormat: .gguf
            )
        )
    }

    private func plan(format: ModelFormat, gb: Double, context: Int) -> AutopilotDualLoadAdvisor.ModelLoadPlan {
        AutopilotDualLoadAdvisor.ModelLoadPlan(
            format: format,
            sizeBytes: Int64(gb * 1_073_741_824.0),
            contextLength: context,
            layerCount: 32,
            moeInfo: nil
        )
    }

    func testDualLoadFitsUnderGenerousBudget() {
        let assessment = AutopilotDualLoadAdvisor.assess(
            resident: plan(format: .gguf, gb: 4, context: 8192),
            escalation: plan(format: .mlx, gb: 16, context: 8192),
            budgetBytesOverride: 64 * 1_073_741_824
        )
        XCTAssertTrue(assessment.fits)
        XCTAssertEqual(assessment.combinedBytes, assessment.residentBytes + assessment.escalationBytes)
        XCTAssertGreaterThan(assessment.escalationBytes, assessment.residentBytes)
    }

    func testDualLoadRejectsUnderTightBudget() {
        let assessment = AutopilotDualLoadAdvisor.assess(
            resident: plan(format: .gguf, gb: 4, context: 8192),
            escalation: plan(format: .mlx, gb: 16, context: 8192),
            budgetBytesOverride: 8 * 1_073_741_824
        )
        XCTAssertFalse(assessment.fits)
    }

    func testDualLoadCountsMLXGPUCacheHeadroom() {
        let withMLX = AutopilotDualLoadAdvisor.assess(
            resident: nil,
            escalation: plan(format: .mlx, gb: 8, context: 4096),
            budgetBytesOverride: 64 * 1_073_741_824
        )
        let withGGUF = AutopilotDualLoadAdvisor.assess(
            resident: nil,
            escalation: plan(format: .gguf, gb: 8, context: 4096),
            budgetBytesOverride: 64 * 1_073_741_824
        )
        // MLX reserves Metal buffer-cache headroom on top of the weights; the
        // exact weight multipliers differ per format, but the MLX estimate must
        // exceed the GGUF one by at least the cache reservation delta direction.
        XCTAssertGreaterThan(withMLX.escalationBytes, withGGUF.escalationBytes)
        XCTAssertEqual(withMLX.residentBytes, 0)
    }

    // MARK: - Tool-call peeking

    func testPeekToolCallTargetParsesHandoff() {
        let token = "TOOL_CALL: {\"name\":\"noema.assist.handoff\",\"arguments\":{\"reason\":\"hard math\"}}"
        let peek = peekToolCallTarget(token)
        XCTAssertEqual(peek?.tool, PhoneAFriendTool.toolName)
        XCTAssertEqual(peek?.arguments["reason"] as? String, "hard math")
    }

    func testPeekToolCallTargetNormalizesAliases() {
        let token = "TOOL_CALL: {\"tool\":\"phone_a_friend\",\"args\":{\"reason\":\"beyond me\"}}"
        XCTAssertEqual(peekToolCallTarget(token)?.tool, PhoneAFriendTool.toolName)
    }

    func testPeekToolCallTargetIgnoresOtherTools() {
        let token = "TOOL_CALL: {\"name\":\"noema.web.retrieve\",\"arguments\":{\"query\":\"news\"}}"
        XCTAssertEqual(peekToolCallTarget(token)?.tool, "noema.web.retrieve")
        XCTAssertNil(peekToolCallTarget("plain text, no tool call"))
    }

    func testPeekEmbeddedToolCallTargetFindsProseForm() {
        let buffer = "Let me get help.\n<tool_call>\n{\"name\":\"noema.assist.handoff\",\"arguments\":{\"reason\":\"complex proof\"}}\n</tool_call>"
        let peek = peekEmbeddedToolCallTarget(in: buffer)
        XCTAssertEqual(peek?.tool, PhoneAFriendTool.toolName)
        XCTAssertEqual(peek?.arguments["reason"] as? String, "complex proof")
    }

    func testPeekEmbeddedToolCallTargetSkipsOpenThinkBlocks() {
        let buffer = "<think>maybe I should call <tool_call>{\"name\":\"noema.assist.handoff\",\"arguments\":{}}</tool_call>"
        XCTAssertNil(peekEmbeddedToolCallTarget(in: buffer), "tool calls inside an open <think> must not trigger")
    }

    func testPeekEmbeddedToolCallTargetIgnoresCallsInsideClosedThinkBlocks() {
        // A closed <think> that merely QUOTES the handoff markup must not
        // trigger a real hand-off.
        let buffer = "<think>For example I could write <tool_call>{\"name\":\"noema.assist.handoff\",\"arguments\":{\"reason\":\"x\"}}</tool_call> but I won't.</think>\nHere is my answer."
        XCTAssertNil(peekEmbeddedToolCallTarget(in: buffer), "quoted markup inside a closed <think> must not trigger")
    }

    func testPeekEmbeddedToolCallTargetParsesQwenXMLForm() {
        let buffer = "</think>\n<function=noema.assist.handoff>\n<parameter=reason>needs deeper reasoning</parameter>\n</function>"
        let peek = peekEmbeddedToolCallTarget(in: buffer)
        XCTAssertEqual(peek?.tool, PhoneAFriendTool.toolName)
        XCTAssertEqual(peek?.arguments["reason"] as? String, "needs deeper reasoning")
    }

    func testPeekEmbeddedToolCallTargetParsesBareJSONForm() {
        let buffer = "Sure.\n{\"name\": \"noema.assist.handoff\", \"arguments\": {\"reason\": \"beyond me\"}}"
        let peek = peekEmbeddedToolCallTarget(in: buffer)
        XCTAssertEqual(peek?.tool, PhoneAFriendTool.toolName)
        XCTAssertEqual(peek?.arguments["reason"] as? String, "beyond me")
    }

    func testPeekBareJSONIgnoresPlainObjectsWithoutToolShape() {
        // A JSON object that isn't a tool call (no arguments key) must not match.
        XCTAssertNil(peekEmbeddedToolCallTarget(in: "Here is data: {\"name\": \"Alice\", \"age\": 30}"))
    }

    // MARK: - Genuine-reason guard

    func testGenuineHandoffReasonRejectsPlaceholders() {
        XCTAssertFalse(PhoneAFriendGate.isGenuineHandoffReason(""))
        XCTAssertFalse(PhoneAFriendGate.isGenuineHandoffReason("   "))
        XCTAssertFalse(PhoneAFriendGate.isGenuineHandoffReason("..."))
        XCTAssertFalse(PhoneAFriendGate.isGenuineHandoffReason("one short sentence on why this needs the stronger model"))
        XCTAssertTrue(PhoneAFriendGate.isGenuineHandoffReason("This requires solving a nonlinear PDE."))
    }

    // MARK: - Spec stripping

    func testStrippingHandoffRemovesOnlyHandoffSpec() throws {
        let handoff = try XCTUnwrap(specFor(PhoneAFriendTool()))
        let web = ToolSpec(
            name: "noema.web.retrieve",
            description: "web",
            parameters: .init(type: "object", properties: [:], required: [])
        )
        let stripped = PhoneAFriendGate.strippingHandoff(from: [handoff, web])
        XCTAssertEqual(stripped.map(\.function.name), ["noema.web.retrieve"])
    }

    private func specFor(_ tool: Tool) -> ToolSpec? {
        ToolSpec(
            name: tool.name,
            description: tool.description,
            parameters: .init(type: "object", properties: [:], required: [])
        )
    }

    func testPhoneAFriendToolFallbackResultTellsModelToAnswerItself() async throws {
        let tool = PhoneAFriendTool()
        let result = try await tool.call(args: Data("{\"reason\":\"x\"}".utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "unavailable")
        XCTAssertNotNil(json["message"])
    }

    // MARK: - Dataset search argument resilience

    func testDatasetSearchMissingQueryReturnsCorrectiveErrorNotDecodeThrow() async throws {
        let tool = DatasetSearchTool()
        // Models sometimes emit `{}`; this must come back as a corrective tool
        // result the model can act on, never a DecodingError.
        let result = try await tool.call(args: Data("{}".utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let message = try XCTUnwrap(json["error"] as? String)
        XCTAssertTrue(message.contains("query"), "the error must name the missing argument")
    }

    func testDatasetSearchEmptyQueryReturnsCorrectiveError() async throws {
        let tool = DatasetSearchTool()
        let result = try await tool.call(args: Data("{\"query\":\"   \"}".utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
        XCTAssertNotNil(json["error"])
    }
}
