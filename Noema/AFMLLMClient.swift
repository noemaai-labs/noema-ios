import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import CoreGraphics

// NOTE: Private Cloud Compute, multimodal `Attachment`, and the Dynamic
// Profile baton-pass routing (AFMDynamicProfileRouting.swift) are iOS 27 /
// Xcode 27 SDK symbols that don't exist in the iOS 26 SDK. `#if NOEMA_ENABLE_XCODE27_APIS`
// gates them at *compile time* because the Swift compiler version alone does
// not prove that the active SDK includes those symbols. Paired with
// `if #available` runtime checks where the symbols are used.

enum AFMLLMClientError: LocalizedError {
    case unsupportedDevice
    case unavailable(AppleFoundationModelUnavailableReason)
    case frameworkUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedDevice:
            return String(localized: "Apple Foundation Models are not supported on this device.")
        case .unavailable(let reason):
            return reason.message
        case .frameworkUnavailable:
            return String(localized: "Foundation Models framework is unavailable in this build.")
        }
    }
}

final class AFMLLMClient: @unchecked Sendable {
    #if canImport(FoundationModels)
    private var sessionStorage: AnyObject?
    #endif

    private let guardrailsMode: AFMGuardrailsMode
    private let privateCloudComputeMode: AFMPrivateCloudComputeMode
    private let onToolSummary: (@Sendable (AFMToolExecutionSummary) async -> Void)?
    private let onRouteInfo: (@Sendable (AFMTurnRouteInfo) async -> Void)?
    private var systemPrompt: String?

    init(
        guardrailsMode: AFMGuardrailsMode = .permissiveContentTransformations,
        privateCloudComputeMode: AFMPrivateCloudComputeMode = .smart,
        onToolSummary: (@Sendable (AFMToolExecutionSummary) async -> Void)? = nil,
        onRouteInfo: (@Sendable (AFMTurnRouteInfo) async -> Void)? = nil
    ) {
        self.guardrailsMode = guardrailsMode
        self.privateCloudComputeMode = privateCloudComputeMode
        self.onToolSummary = onToolSummary
        self.onRouteInfo = onRouteInfo
    }

    static func resolvedGuardrailsMode(from settings: ModelSettings?) -> AFMGuardrailsMode {
        // The AFM guardrail is always pinned to the most permissive option. We
        // deliberately ignore any persisted `afmGuardrails` value so that the lax
        // content-transformation guardrails apply to every AFM session — both new
        // installs and anyone updating from an older build that stored `.default`.
        .permissiveContentTransformations
    }

