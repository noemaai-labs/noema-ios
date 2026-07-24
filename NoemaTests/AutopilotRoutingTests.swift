import Foundation
import XCTest
@testable import Noema

final class AutopilotRoutingTests: XCTestCase {

    private func routingOutcome(
        target: AutoRouteTarget,
        reasonKey: String
    ) -> AutoRoutingOutcome {
        AutoRoutingOutcome(
            decision: AutoRouteDecision(
                target: target,
                confidence: 1,
                reason: AutopilotReasonKey.localized(reasonKey),
                reasonKey: reasonKey,
                category: .other,
                estDifficulty: 1,
                latencyMs: 0,
                decidedBy: .heuristic
            ),
            escalation: nil,
            escalationBackendName: nil,
            escalationModelName: nil,
            routerPromptTokens: nil,
            routerCompletionTokens: nil
        )
    }

    private func inputs(
        userMessage: String = "hello there",
        previousUserMessage: String? = nil,
        conversationTurnCount: Int = 2,
        historyTokenEstimate: Int = 200,
        priorLocalRoutes: Int = 0,
        priorCloudRoutes: Int = 0,
        lastRoute: AutoRouteTarget? = nil,
        localSizeGB: Double = 4.0,
        localContext: Int = 8192,
        cloudContext: Int? = 200_000,
        escalationVision: Bool = false,
        hasImages: Bool = false,
        ragArmed: Bool = false,
        promptTokenEstimate: Int? = 500,
        batteryLevel: Float = 0.8,
        isCharging: Bool = false,
        lowPowerMode: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal
    ) -> AutoRouteInputs {
        AutoRouteInputs(
            userMessage: userMessage,
            previousUserMessage: previousUserMessage,
            conversationTurnCount: conversationTurnCount,
            historyTokenEstimate: historyTokenEstimate,
            priorLocalRoutes: priorLocalRoutes,
            priorCloudRoutes: priorCloudRoutes,
            lastRoute: lastRoute,
            localModel: LocalModelCard(
                name: "TestLocal-4B",
                format: .gguf,
                sizeGB: localSizeGB,
                quant: "Q4_K_M",
                parameterLabel: "4B",
                contextLength: localContext,
                isToolCapable: true,
                isMultimodal: false,
                moeSummary: nil,
                recentAvgTokPerSec: 32
            ),
            escalationModel: EscalationModelCard(
                name: "TestCloud",
                contextLength: cloudContext,
                promptPricePerMillion: 1.0,
                completionPricePerMillion: 3.0,
                isVisionCapable: escalationVision
            ),
            hasImages: hasImages,
            imageCount: hasImages ? 1 : 0,
            documentCount: 0,
            ragArmed: ragArmed,
            webSearchArmed: false,
            pythonArmed: false,
            promptTokenEstimate: promptTokenEstimate,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            lowPowerMode: lowPowerMode,
            thermalState: thermal
        )
    }

    private func openGates() -> PolicyGates {
        PolicyGates(
            offGrid: false,
            killSwitch: false,
            enterpriseRemoteAllowed: true,
            enterpriseAllowsRouterBackend: true,
            enterpriseAllowsEscalationBackend: true
        )
    }

    private func makeBackend(name: String = "Test OpenRouter",
                             baseURLString: String = "https://openrouter.ai",
                             endpointType: RemoteBackend.EndpointType = .openRouter) -> RemoteBackend {
        RemoteBackend(
            name: name,
            baseURLString: baseURLString,
            chatPath: endpointType.defaultChatPath,
            modelsPath: endpointType.defaultModelsPath,
            endpointType: endpointType
        )
    }

    private func configuredTargets() -> AutopilotResolvedTargets {
        let backend = makeBackend()
        let model = RemoteModel(id: "test/cloud-model", name: "TestCloud", author: "test")
        return AutopilotResolvedTargets(
            routerBackend: nil,   // no router → heuristic path, no network in tests
            routerModel: nil,
            escalationBackend: backend,
            escalationModel: model
        )
    }

    private func config(aggressiveness: RouterAggressiveness = .balanced,
                        allowRAG: Bool = false,
                        paused: Bool = false) -> AutopilotConfig {
        AutopilotConfig(
            enabled: true,
            routerSelection: nil,
            escalationSelection: nil,
            aggressiveness: aggressiveness,
            allowCloudForRAGTurns: allowRAG,
            pauseCloudEscalation: paused,
            consentAcceptedAt: Date()
        )
    }

    // MARK: - Hard gates (ordering: off-grid beats everything)

