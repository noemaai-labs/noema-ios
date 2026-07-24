import Foundation
import XCTest
@testable import Noema

final class AFMIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        HiddenModelsStore.clear()
    }

    override func tearDown() {
        HiddenModelsStore.clear()
        super.tearDown()
    }

    func testAFMRegistryPublishesParameterCountLabel() async throws {
        let registry = AppleFoundationModelRegistry()
        let curated = try await registry.curated()

        if AppleFoundationModelRegistry.availableKinds.contains(.onDevice) {
            XCTAssertEqual(curated.first?.parameterCountLabel, AppleFoundationModelRegistry.parameterCountLabel)

            let details = try await registry.details(for: AppleFoundationModelRegistry.modelID)
            XCTAssertEqual(details.parameterCountLabel, AppleFoundationModelRegistry.parameterCountLabel)
        } else {
            XCTAssertTrue(curated.isEmpty)
        }
    }

    func testAvailabilityStateInvariants() {
        let state = AppleFoundationModelAvailability.current

        if state.isAvailableNow {
            XCTAssertTrue(state.isSupportedDevice)
            XCTAssertNil(state.unavailableReason)
        } else if !state.isSupportedDevice {
            XCTAssertEqual(state.unavailableReason, .unsupportedDevice)
        }
    }

    func testAFMRegistryCuratedHonorsSupportGate() async throws {
        let registry = AppleFoundationModelRegistry()
        let curated = try await registry.curated()

        XCTAssertEqual(curated.count, AppleFoundationModelRegistry.availableKinds.count)
        XCTAssertEqual(Set(curated.map(\.id)), Set(AppleFoundationModelRegistry.availableKinds.map(\.modelID)))
        XCTAssertTrue(curated.allSatisfy { $0.formats == [.afm] })
    }

    func testAFMRegistrySearchYieldsOnlyCanonicalEntry() async throws {
        let registry = AppleFoundationModelRegistry()

        let matching = try await collect(
            registry.searchStream(
                query: "apple",
                page: 0,
                format: .afm,
                includeVisionModels: false,
                visionOnly: false
            )
        )

        XCTAssertEqual(matching.count, AppleFoundationModelRegistry.availableKinds.count)
        XCTAssertEqual(Set(matching.map(\.id)), Set(AppleFoundationModelRegistry.availableKinds.map(\.modelID)))

        let nonMatching = try await collect(
            registry.searchStream(
                query: "definitely-not-a-model-name",
                page: 0,
                format: .afm,
                includeVisionModels: false,
                visionOnly: false
            )
        )
        XCTAssertTrue(nonMatching.isEmpty)
    }

    func testCombinedRegistryRoutesAFMSearchAwayFromPrimary() async throws {
        let primary = CountingRegistry()
        let combined = CombinedRegistry(primary: primary, extras: [])

        _ = try await collect(
            combined.searchStream(
                query: "apple",
                page: 0,
                format: .afm,
                includeVisionModels: false,
                visionOnly: false
            )
        )

        XCTAssertEqual(primary.currentSearchCalls(), 0)
    }

    func testCombinedRegistryUsesPrimaryForNonAFMSearch() async throws {
        let primary = CountingRegistry()
        let combined = CombinedRegistry(primary: primary, extras: [])

        _ = try await collect(
            combined.searchStream(
                query: "qwen",
                page: 0,
                format: .gguf,
                includeVisionModels: true,
                visionOnly: false
            )
        )

        XCTAssertEqual(primary.currentSearchCalls(), 1)
    }

    func testCombinedRegistryCuratedExcludesAFMFromRecommended() async throws {
        let combined = CombinedRegistry(primary: CountingRegistry(), extras: [AppleFoundationModelRegistry()])
        let curated = try await combined.curated()

        XCTAssertFalse(curated.contains(where: { $0.id == AppleFoundationModelRegistry.modelID }))
        XCTAssertFalse(curated.contains(where: { $0.id == AppleFoundationModelRegistry.privateCloudModelID }))
    }

    func testANEExploreRestrictsResultsToAnemllAuthor() {
        XCTAssertEqual(HuggingFaceRegistry.requiredAuthor(for: .ane), "anemll")
        XCTAssertTrue(HuggingFaceRegistry.matchesAuthorConstraint(format: .ane, modelID: "anemll/sample-model", author: nil))
        XCTAssertTrue(HuggingFaceRegistry.matchesAuthorConstraint(format: .ane, modelID: "someone/sample-model", author: "anemll"))
        XCTAssertFalse(HuggingFaceRegistry.matchesAuthorConstraint(format: .ane, modelID: "someone/sample-model", author: "someone"))
        XCTAssertTrue(HuggingFaceRegistry.matchesAuthorConstraint(format: .gguf, modelID: "someone/sample-model", author: "someone"))
    }

    @MainActor
    func testExploreModeCycleIncludesOrSkipsAFMFromANE() {
        let vm = ExploreViewModel(registry: CountingRegistry())
        vm.searchMode = .ane
        vm.toggleMode()

        if AppleFoundationModelAvailability.isSupportedDevice {
            XCTAssertEqual(vm.searchMode, .afm)
        } else {
            XCTAssertEqual(vm.searchMode, .gguf)
        }
    }

    @MainActor
    func testAppModelManagerBuiltInAFMSyncMatchesSupport() {
        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let store = InstalledModelsStore(filename: fileName)
        let manager = AppModelManager(store: store)

        let afmModel = manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.modelID
                && $0.quant == AppleFoundationModelRegistry.quantLabel
                && $0.format == .afm
        }

        XCTAssertEqual(afmModel != nil, AppleFoundationModelAvailability.isSupportedDevice)
        if let afmModel {
            XCTAssertEqual(afmModel.parameterCountLabel, AppleFoundationModelRegistry.parameterCountLabel)
            XCTAssertTrue(afmModel.isToolCapable)
        }
    }

    @MainActor
    func testAppModelManagerPublishesPCCAsASeparateStoredModelWhenSelectable() {
        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let manager = AppModelManager(store: InstalledModelsStore(filename: fileName))
        let pcc = manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.privateCloudModelID
                && $0.quant == AppleFoundationModelRegistry.privateCloudQuantLabel
                && $0.format == .afm
        }

        XCTAssertEqual(pcc != nil, ApplePrivateCloudComputeAvailability.isSelectable)
        if let pcc {
            XCTAssertEqual(pcc.parameterCountLabel, AppleFoundationModelRegistry.privateCloudParameterCountLabel)
            XCTAssertTrue(pcc.isMultimodal)
            XCTAssertTrue(pcc.isToolCapable)
        }
    }

    func testLocalModelLoadInstalledPropagatesParameterCountLabel() {
        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let store = InstalledModelsStore(filename: fileName)
        let installed = InstalledModel(
            modelID: AppleFoundationModelRegistry.modelID,
            quantLabel: AppleFoundationModelRegistry.quantLabel,
            parameterCountLabel: AppleFoundationModelRegistry.parameterCountLabel,
            url: InstalledModelsStore.baseDir(for: .afm, modelID: AppleFoundationModelRegistry.modelID),
            format: .afm,
            sizeBytes: 0,
            lastUsed: nil,
            installDate: Date(),
            checksum: nil,
            isFavourite: false,
            totalLayers: 0,
            isMultimodal: false,
            isToolCapable: true
        )
        store.add(installed)

        let local = LocalModel.loadInstalled(store: store).first {
            $0.modelID == AppleFoundationModelRegistry.modelID && $0.quant == AppleFoundationModelRegistry.quantLabel
        }

        XCTAssertEqual(local?.parameterCountLabel, AppleFoundationModelRegistry.parameterCountLabel)
        XCTAssertEqual(local?.isToolCapable, true)
    }

    func testInstalledModelDecodesWithoutParameterCountLabel() throws {
        let json = """
        {
          "id":"\(UUID().uuidString)",
          "modelID":"apple/system-foundation-model",
          "quantLabel":"System",
          "url":"afm://system",
          "format":"AFM",
          "sizeBytes":0,
          "installDate":0,
          "checksum":null,
          "isFavourite":false,
          "totalLayers":0,
          "isMultimodal":false,
          "isToolCapable":true
        }
        """

        let decoded = try JSONDecoder().decode(InstalledModel.self, from: Data(json.utf8))
        XCTAssertNil(decoded.parameterCountLabel)
        XCTAssertEqual(decoded.format, .afm)
    }

    func testAFMToolCapabilityDetectorReturnsTrue() {
        XCTAssertTrue(ToolCapabilityDetector.isToolCapableLocal(url: URL(fileURLWithPath: "/tmp/afm"), format: .afm))
    }

    func testAFMWebToolGateDisabledForOnDeviceKind() {
        // No persisted kind → resolves to .onDevice, which stays tool-free.
        XCTAssertFalse(WebToolGate.isAvailable(currentFormat: .afm, afmKind: .onDevice))
        XCTAssertFalse(ToolAvailability.current(currentFormat: .afm, afmKind: .onDevice).webSearch)
    }

    func testAFMWebToolGateAllowsPrivateCloudComputeKind() {
        let defaults = UserDefaults.standard
        let keys = [
            "webSearchEnabled", "webSearchArmed", "offGrid",
            "selectedDatasetID", "indexingDatasetIDPersisted",
            "currentModelSupportsFunctionCalling",
            AppleFoundationModelKind.persistedCurrentKindKey
        ]
        let previous = keys.reduce(into: [String: Any?]()) { $0[$1] = defaults.object(forKey: $1) }
        defer {
            for key in keys {
                if let value = previous[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: "webSearchEnabled")
        defaults.set(true, forKey: "webSearchArmed")
        defaults.set(false, forKey: "offGrid")
        defaults.set("", forKey: "selectedDatasetID")
        defaults.set("", forKey: "indexingDatasetIDPersisted")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")

        // Explicit kind from an AFM client wins.
        XCTAssertTrue(WebToolGate.isAvailable(currentFormat: .afm, afmKind: .privateCloudCompute))
        XCTAssertTrue(ToolAvailability.current(currentFormat: .afm, afmKind: .privateCloudCompute).webSearch)
        XCTAssertFalse(WebToolGate.isAvailable(currentFormat: .afm, afmKind: .onDevice))

        // Callers that don't know the kind fall back to the persisted one.
        defaults.set(AppleFoundationModelKind.privateCloudCompute.rawValue, forKey: AppleFoundationModelKind.persistedCurrentKindKey)
        XCTAssertTrue(WebToolGate.isAvailable(currentFormat: .afm))
        defaults.set(AppleFoundationModelKind.onDevice.rawValue, forKey: AppleFoundationModelKind.persistedCurrentKindKey)
        XCTAssertFalse(WebToolGate.isAvailable(currentFormat: .afm))
    }

    func testAFMDefaultSettingsUsePermissiveGuardrails() {
        XCTAssertEqual(ModelSettings.default(for: .afm).afmGuardrails, .permissiveContentTransformations)
    }

    func testAFMGuardrailsExposeSettingsLabels() {
        XCTAssertEqual(AFMGuardrailsMode.default.titleKey, "Standard")
        XCTAssertEqual(AFMGuardrailsMode.permissiveContentTransformations.titleKey, "Content Transformation")
        XCTAssertEqual(
            AFMGuardrailsMode.permissiveContentTransformations.detailKey,
            "Allows Apple's permissive content-transformation guardrails for rewriting or transforming user-provided content."
        )
    }

    func testAFMClientAlwaysResolvesToPermissiveGuardrails() {
        // The guardrail is pinned to the most permissive option regardless of what
        // (if anything) is persisted — including a stored `.default` from older builds.
        var settings = ModelSettings.default(for: .afm)
        settings.afmGuardrails = .default

        XCTAssertEqual(AFMLLMClient.resolvedGuardrailsMode(from: settings), .permissiveContentTransformations)
        XCTAssertEqual(AFMLLMClient.resolvedGuardrailsMode(from: nil), .permissiveContentTransformations)
    }

    func testAFMFixedContextNormalizationUsesRuntimeSystemWindow() {
        let model = LocalModel(
            modelID: AppleFoundationModelRegistry.modelID,
            name: AppleFoundationModelRegistry.modelName,
            url: URL(fileURLWithPath: "/tmp/afm"),
            quant: AppleFoundationModelRegistry.quantLabel,
            architecture: "",
            architectureFamily: "",
            format: .afm,
            sizeGB: 0,
            isMultimodal: false,
            isToolCapable: true,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )

        let runtimeContext = AFMLLMClient.onDeviceContextLimit()
        let stale = ModelSettings(contextLength: 1_000_000)
        XCTAssertEqual(ModelSettings.fixedContextLength(for: model), runtimeContext)
        XCTAssertEqual(stale.normalizedForLocalModel(model).contextLength, Double(runtimeContext))
    }

    func testPCCFixedContextNormalizationUses32KWindow() {
        let model = LocalModel(
            modelID: AppleFoundationModelRegistry.privateCloudModelID,
            name: AppleFoundationModelRegistry.privateCloudModelName,
            url: URL(fileURLWithPath: "/tmp/pcc"),
            quant: AppleFoundationModelRegistry.privateCloudQuantLabel,
            architecture: "",
            architectureFamily: "",
            format: .afm,
            sizeGB: 0,
            isMultimodal: true,
            isToolCapable: true,
            isDownloaded: true,
            downloadDate: Date(),
            totalLayers: 0
        )

        XCTAssertEqual(
            ModelSettings.fixedContextLength(for: model),
            AppleFoundationModelKind.privateCloudContextLimit
        )
    }

    @MainActor
    func testMsgPrivateCloudOriginRoundTrips() throws {
        var msg = ChatVM.Msg(role: "🤖", text: "hello", timestamp: Date())
        msg.ranOnPrivateCloudCompute = true

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)
        XCTAssertEqual(decoded.ranOnPrivateCloudCompute, true)

        let plain = ChatVM.Msg(role: "🤖", text: "hello", timestamp: Date())
        let plainData = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(data: plainData, encoding: .utf8)!.contains("ranOnPrivateCloudCompute"))
        let decodedPlain = try JSONDecoder().decode(ChatVM.Msg.self, from: plainData)
        XCTAssertNil(decodedPlain.ranOnPrivateCloudCompute)
    }

    @MainActor
    func testHidingAFMRemovesItFromDownloadedModelsAndKeepsItInHiddenModels() throws {
        try XCTSkipUnless(AppleFoundationModelAvailability.isSupportedDevice, "AFM is unavailable on this device.")

        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let manager = AppModelManager(store: InstalledModelsStore(filename: fileName))
        let afmModel = try XCTUnwrap(manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm
        })

        manager.hide(afmModel)

        XCTAssertFalse(manager.downloadedModels.contains { $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm })
        XCTAssertTrue(manager.hiddenModels.contains { $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm })
        XCTAssertTrue(HiddenModelsStore.isHidden(modelID: afmModel.modelID, quantLabel: afmModel.quant))
    }

    @MainActor
    func testUnhidingAFMRestoresItToDownloadedModels() throws {
        try XCTSkipUnless(AppleFoundationModelAvailability.isSupportedDevice, "AFM is unavailable on this device.")

        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let manager = AppModelManager(store: InstalledModelsStore(filename: fileName))
        let afmModel = try XCTUnwrap(manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm
        })

        manager.hide(afmModel)
        manager.unhide(modelID: afmModel.modelID, quantLabel: afmModel.quant)

        XCTAssertTrue(manager.downloadedModels.contains { $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm })
        XCTAssertFalse(manager.hiddenModels.contains { $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm })
        XCTAssertFalse(HiddenModelsStore.isHidden(modelID: afmModel.modelID, quantLabel: afmModel.quant))
    }

    @MainActor
    func testHiddenAFMRemainsRepresentedAfterRefreshAndSync() throws {
        try XCTSkipUnless(AppleFoundationModelAvailability.isSupportedDevice, "AFM is unavailable on this device.")

        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let store = InstalledModelsStore(filename: fileName)
        let manager = AppModelManager(store: store)
        let afmModel = try XCTUnwrap(manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm
        })

        manager.hide(afmModel)
        manager.refresh()

        XCTAssertTrue(manager.hiddenModels.contains { $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm })

        let secondManager = AppModelManager(store: InstalledModelsStore(filename: fileName))
        XCTAssertTrue(secondManager.hiddenModels.contains { $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm })
    }

    @MainActor
    func testStartupPreferenceSanitizeClearsHiddenAFMLocalDefault() throws {
        try XCTSkipUnless(AppleFoundationModelAvailability.isSupportedDevice, "AFM is unavailable on this device.")

        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let manager = AppModelManager(store: InstalledModelsStore(filename: fileName))
        let afmModel = try XCTUnwrap(manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm
        })

        manager.hide(afmModel)

        let preferences = StartupPreferences(localModelPath: afmModel.url.path, priority: .localFirst)
        let sanitized = StartupPreferencesStore.sanitize(
            preferences: preferences,
            models: manager.downloadedModels,
            backends: manager.remoteBackends
        )

        XCTAssertNil(sanitized.localModelPath)
    }

    @MainActor
    func testReenabledAFMBecomesEligibleForStartupSelection() throws {
        try XCTSkipUnless(AppleFoundationModelAvailability.isSupportedDevice, "AFM is unavailable on this device.")

        let fileName = uniqueInstalledStoreFile()
        defer { removeInstalledStore(named: fileName) }

        let manager = AppModelManager(store: InstalledModelsStore(filename: fileName))
        let afmModel = try XCTUnwrap(manager.downloadedModels.first {
            $0.modelID == AppleFoundationModelRegistry.modelID && $0.format == .afm
        })

        manager.hide(afmModel)
        manager.unhide(modelID: afmModel.modelID, quantLabel: afmModel.quant)

        let preferences = StartupPreferences(localModelPath: afmModel.url.path, priority: .localFirst)
        let sanitized = StartupPreferencesStore.sanitize(
            preferences: preferences,
            models: manager.downloadedModels,
            backends: manager.remoteBackends
        )

        XCTAssertEqual(sanitized.localModelPath, afmModel.url.path)
    }

    func testAFMWebSearchExecutionClampsCountAndNormalizesSafeSearch() async {
        let payload = await AFMWebSearchExecution.perform(
            query: "  apple intelligence  ",
            count: 99,
            safesearch: "LOUD",
            isAvailable: true,
            searchHandler: { query, count, safesearch in
                XCTAssertEqual(query, "apple intelligence")
                XCTAssertEqual(count, 5)
                XCTAssertEqual(safesearch, "moderate")
                return [
                    WebHit(
                        title: "Result",
                        url: "https://example.com",
                        snippet: "Snippet",
                        engine: "searxng",
                        score: 0.8
                    )
                ]
            }
        )

        let hits = AFMWebSearchExecution.hits(from: payload)
        XCTAssertEqual(hits?.count, 1)
        XCTAssertEqual(hits?.first?.title, "Result")
    }

    func testAFMWebSearchExecutionReturnsGateDisabledError() async {
        let payload = await AFMWebSearchExecution.perform(
            query: "apple intelligence",
            count: 3,
            safesearch: "moderate",
            isAvailable: false
        )

        XCTAssertEqual(AFMWebSearchExecution.errorMessage(from: payload), "Web search is disabled or offline-only.")
    }

    func testAFMModelReadableWebOutputFormatsHits() {
        let payload = """
        [{"title":"Result","url":"https://example.com","snippet":"Snippet","engine":"searxng","score":0.5}]
        """

        let rendered = AFMWebSearchExecution.modelReadableOutput(from: payload, query: "apple intelligence")
        XCTAssertTrue(rendered.contains("Web search results for \"apple intelligence\":"))
        XCTAssertTrue(rendered.contains("1. Result"))
        XCTAssertTrue(rendered.contains("URL: https://example.com"))
        XCTAssertTrue(rendered.contains("Snippet: Snippet"))
    }

    func testAFMModelReadableWebOutputFormatsErrors() {
        let rendered = AFMWebSearchExecution.modelReadableOutput(
            from: #"{"error":"Model not ready"}"#,
            query: "apple intelligence"
        )

        XCTAssertEqual(rendered, "Web search error: Model not ready")
    }

    func testAFMToolExecutionMapperResolvesWebHits() {
        let payload = """
        [{"title":"Result","url":"https://example.com","snippet":"Snippet","engine":"searxng","score":0.5}]
        """
        let summary = AFMToolExecutionSummary(
            calls: [
                AFMToolCallSummary(
                    toolName: "noema.web.retrieve",
                    requestParams: ["query": AnyCodable("apple intelligence")],
                    result: payload,
                    error: nil,
                    timestamp: Date()
                )
            ]
        )

        let resolved = AFMToolExecutionMapper.resolve(summary)
        XCTAssertEqual(resolved.calls.count, 1)
        XCTAssertTrue(resolved.usedWebSearch)
        XCTAssertEqual(resolved.calls.first?.displayName, "Web Search")
        XCTAssertEqual(resolved.webHits?.count, 1)
        XCTAssertNil(resolved.webError)
    }

    func testAFMToolExecutionMapperResolvesWebErrors() {
        let summary = AFMToolExecutionSummary(
            calls: [
                AFMToolCallSummary(
                    toolName: "noema.web.retrieve",
                    requestParams: ["query": AnyCodable("apple intelligence")],
                    result: "{\"error\":\"Model not ready\"}",
                    error: nil,
                    timestamp: Date()
                )
            ]
        )

        let resolved = AFMToolExecutionMapper.resolve(summary)
        XCTAssertTrue(resolved.usedWebSearch)
        XCTAssertNil(resolved.webHits)
        XCTAssertEqual(resolved.webError, "Model not ready")
    }

    func testAFMWebSearchExecutionMapsThrownSearchErrors() async {
        let payload = await AFMWebSearchExecution.perform(
            query: "apple intelligence",
            count: 1,
            safesearch: "moderate",
            isAvailable: true,
            searchHandler: { _, _, _ in
                throw URLError(.timedOut)
            }
        )

        XCTAssertEqual(AFMWebSearchExecution.errorMessage(from: payload), "Web search timed out. Please try again.")
    }

    func testAFMResolvedResponseTextPrefersDirectContent() {
        let response = MockAFMResponse(content: "Direct answer")

        let resolved = AFMLLMClient.resolvedResponseText(
            response: response,
            transcriptResponseText: "Transcript answer",
            preferTranscriptFallback: true
        )

        XCTAssertEqual(resolved, "Direct answer")
    }

    func testAFMResolvedResponseTextFallsBackToTranscriptWhenToolUsed() {
        let response = MockAFMResponse(content: "")

        let resolved = AFMLLMClient.resolvedResponseText(
            response: response,
            transcriptResponseText: "Transcript answer",
            preferTranscriptFallback: true
        )

        XCTAssertEqual(resolved, "Transcript answer")
    }

    private func uniqueInstalledStoreFile() -> String {
        "installed-afm-tests-\(UUID().uuidString).json"
    }

    private func removeInstalledStore(named fileName: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let testStoreURL = docs.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: testStoreURL)
    }
}

private final class CountingRegistry: ModelRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var searchCalls: Int = 0

    func curated() async throws -> [ModelRecord] {
        []
    }

    func searchStream(
        query: String,
        page: Int,
        format: ModelFormat?,
        includeVisionModels: Bool,
        visionOnly: Bool
    ) -> AsyncThrowingStream<ModelRecord, Error> {
        lock.lock()
        searchCalls += 1
        lock.unlock()

        return AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }

    func details(for id: String) async throws -> ModelDetails {
        throw URLError(.badURL)
    }

    func currentSearchCalls() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return searchCalls
    }
}

private func collect<T>(_ stream: AsyncThrowingStream<T, Error>) async throws -> [T] {
    var results: [T] = []
    for try await item in stream {
        results.append(item)
    }
    return results
}

private struct MockAFMResponse {
    let content: String
}