    /// Whether Private Cloud Compute (and therefore its mode selector) is
    /// meaningful for this build + runtime OS. PCC needs the iOS 27 SDK
    /// (Xcode 27 / Swift ≥ 6.3) *and* a device running iOS 27+. On iOS 26 and
    /// below every reply runs on-device regardless of the stored mode, so the
    /// selector is hidden (see `ModelSettingsView`) and the mode resolves to
    /// `.off`.
    static var supportsPrivateCloudCompute: Bool {
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            return true
        }
        #endif
        return false
    }

    static func resolvedPrivateCloudComputeMode(from settings: ModelSettings?) -> AFMPrivateCloudComputeMode {
        // iOS 26 and below can't reach Private Cloud Compute, so AFM stays fully
        // on-device there irrespective of any persisted preference.
        guard supportsPrivateCloudCompute else { return .off }
        return settings?.afmPrivateCloudComputeMode ?? ModelSettings.default(for: .afm).afmPrivateCloudComputeMode
    }

    func load() async throws {
        let availability = AppleFoundationModelAvailability.current
        guard availability.isSupportedDevice else {
            throw AFMLLMClientError.unsupportedDevice
        }
        if let reason = availability.unavailableReason, !availability.isAvailableNow {
            throw AFMLLMClientError.unavailable(reason)
        }

        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            _ = systemSessionBox()
            return
        }
        #endif
        #endif

        throw AFMLLMClientError.frameworkUnavailable
    }

    func syncSystemPrompt(_ prompt: String?) async {
        let trimmed = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if systemPrompt != normalized {
            systemPrompt = normalized
            unload()
        }
    }

    /// The largest prompt budget a turn can currently use: Private Cloud
    /// Compute's 32K window when routing there is possible, otherwise the
    /// on-device window.
    func effectiveContextLimit() -> Int {
        #if canImport(FoundationModels)
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
            if privateCloudComputeMode != .off, !offGrid {
                let pcc = PrivateCloudComputeLanguageModel()
                if pcc.isAvailable, !pcc.quotaUsage.isLimitReached {
                    return 32_768
                }
            }
            return SystemLanguageModel.default.contextSize
        }
        #endif
        #endif
        return 4096
    }

    func textStream(from input: LLMInput) async throws -> AsyncThrowingStream<String, Error> {
        try await load()
        let prompt = renderedPrompt(for: input)
        let imagePaths = Self.imagePaths(from: input)

        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let activeSessionBox = systemSessionBox()
            return AsyncThrowingStream { continuation in
                Task {
                    await activeSessionBox.toolRecorder?.reset()
                    do {
                        try await self.performStreamingRespond(
                            box: activeSessionBox,
                            prompt: prompt,
                            imagePaths: imagePaths,
                            continuation: continuation
                        )
                        continuation.finish()
                    } catch {
                        if let summary = await activeSessionBox.toolRecorder?.drain() {
                            await self.onToolSummary?(summary)
                        }
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        #endif
        #endif

        throw AFMLLMClientError.frameworkUnavailable
    }

    private static func imagePaths(from input: LLMInput) -> [String] {
        switch input.content {
        case .multimodal(_, let paths):
            return paths
        case .multimodalMessages(_, let paths):
            return paths
        case .plain, .messages:
            return []
        }
    }

    func unload() {
        #if canImport(FoundationModels)
        #if os(iOS) || os(macOS) || os(visionOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            clearSystemSession()
        }
        #endif
        #endif
    }

    private func renderedPrompt(for input: LLMInput) -> String {
        switch input.content {
        case .plain(let text):
            return text
        case .messages(let messages):
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        case .multimodal(let text, _):
            return text
        case .multimodalMessages(let messages, _):
            return messages.map { "\($0.role): \($0.content)" }.joined(separator: "\n")
        }
    }

    static func resolvedResponseText<T>(
        response: T,
        transcriptResponseText: String? = nil,
        preferTranscriptFallback: Bool = false
    ) -> String {
        let directText = extractResponseText(response)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !directText.isEmpty {
            return directText
        }

        if preferTranscriptFallback,
           let transcriptResponseText = transcriptResponseText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcriptResponseText.isEmpty {
            return transcriptResponseText
        }

        let fallback = String(describing: response).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? directText : fallback
    }

    private static func extractResponseText<T>(_ response: T) -> String {
        let mirror = Mirror(reflecting: response)
        if let text = mirror.children.first(where: { $0.label == "content" })?.value as? String {
            return text
        }
        return ""
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func systemSessionBox() -> SessionBox {
        let signature = currentSessionSignature()
        if let box = sessionStorage as? SessionBox, box.signature == signature {
            return box
        }

        let toolRecorder = signature.toolAvailability.any ? AFMToolRecorder() : nil
        let tools = userFacingTools(signature: signature, toolRecorder: toolRecorder)

        var routeStateStorage: AnyObject?
        let session: LanguageModelSession
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            // One profile-backed session covers all three PCC modes; the
            // per-turn pre-route decides which branch is active, and the
            // hidden switch tool can flip it mid-turn (baton pass).
            let stateBox = AFMRouteStateBox()
            routeStateStorage = stateBox
            let profile = NoemaAFMRoutingProfile(
                stateBox: stateBox,
                instructions: signature.instructions,
                tools: tools,
                guardrails: mappedGuardrails(for: signature.guardrailsMode)
            )
            session = LanguageModelSession(profile: profile)
        } else {
            session = Self.buildSession(
                model: SystemLanguageModel(guardrails: mappedGuardrails(for: signature.guardrailsMode)),
                tools: tools,
                instructions: signature.instructions
            )
        }
        #else
        session = Self.buildSession(
            model: SystemLanguageModel(guardrails: mappedGuardrails(for: signature.guardrailsMode)),
            tools: tools,
            instructions: signature.instructions
        )
        #endif

        let box = SessionBox(
            session: session,
            signature: signature,
            toolRecorder: toolRecorder,
            routeStateStorage: routeStateStorage
        )
        sessionStorage = box
        return box
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func userFacingTools(signature: SessionSignature, toolRecorder: AFMToolRecorder?) -> [any FoundationModels.Tool] {
        var tools: [any FoundationModels.Tool] = []
        if let toolRecorder {
            if signature.toolAvailability.webSearch {
                tools.append(AFMWebSearchTool(recorder: toolRecorder))
            }
            if signature.toolAvailability.python {
                tools.append(AFMPythonTool(recorder: toolRecorder))
            }
            if signature.toolAvailability.memory {
                tools.append(AFMMemoryTool(recorder: toolRecorder))
            }
        }
        return tools
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func currentSessionSignature() -> SessionSignature {
        let toolAvailability = ToolAvailability.current(currentFormat: .afm)
        return SessionSignature(
            instructions: sessionInstructions(toolAvailability: toolAvailability) ?? "",
            toolAvailability: toolAvailability,
            guardrailsMode: guardrailsMode,
            privateCloudComputeMode: privateCloudComputeMode
        )
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func sessionInstructions(toolAvailability: ToolAvailability) -> String? {
        var merged = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if toolAvailability.any {
            SystemPromptResolver.appendToolGuidance(
                to: &merged,
                availability: toolAvailability,
                includeThinkRestriction: false
            )
        }
        let trimmed = merged.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private static func buildSession(
        model: SystemLanguageModel,
        tools: [any FoundationModels.Tool],
        instructions: String
    ) -> LanguageModelSession {
        switch (tools.isEmpty, instructions.isEmpty) {
        case (true, true):
            return LanguageModelSession(model: model)
        case (true, false):
            return LanguageModelSession(model: model, instructions: instructions)
        case (false, true):
            return LanguageModelSession(model: model, tools: tools)
        case (false, false):
            return LanguageModelSession(model: model, tools: tools, instructions: instructions)
        }
    }

    // MARK: - Streaming

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func performStreamingRespond(
        box: SessionBox,
        prompt: String,
        imagePaths: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
            try await performRoutedStreamingRespond(
                box: box,
                prompt: prompt,
                imagePaths: imagePaths,
                continuation: continuation
            )
            return
        }
        #endif

        var totalEmitted = 0
        let output = try await streamOnce(box: box, prompt: prompt, imagePaths: imagePaths) { delta in
            continuation.yield(delta)
            totalEmitted += delta.count
        }
        await finishStreamingTurn(box: box, output: output, totalEmitted: totalEmitted, continuation: continuation)
    }

    /// Streams one `respond` pass, yielding the growing suffix of the
    /// cumulative snapshot content. Returns the final content.
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func streamOnce(
        box: SessionBox,
        prompt: String,
        imagePaths: [String],
        onDelta: (String) -> Void
    ) async throws -> String {
        let stream: LanguageModelSession.ResponseStream<String>
        #if NOEMA_ENABLE_XCODE27_APIS
        if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *),
           !imagePaths.isEmpty,
           let multimodal = Self.makeMultimodalPrompt(text: prompt, imagePaths: imagePaths) {
            stream = box.session.streamResponse(to: multimodal)
        } else {
            stream = box.session.streamResponse(to: prompt)
        }
        #else
        stream = box.session.streamResponse(to: prompt)
        #endif

        var latest = ""
        var localEmitted = 0
        for try await snapshot in stream {
            if Task.isCancelled { break }
            let content = snapshot.content
            latest = content
            if content.count > localEmitted {
                onDelta(String(content.dropFirst(localEmitted)))
                localEmitted = content.count
            }
        }
        return latest
    }

    /// Drains the tool recorder and, when tools ran but no text was produced,
    /// falls back to the last transcript response (mirrors the pre-streaming
    /// behavior).
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func finishStreamingTurn(
        box: SessionBox,
        output: String,
        totalEmitted: Int,
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async {
        let summary = await box.toolRecorder?.drain()
        if let summary {
            await onToolSummary?(summary)
        }
        if totalEmitted == 0,
           output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           summary?.isEmpty == false,
           let fallbackText = box.lastTranscriptResponseText() {
            continuation.yield(fallbackText)
        }
    }

    #if NOEMA_ENABLE_XCODE27_APIS
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func performRoutedStreamingRespond(
        box: SessionBox,
        prompt: String,
        imagePaths: [String],
        continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        await preRouteTurn(box: box, prompt: prompt)
        let stateBox = box.routeState

        var totalEmitted = 0
        let emitTracked: (String) -> Void = { delta in
            continuation.yield(delta)
            totalEmitted += delta.count
        }

        var output: String
        do {
            output = try await streamOnce(box: box, prompt: prompt, imagePaths: imagePaths, onDelta: emitTracked)
        } catch let error as PrivateCloudComputeLanguageModel.Error {
            // PCC failed (quota/network/service). Finish the turn on-device,
            // once, but only when the user hasn't seen any tokens yet — the
            // PCC branch's `.revertTranscript` rolled the prompt back.
            guard let stateBox, totalEmitted == 0 else { throw error }
            stateBox.noteFallbackToOnDevice()
            output = try await streamOnce(box: box, prompt: prompt, imagePaths: imagePaths, onDelta: emitTracked)
        }

        // Baton-pass contingency: if the on-device model escalated but the
        // turn ended on the switch tool's ack instead of a real answer, nudge
        // the session once — the profile now resolves to the PCC branch with
        // the full transcript.
        if let stateBox, stateBox.escalatedThisTurn, Self.isHandoffAckOnly(output, totalEmitted: totalEmitted) {
            output = try await streamOnce(
                box: box,
                prompt: "Answer the user's last message now.",
                imagePaths: [],
                onDelta: emitTracked
            )
        }

        await finishStreamingTurn(box: box, output: output, totalEmitted: totalEmitted, continuation: continuation)

        if let stateBox {
            let info = stateBox.turnRouteInfo()
            if info.route == .privateCloudCompute || info.escalatedMidTurn || info.fellBackToOnDevice {
                await onRouteInfo?(info)
            }
        }
    }

    /// Gathers the per-turn routing facts and applies the planner's verdict to
    /// the session's route state.
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private func preRouteTurn(box: SessionBox, prompt: String) async {
        guard let stateBox = box.routeState else { return }
        let pcc = PrivateCloudComputeLanguageModel()
        let systemModel = SystemLanguageModel.default
        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        let inputs = AFMRouteInputs(
            mode: privateCloudComputeMode,
            offGrid: offGrid,
            runtimeSupportsPCC: true,
            pccAvailable: pcc.isAvailable,
            pccQuotaExhausted: pcc.quotaUsage.isLimitReached,
            promptTokenEstimate: try? await systemModel.tokenCount(for: prompt),
            onDeviceContextSize: systemModel.contextSize
        )
        stateBox.applyDecision(AFMRoutePlanner.decide(inputs))
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private static func isHandoffAckOnly(_ output: String, totalEmitted: Int) -> Bool {
        guard totalEmitted == 0 else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("Handoff accepted")
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    private static func makeMultimodalPrompt(text: String, imagePaths: [String]) -> Prompt? {
        let images = imagePaths.compactMap { loadCGImage(path: $0) }
        guard !images.isEmpty else { return nil }
        return Prompt {
            for image in images {
                Attachment(image)
            }
            text
        }
    }
    #endif

    private static func loadCGImage(path: String) -> CGImage? {
        #if canImport(UIKit)
        return UIImage(contentsOfFile: path)?.cgImage
        #elseif canImport(AppKit)
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func mappedGuardrails(for mode: AFMGuardrailsMode) -> SystemLanguageModel.Guardrails {
        switch mode {
        case .default:
            return .default
        case .permissiveContentTransformations:
            return .permissiveContentTransformations
        }
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func clearSystemSession() {
        sessionStorage = nil
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private struct SessionSignature: Equatable {
        let instructions: String
        let toolAvailability: ToolAvailability
        let guardrailsMode: AFMGuardrailsMode
        let privateCloudComputeMode: AFMPrivateCloudComputeMode
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private final class SessionBox: @unchecked Sendable {
        let session: LanguageModelSession
        let signature: SessionSignature
        let toolRecorder: AFMToolRecorder?
        /// Type-erased `AFMRouteStateBox` (an iOS 27-only type) so this class
        /// still compiles under the Swift 6.2 toolchain.
        let routeStateStorage: AnyObject?

        init(
            session: LanguageModelSession,
            signature: SessionSignature,
            toolRecorder: AFMToolRecorder?,
            routeStateStorage: AnyObject? = nil
        ) {
            self.session = session
            self.signature = signature
            self.toolRecorder = toolRecorder
            self.routeStateStorage = routeStateStorage
        }

        #if NOEMA_ENABLE_XCODE27_APIS
        @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
        var routeState: AFMRouteStateBox? {
            routeStateStorage as? AFMRouteStateBox
        }
        #endif

        func lastTranscriptResponseText() -> String? {
            for entry in Array(session.transcript).reversed() {
                let mirror = Mirror(reflecting: entry)
                guard let child = mirror.children.first, child.label == "response" else { continue }
                let text = AFMLLMClient.extractResponseText(child.value)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            }
            return nil
        }
    }
    #endif
}