    func testOffGridForcesLocalEvenForHardQueries() async {
        var gates = openGates()
        gates.offGrid = true
        let result = await AutopilotRouter().decide(
            inputs(userMessage: "Prove the theorem by induction and derive the integral ```code```"),
            config: config(aggressiveness: .frontier),
            targets: configuredTargets(),
            gates: gates
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.decidedBy, .forced)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.offGrid)
    }

    func testOfflineForcesLocalWithOfflineReceipt() async {
        var gates = openGates()
        gates.offline = true
        let result = await AutopilotRouter().decide(
            inputs(userMessage: "Prove the theorem by induction ```code```"),
            config: config(aggressiveness: .frontier),
            targets: configuredTargets(),
            gates: gates
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.decidedBy, .forced)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.offGrid)
    }

    func testKillSwitchForcesLocal() async {
        var gates = openGates()
        gates.killSwitch = true
        let result = await AutopilotRouter().decide(
            inputs(), config: config(), targets: configuredTargets(), gates: gates
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.killSwitch)
    }

    func testEnterpriseBlockForcesLocal() async {
        var gates = openGates()
        gates.enterpriseRemoteAllowed = false
        let result = await AutopilotRouter().decide(
            inputs(), config: config(), targets: configuredTargets(), gates: gates
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.enterprise)
    }

    func testMissingEscalationTargetForcesLocal() async {
        let result = await AutopilotRouter().decide(
            inputs(), config: config(),
            targets: AutopilotResolvedTargets(routerBackend: nil, routerModel: nil,
                                              escalationBackend: nil, escalationModel: nil),
            gates: openGates()
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.noEscalationTarget)
    }

    func testImagesForceLocal() async {
        let result = await AutopilotRouter().decide(
            inputs(hasImages: true), config: config(), targets: configuredTargets(), gates: openGates()
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.imagesLocalOnly)
    }

    func testImagesReachRouterWhenEscalationModelHasVision() async {
        // A vision-capable escalation target lifts the hard gate; the verdict
        // falls to the heuristic here (no router configured in tests).
        let result = await AutopilotRouter().decide(
            inputs(escalationVision: true, hasImages: true),
            config: config(), targets: configuredTargets(), gates: openGates()
        )
        XCTAssertNotEqual(result.decision.reasonKey, AutopilotReasonKey.imagesLocalOnly)
        XCTAssertEqual(result.decision.decidedBy, .heuristic)
    }

    func testRAGForcesLocalByDefaultAndAllowsWhenOptedIn() async {
        let blocked = await AutopilotRouter().decide(
            inputs(ragArmed: true), config: config(), targets: configuredTargets(), gates: openGates()
        )
        XCTAssertEqual(blocked.decision.target, .local)
        XCTAssertEqual(blocked.decision.reasonKey, AutopilotReasonKey.ragPrivacy)

        let allowed = await AutopilotRouter().decide(
            inputs(ragArmed: true), config: config(allowRAG: true), targets: configuredTargets(), gates: openGates()
        )
        XCTAssertNotEqual(allowed.decision.reasonKey, AutopilotReasonKey.ragPrivacy)
    }

    func testContextOverflowForcesCloudWhenCloudFits() async {
        let result = await AutopilotRouter().decide(
            inputs(localContext: 4096, promptTokenEstimate: 5000),
            config: config(), targets: configuredTargets(), gates: openGates()
        )
        XCTAssertEqual(result.decision.target, .cloud)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.contextOverflow)
    }

    func testContextOverflowStaysLocalWhenCloudDoesNotFit() async {
        let result = await AutopilotRouter().decide(
            inputs(localContext: 4096, cloudContext: 4096, promptTokenEstimate: 5000),
            config: config(), targets: configuredTargets(), gates: openGates()
        )
        XCTAssertEqual(result.decision.target, .local)
    }

    func testPauseCloudEscalationConvertsCloudVerdictsToLocal() async {
        let result = await AutopilotRouter().decide(
            inputs(userMessage: "Prove by induction the theorem, derive ```code``` " + String(repeating: "constraint ", count: 200)),
            config: config(aggressiveness: .frontier, paused: true),
            targets: configuredTargets(), gates: openGates()
        )
        XCTAssertEqual(result.decision.target, .local)
        XCTAssertEqual(result.decision.reasonKey, AutopilotReasonKey.escalationPaused)
    }

    // MARK: - Heuristic thresholds per aggressiveness

    func testHeuristicDefaultsLocalOnSimpleChat() {
        let d = AutopilotHeuristic.decide(inputs(userMessage: "hey, how's it going?"), aggressiveness: .balanced)
        XCTAssertEqual(d.target, .local)
        XCTAssertEqual(d.decidedBy, .heuristic)
        XCTAssertNotNil(d.reasonKey)
    }

    func testHeuristicEscalatesHeavyCodePlusMathOnBalanced() {
        let msg = "Please implement and debug this program, then prove the complexity bound.\n```swift\nfunc f() {}\n```"
        let d = AutopilotHeuristic.decide(inputs(userMessage: msg), aggressiveness: .balanced)
        XCTAssertEqual(d.target, .cloud)
    }

    func testConserveIsStricterThanFrontier() {
        // Score 4: heavy code (+3) + 3B-class model (+1).
        let msg = "Please refactor this module.\n```swift\nfunc f() {}\n```"
        let base = inputs(userMessage: msg, localSizeGB: 2.5)
        XCTAssertEqual(AutopilotHeuristic.decide(base, aggressiveness: .conserve).target, .local)
        XCTAssertEqual(AutopilotHeuristic.decide(base, aggressiveness: .balanced).target, .cloud)
        XCTAssertEqual(AutopilotHeuristic.decide(base, aggressiveness: .frontier).target, .cloud)
    }

    func testHeuristicLargeLocalModelEarnsTrust() {
        let msg = "Please refactor this module.\n```swift\nfunc f() {}\n```"
        let d = AutopilotHeuristic.decide(inputs(userMessage: msg, localSizeGB: 12), aggressiveness: .balanced)
        XCTAssertEqual(d.target, .local)
    }

    func testHeuristicReasonKeysAlwaysLocalizable() {
        let cases = [
            "hi", "prove the theorem", "```code```", "what's my tax dosage situation",
            String(repeating: "long ", count: 500)
        ]
        for text in cases {
            let d = AutopilotHeuristic.decide(inputs(userMessage: text), aggressiveness: .balanced)
            let key = try? XCTUnwrap(d.reasonKey)
            XCTAssertNotNil(key, "heuristic must emit a reason key for: \(text.prefix(24))")
            XCTAssertNotEqual(AutopilotReasonKey.localized(key!), key!, "key must resolve: \(key!)")
        }
    }

    // MARK: - Defensive verdict parsing

    func testParseVerdictPlainJSON() {
        let v = AutopilotBrainClient.parseVerdict(from: #"{"route":"cloud","confidence":0.9,"reason":"hard math","category":"math_reasoning","est_difficulty":5}"#)
        XCTAssertEqual(v?.route, "cloud")
        XCTAssertEqual(v?.confidence, 0.9)
    }

    func testParseVerdictFencedJSON() {
        let content = """
        ```json
        {"route":"local","confidence":0.7,"reason":"simple","category":"casual_chat","est_difficulty":1}
        ```
        """
        XCTAssertEqual(AutopilotBrainClient.parseVerdict(from: content)?.route, "local")
    }

    func testParseVerdictEmbeddedInProse() {
        let content = #"Sure! Here's my decision: {"route":"local","confidence":0.8,"reason":"easy","category":"factual","est_difficulty":2} Hope that helps."#
        XCTAssertEqual(AutopilotBrainClient.parseVerdict(from: content)?.route, "local")
    }

    func testParseVerdictBalancedBracesInsideStrings() {
        let content = #"{"route":"local","confidence":0.8,"reason":"contains { brace } chars","category":"other","est_difficulty":1}"#
        XCTAssertEqual(AutopilotBrainClient.parseVerdict(from: content)?.reason, "contains { brace } chars")
    }

    func testParseVerdictGarbageReturnsNil() {
        XCTAssertNil(AutopilotBrainClient.parseVerdict(from: "I think local is best!"))
        XCTAssertNil(AutopilotBrainClient.parseVerdict(from: "{route: local"))
    }

    // MARK: - Energy estimator

    func testEnergyEstimatorNeverNegative() {
        XCTAssertGreaterThanOrEqual(EnergyEstimator.whSaved(localDurationSeconds: 100_000), 0)
        XCTAssertEqual(EnergyEstimator.localWh(durationSeconds: -5), 0)
    }

    func testEnergyEstimatorShortLocalTurnSavesMostOfCloudQuery() {
        let saved = EnergyEstimator.whSaved(localDurationSeconds: 10)
        XCTAssertGreaterThan(saved, EnergyEstimator.cloudWhPerQuery * 0.8)
        XCTAssertLessThanOrEqual(saved, EnergyEstimator.cloudWhPerQuery)
    }

    // MARK: - Msg round-trip with new fields

    func testMsgRouteRecordRoundTrip() throws {
        var decision = AutoRouteDecision.forced(.cloud, reasonKey: AutopilotReasonKey.contextOverflow)
        decision.category = .longContext
        let record = RouteDecisionRecord(
            decision: decision,
            escalationBackendName: "OpenRouter",
            escalationModelName: "TestCloud"
        )
        var msg = ChatVM.Msg(role: "🤖", text: "answer", localModelName: nil)
        msg.route = record

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)
        XCTAssertEqual(decoded.route, record)
        XCTAssertEqual(decoded.route?.target, .cloud)
    }

    func testCloudFallbackPreservesDecisionAndTracksAnswerTarget() throws {
        let decision = AutoRouteDecision.forced(.cloud, reasonKey: AutopilotReasonKey.cloudCapable)
        let record = RouteDecisionRecord(
            decision: decision,
            escalationBackendName: "OpenRouter",
            escalationModelName: "TestCloud",
            fellBackToLocal: true
        )

        XCTAssertEqual(record.target, .cloud)
        XCTAssertEqual(record.answerTarget, .local)
    }

    func testMsgWithoutRouteFieldsDecodes() throws {
        let legacyJSON = #"{"id":"\#(UUID().uuidString)","role":"🤖","text":"old message"}"#
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: Data(legacyJSON.utf8))
        XCTAssertNil(decoded.route)
        XCTAssertNil(decoded.localModelName)
        XCTAssertEqual(decoded.text, "old message")
    }

    func testLocalModelNameRoundTrip() throws {
        let msg = ChatVM.Msg(role: "🤖", text: "hi", localModelName: "TestLocal-4B")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)
        XCTAssertEqual(decoded.localModelName, "TestLocal-4B")
    }

    // MARK: - Local model card

    @MainActor
    func testRouterParameterLabelPrefersStoredLabelThenNameFallback() {
        func model(name: String, label: String?) -> LocalModel {
            LocalModel(modelID: "test/\(name)", name: name, url: URL(fileURLWithPath: "/tmp/\(name).gguf"),
                       quant: "Q4_K_M", parameterCountLabel: label, architecture: "", architectureFamily: "",
                       format: .gguf, sizeGB: 2, isMultimodal: false, isToolCapable: false,
                       isDownloaded: true, downloadDate: Date(), totalLayers: 32)
        }
        XCTAssertEqual(ChatVM.routerParameterLabel(for: model(name: "Qwen3.6-27B", label: nil)), "27B")
        XCTAssertEqual(ChatVM.routerParameterLabel(for: model(name: "Noema-2B-Q6_K", label: "2B")), "2B")
        XCTAssertEqual(ChatVM.routerParameterLabel(for: model(name: "gemma-4-31B-it-qat", label: nil)), "31B")
        XCTAssertEqual(ChatVM.routerParameterLabel(for: model(name: "Llama-0.5b-chat", label: nil)), "0.5B")
        XCTAssertEqual(ChatVM.routerParameterLabel(for: model(name: "mistral-large", label: nil)), "")
    }

    // MARK: - Config decode & configuration state

    func testLegacyAFMRouterKindIsRestoredDuringDecode() throws {
        let legacy = #"{"enabled":true,"routerKind":"appleFoundationModel"}"#
        let decoded = try JSONDecoder().decode(AutopilotConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(decoded.enabled)
        XCTAssertEqual(decoded.routerKind, .appleFoundationModel)
        XCTAssertNil(decoded.routerSelection)
        // A stronger target is still required even though AFM needs no remote
        // router selection.
        XCTAssertFalse(decoded.isConfigured)
    }

    func testConfigRequiresBothRouterAndEscalationSelections() {
        let router = StartupPreferences.RemoteSelection(
            backendID: UUID(), backendName: "OR", modelID: "r", modelName: "R"
        )
        let escalation = StartupPreferences.RemoteSelection(
            backendID: UUID(), backendName: "OR", modelID: "m", modelName: "M"
        )
        XCTAssertFalse(AutopilotConfig(routerSelection: router).isConfigured)
        XCTAssertFalse(AutopilotConfig(escalationSelection: escalation).isConfigured)
        XCTAssertTrue(AutopilotConfig(routerSelection: router, escalationSelection: escalation).isConfigured)
    }

    func testAFMRouterNeedsOnlyAnEscalationSelection() {
        let escalation = StartupPreferences.RemoteSelection(
            backendID: UUID(), backendName: "OR", modelID: "m", modelName: "M"
        )
        let config = AutopilotConfig(
            routerKind: .appleFoundationModel,
            escalationSelection: escalation
        )
        XCTAssertTrue(config.isConfigured)
        XCTAssertTrue(config.requiresCloudConsent)
    }

    func testAFMRouterWithLocalEscalationIsFullyLocal() {
        let local = AutopilotLocalEscalationSelection(
            modelID: "local/stronger",
            name: "Stronger Local",
            quant: "Q4_K_M",
            format: .mlx,
            urlPath: "/tmp/stronger",
            contextLength: 8192
        )
        let config = AutopilotConfig(
            routerKind: .appleFoundationModel,
            escalationTarget: .localModel,
            localEscalation: local
        )
        XCTAssertTrue(config.isConfigured)
        XCTAssertFalse(config.requiresCloudConsent)
        XCTAssertTrue(config.isReadyToArm)
    }

    func testPCCRouterAndEscalationRoundTrip() throws {
        let config = AutopilotConfig(
            enabled: true,
            routerKind: .privateCloudCompute,
            escalationTarget: .privateCloudCompute,
            consentAcceptedAt: Date()
        )
        let decoded = try JSONDecoder().decode(
            AutopilotConfig.self,
            from: JSONEncoder().encode(config)
        )
        XCTAssertEqual(decoded.routerKind, .privateCloudCompute)
        XCTAssertEqual(decoded.escalationTarget, .privateCloudCompute)
        XCTAssertTrue(decoded.requiresCloudConsent)
        XCTAssertEqual(decoded.isConfigured, ApplePrivateCloudComputeAvailability.isSelectable)
    }

    // MARK: - Schema rung selection

    func testInitialRungOpenRouterWithoutStructuredSupportSkipsToPromptOnly() {
        let backend = makeBackend()
        let bare = RemoteModel(id: "m", name: "m", author: "a")
        XCTAssertEqual(AutopilotBrainClient.initialRung(backend: backend, model: bare), .promptOnly)

        let structured = RemoteModel(id: "m2", name: "m2", author: "a", supportedParameters: ["response_format"])
        XCTAssertEqual(AutopilotBrainClient.initialRung(backend: backend, model: structured), .jsonSchema)
    }

    func testDemotionTargetJumpsToPromptOnlyOnStructuredRejection() {
        XCTAssertEqual(AutopilotBrainClient.demotionTarget(for: .httpError(400, "Invalid schema"), current: .jsonSchema), .promptOnly)
        XCTAssertEqual(AutopilotBrainClient.demotionTarget(for: .httpError(404, "no endpoints found"), current: .jsonObject), .promptOnly)
    }

    func testDemotionTargetNeverRetriesAuthCreditOrRateFailures() {
        for code in [401, 402, 403, 429] {
            XCTAssertNil(AutopilotBrainClient.demotionTarget(for: .httpError(code, ""), current: .jsonSchema), "code \(code)")
        }
        XCTAssertNil(AutopilotBrainClient.demotionTarget(for: .httpError(400, ""), current: .promptOnly))
        XCTAssertNil(AutopilotBrainClient.demotionTarget(for: .httpError(500, "server error"), current: .jsonSchema))
    }

    func testDemotionTargetStepwiseForUnparseableReplies() {
        XCTAssertEqual(AutopilotBrainClient.demotionTarget(for: .unparseable, current: .jsonSchema), .jsonObject)
        XCTAssertEqual(AutopilotBrainClient.demotionTarget(for: .unparseable, current: .jsonObject), .promptOnly)
        XCTAssertNil(AutopilotBrainClient.demotionTarget(for: .unparseable, current: .promptOnly))
    }

    func testInitialRungCustomEndpointTriesJSONSchemaFirst() {
        let backend = makeBackend(name: "Custom", baseURLString: "https://example.com", endpointType: .openAI)
        let model = RemoteModel(id: "m", name: "m", author: "a")
        XCTAssertEqual(AutopilotBrainClient.initialRung(backend: backend, model: model), .jsonSchema)
    }

    // MARK: - Verdict gate (LLM/AFM cloud verdicts)

    private func llmVerdict(confidence: Double = 0.9,
                            category: AutoRouteDecision.Category = .mathReasoning,
                            difficulty: Int = 3,
                            decidedBy: AutoRouteDecision.DecidedBy = .llm) -> AutoRouteDecision {
        AutoRouteDecision(target: .cloud,
                          confidence: confidence,
                          reason: "Needs the cloud model",
                          reasonKey: nil,
                          category: category,
                          estDifficulty: difficulty,
                          latencyMs: 120,
                          decidedBy: decidedBy)
    }

    func testVerdictGateConserveDemotesTextbookDifficulty() {
        // The Gemma-1B/physics repro: confident cloud verdict, textbook difficulty.
        let gated = AutopilotVerdictGate.apply(llmVerdict(confidence: 0.9, difficulty: 3),
                                               inputs: inputs(), aggressiveness: .conserve)
        XCTAssertEqual(gated.target, .local)
        XCTAssertEqual(gated.reasonKey, AutopilotReasonKey.routineForMode)
        XCTAssertEqual(gated.decidedBy, .llm)
        XCTAssertEqual(gated.confidence, 0.9)
    }

    func testVerdictGateFrontierPassesSameVerdict() {
        let gated = AutopilotVerdictGate.apply(llmVerdict(confidence: 0.9, difficulty: 3),
                                               inputs: inputs(), aggressiveness: .frontier)
        XCTAssertEqual(gated.target, .cloud)
        XCTAssertNil(gated.reasonKey)
    }

    func testVerdictGateBalancedDemotesOnlyTrivial() {
        let trivial = AutopilotVerdictGate.apply(llmVerdict(difficulty: 1),
                                                 inputs: inputs(), aggressiveness: .balanced)
        XCTAssertEqual(trivial.target, .local)
        let everyday = AutopilotVerdictGate.apply(llmVerdict(difficulty: 2),
                                                  inputs: inputs(), aggressiveness: .balanced)
        XCTAssertEqual(everyday.target, .cloud)
    }

    func testVerdictGateHighStakesEscalatesOnConserve() {
        let confident = AutopilotVerdictGate.apply(llmVerdict(confidence: 0.8, category: .highStakes, difficulty: 2),
                                                   inputs: inputs(), aggressiveness: .conserve)
        XCTAssertEqual(confident.target, .cloud)
        let shaky = AutopilotVerdictGate.apply(llmVerdict(confidence: 0.4, category: .highStakes, difficulty: 2),
                                               inputs: inputs(), aggressiveness: .conserve)
        XCTAssertEqual(shaky.target, .local)
        XCTAssertEqual(shaky.reasonKey, AutopilotReasonKey.lowRouterConfidence)
    }

    func testVerdictGateLongContextExemptOnlyWithEvidence() {
        // 5000 tokens + 1024 reply headroom crowds a 8192-token window (>60%).
        let crowded = AutopilotVerdictGate.apply(llmVerdict(category: .longContext, difficulty: 2),
                                                 inputs: inputs(promptTokenEstimate: 5000),
                                                 aggressiveness: .conserve)
        XCTAssertEqual(crowded.target, .cloud)
        let roomy = AutopilotVerdictGate.apply(llmVerdict(category: .longContext, difficulty: 2),
                                               inputs: inputs(promptTokenEstimate: 800),
                                               aggressiveness: .conserve)
        XCTAssertEqual(roomy.target, .local)
        XCTAssertEqual(roomy.reasonKey, AutopilotReasonKey.routineForMode)
    }

    func testVerdictGateLowConfidenceDemotionSetsReasonKey() {
        let gated = AutopilotVerdictGate.apply(llmVerdict(confidence: 0.5, difficulty: 5),
                                               inputs: inputs(), aggressiveness: .balanced)
        XCTAssertEqual(gated.target, .local)
        XCTAssertEqual(gated.reasonKey, AutopilotReasonKey.lowRouterConfidence)
        XCTAssertEqual(gated.reason, AutopilotReasonKey.localized(AutopilotReasonKey.lowRouterConfidence))
    }

    func testVerdictGateIgnoresHeuristicAndForcedVerdicts() {
        for decidedBy in [AutoRouteDecision.DecidedBy.heuristic, .forced] {
            let verdict = llmVerdict(confidence: 0.1, difficulty: 1, decidedBy: decidedBy)
            let gated = AutopilotVerdictGate.apply(verdict, inputs: inputs(), aggressiveness: .conserve)
            XCTAssertEqual(gated, verdict, "\(decidedBy) verdicts must pass through untouched")
        }
    }

    func testNewReasonKeysLocalize() {
        for key in [AutopilotReasonKey.lowRouterConfidence,
                    AutopilotReasonKey.routineForMode,
                    AutopilotReasonKey.routerCoolingDown,
                    AutopilotReasonKey.cloudCapable] {
            XCTAssertNotEqual(AutopilotReasonKey.localized(key), key, "key must resolve: \(key)")
        }
    }

    func testVerdictGateExplicitRequestBypassesDifficultyFloor() {
        // "Use your strongest model for this" on a trivial task must be honored.
        let gated = AutopilotVerdictGate.apply(llmVerdict(confidence: 0.9, category: .explicitRequest, difficulty: 1),
                                               inputs: inputs(), aggressiveness: .conserve)
        XCTAssertEqual(gated.target, .cloud)
        XCTAssertNil(gated.reasonKey)
    }

    func testVerdictGateExemptionFloorNeverStricterThanModeGate() {
        // Frontier's gate is 0.50; the high-stakes sanity floor must not
        // demote a verdict the plain gate would pass.
        let verdict = llmVerdict(confidence: 0.55, category: .highStakes, difficulty: 2)
        XCTAssertEqual(AutopilotVerdictGate.apply(verdict, inputs: inputs(), aggressiveness: .frontier).target, .cloud)
        XCTAssertEqual(AutopilotVerdictGate.apply(verdict, inputs: inputs(), aggressiveness: .conserve).target, .local)
    }

    func testSystemPromptStableAcrossPerTurnState() {
        // Per-turn state belongs in the snapshot, not the reusable remote
        // router system prompt or AFM's stable prewarm instructions.
        var fast = inputs()
        fast.localModel.recentAvgTokPerSec = 42.3
        fast.batteryLevel = 0.9
        var slow = inputs()
        slow.localModel.recentAvgTokPerSec = 17.8
        slow.batteryLevel = 0.2
        XCTAssertEqual(AutopilotBrainClient.systemPrompt(inputs: fast, aggressiveness: .conserve),
                       AutopilotBrainClient.systemPrompt(inputs: slow, aggressiveness: .conserve))
        XCTAssertTrue(AutopilotBrainClient.turnSnapshot(inputs: fast).contains("42.3 tokens/sec"))
    }

    // MARK: - Turn snapshot route history

    func testTurnSnapshotLastRoute() {
        // Mixed history whose newest answer was cloud: the old count-based
        // computation reported "local" here.
        let mixed = AutopilotBrainClient.turnSnapshot(
            inputs: inputs(priorLocalRoutes: 3, priorCloudRoutes: 1, lastRoute: .cloud)
        )
        XCTAssertTrue(mixed.contains("Last route: cloud"))

        let unknown = AutopilotBrainClient.turnSnapshot(
            inputs: inputs(priorLocalRoutes: 3, priorCloudRoutes: 1)
        )
        XCTAssertFalse(unknown.contains("Last route"))
        XCTAssertTrue(unknown.contains("local x3, cloud x1"))
    }

    // MARK: - Mode-aware rubric

    func testConservePromptClosedRubric() {
        let conserve = AutopilotBrainClient.systemPrompt(inputs: inputs(), aggressiveness: .conserve)
        let balanced = AutopilotBrainClient.systemPrompt(inputs: inputs(), aggressiveness: .balanced)
        let frontier = AutopilotBrainClient.systemPrompt(inputs: inputs(), aggressiveness: .frontier)

        XCTAssertTrue(conserve.contains("Route CLOUD only when"))
        XCTAssertTrue(conserve.contains("a block slides down a ramp"))
        XCTAssertFalse(balanced.contains("Route CLOUD only when"))
        XCTAssertFalse(frontier.contains("Route CLOUD only when"))
        XCTAssertNotEqual(conserve, balanced)
        XCTAssertNotEqual(balanced, frontier)
    }

    func testAFMClassifierPromptStaysCompactAndContainsNoOutputProseFields() {
        let prompt = AutopilotBrainClient.afmRoutingPrompt(
            inputs: inputs(),
            aggressiveness: .balanced
        )
        XCTAssertLessThan(prompt.count, 4_000)
        XCTAssertTrue(prompt.contains("POLICY: BALANCED"))
        XCTAssertTrue(prompt.contains("TURN SNAPSHOT"))
        XCTAssertFalse(prompt.contains("DOCUMENT ACCESS POLICY"))
        XCTAssertFalse(prompt.contains("est_difficulty"))
        XCTAssertFalse(prompt.contains("confidence:"))
        XCTAssertLessThan(AutopilotBrainClient.afmPlannerInstructions.count, 700)
    }

    func testAFMResolvedDecisionUsesDeterministicMetadata() {
        let heavy = inputs(
            userMessage: "Implement and debug this full program, then prove its complexity. ```swift\nfunc f() {}\n```"
        )
        let decision = AutopilotAFMBrain.resolvedDecision(
            target: .cloud,
            inputs: heavy,
            aggressiveness: .balanced,
            latencyMs: 725
        )
        XCTAssertEqual(decision.target, .cloud)
        XCTAssertEqual(decision.decidedBy, .afm)
        XCTAssertEqual(decision.category, .codingHeavy)
        XCTAssertEqual(decision.latencyMs, 725)
        XCTAssertNotNil(decision.reasonKey)
    }

    func testFrontierCloudReceiptNeverClaimsTheRequestIsSimpleLocalWork() {
        // Prompt length + a small local model is enough to cross Frontier's
        // cloud threshold even without a keyword assigning a dominant reason.
        let ambiguous = inputs(
            userMessage: String(repeating: "Please consider every detail carefully. ", count: 24),
            localSizeGB: 1.0
        )
        let heuristic = AutopilotHeuristic.decide(ambiguous, aggressiveness: .frontier)
        XCTAssertEqual(heuristic.target, .cloud)
        XCTAssertEqual(heuristic.reasonKey, AutopilotReasonKey.cloudCapable)

        let afm = AutopilotAFMBrain.resolvedDecision(
            target: .cloud,
            inputs: ambiguous,
            aggressiveness: .frontier,
            latencyMs: 1_071
        )
        XCTAssertEqual(afm.target, .cloud)
        XCTAssertEqual(afm.reasonKey, AutopilotReasonKey.cloudCapable)
        XCTAssertEqual(afm.reason, AutopilotReasonKey.localized(AutopilotReasonKey.cloudCapable))
    }

    func testPhysicsDerivationGetsFormalReasoningReceipt() {
        let physics = inputs(
            userMessage: "Find the minimum launch speed. Your derivation must account for recoil and verify contact throughout the revolution."
        )
        let decision = AutopilotHeuristic.decide(physics, aggressiveness: .frontier)
        XCTAssertEqual(decision.target, .cloud)
        XCTAssertEqual(decision.category, .mathReasoning)
        XCTAssertEqual(decision.reasonKey, AutopilotReasonKey.hardMath)
    }

    @MainActor
    func testAutoRoutingAwaiterCanReleaseChatBeforeLateWorkerResult() async {
        let awaiter = AutoRoutingAwaiter()
        let local = routingOutcome(
            target: .local,
            reasonKey: AutopilotReasonKey.routerUnreachable
        )
        let lateCloud = routingOutcome(
            target: .cloud,
            reasonKey: AutopilotReasonKey.cloudCapable
        )
        let waiting = Task { @MainActor in
            await awaiter.value()
        }
        await Task.yield()

        XCTAssertTrue(awaiter.resolve(local))
        let outcome = await waiting.value
        XCTAssertEqual(outcome?.decision.target, .local)
        XCTAssertEqual(outcome?.decision.reasonKey, AutopilotReasonKey.routerUnreachable)

        // A non-cooperative router worker may report after cancellation. The
        // late result must not replace the already-authoritative local fallback.
        XCTAssertFalse(awaiter.resolve(lateCloud))
        let repeatedRead = await awaiter.value()
        XCTAssertEqual(repeatedRead?.decision.target, .local)
        XCTAssertEqual(repeatedRead?.decision.reasonKey, AutopilotReasonKey.routerUnreachable)
    }

    @MainActor
    func testLifecycleRoutingFallbackPreservesPendingTurnAndSendOwnership() async {
        let vm = ChatVM()
        let probe = DeterministicLLMClientProbe()
        let client = AnyLLMClient.makeDeterministicFake(chunks: ["Hello"], probe: probe)
        vm.msgs = [
            .init(role: "system", text: "test"),
            .init(role: "🧑‍💻", text: "Hi"),
            .init(role: "🤖", text: "", streaming: true)
        ]
        vm.setClientForTesting(
            client,
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/test.gguf"),
            loadedFormat: .gguf
        )
        let awaiter = vm.prepareAutoRoutingWaitForTesting()
        let waiting = Task { @MainActor in await awaiter.value() }
        await Task.yield()

        XCTAssertTrue(vm.cancelAutoRoutingAndContinueLocally(reason: "test-memory-warning"))
        let outcome = await waiting.value
        XCTAssertEqual(outcome?.decision.target, .local)
        XCTAssertEqual(outcome?.decision.reasonKey, AutopilotReasonKey.routerUnreachable)
        XCTAssertEqual(vm.autoRoutingStage, .none)
        XCTAssertTrue(vm.sendInFlight)
        XCTAssertTrue(vm.modelLoaded)
        XCTAssertTrue(vm.canAcceptChatInput)
        XCTAssertEqual(vm.msgs.count, 3)
        XCTAssertEqual(vm.msgs[1].text, "Hi")
        XCTAssertTrue(vm.msgs[2].streaming)
        vm.msgs[2].streaming = false
        let didUnload = await vm.unloadIfIdle(reason: "test-memory-warning")
        XCTAssertFalse(didUnload)
        XCTAssertEqual(probe.unloadCount, 0)
        XCTAssertEqual(probe.asyncUnloadCount, 0)

        vm.setAutoRoutingLifecycleStateForTesting(sendInFlight: false, stage: .none)
    }

    @MainActor
    func testBackgroundDefersLocalFallbackUntilSceneIsActive() async {
        let vm = ChatVM()
        let awaiter = vm.prepareAutoRoutingWaitForTesting()
        let waiting = Task { @MainActor in await awaiter.value() }
        await Task.yield()

        XCTAssertTrue(vm.deferAutoRoutingLocallyUntilActive(reason: "test-background"))
        XCTAssertFalse(awaiter.isResolved)
        XCTAssertEqual(vm.autoRoutingStage, .deciding)

        XCTAssertTrue(vm.resumeDeferredAutoRoutingIfNeeded())
        let outcome = await waiting.value
        XCTAssertEqual(outcome?.decision.target, .local)
        XCTAssertEqual(outcome?.decision.reasonKey, AutopilotReasonKey.routerUnreachable)
        XCTAssertEqual(vm.autoRoutingStage, .none)

        vm.setAutoRoutingLifecycleStateForTesting(sendInFlight: false, stage: .none)
    }

    @MainActor
    func testLifecycleFallbackCompletesTheRealLocalSendAndIgnoresLateCloud() async {
        let vm = ChatVM()
        let probe = DeterministicLLMClientProbe()
        let client = AnyLLMClient.makeDeterministicFake(chunks: ["Hello"], probe: probe)
        vm.msgs = [.init(role: "system", text: "test")]
        vm.setClientForTesting(
            client,
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/test.gguf"),
            loadedFormat: .gguf
        )
        let lateCloud = routingOutcome(
            target: .cloud,
            reasonKey: AutopilotReasonKey.cloudCapable
        )
        vm.setAutoRoutingOutcomeProviderForTesting {
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                // Deliberately emulate a framework worker that reports after
                // its chat-side continuation has already been released.
            }
            return lateCloud
        }

        let send = Task { @MainActor in await vm.sendMessage("Hi") }
        for _ in 0..<1_000 where vm.autoRoutingStage != .deciding {
            await Task.yield()
        }
        XCTAssertEqual(vm.autoRoutingStage, .deciding)
        XCTAssertTrue(vm.cancelAutoRoutingAndContinueLocally(reason: "test-memory-warning"))

        await send.value
        vm.setAutoRoutingOutcomeProviderForTesting(nil)

        XCTAssertEqual(probe.inputs.count, 1)
        XCTAssertEqual(vm.msgs.last?.text, "Hello")
        XCTAssertEqual(vm.msgs.last?.route?.target, .local)
        XCTAssertEqual(
            vm.msgs.last?.route?.reasonKey,
            AutopilotReasonKey.routerUnreachable
        )
        XCTAssertFalse(vm.msgs.last?.streaming ?? true)
        XCTAssertEqual(probe.unloadCount, 0)
        XCTAssertEqual(probe.asyncUnloadCount, 0)
    }

    func testSystemPromptOutputSpecToggle() {
        let full = AutopilotBrainClient.systemPrompt(inputs: inputs(), aggressiveness: .balanced)
        XCTAssertTrue(full.contains("exactly one JSON object"))
        let guided = AutopilotBrainClient.systemPrompt(inputs: inputs(), aggressiveness: .balanced,
                                                       includeOutputSpec: false)
        XCTAssertFalse(guided.contains("exactly one JSON object"))
        XCTAssertTrue(guided.contains("est_difficulty"))
    }
}
