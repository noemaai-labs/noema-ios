import SwiftUI
import Foundation
import RelayKit
import Combine
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
import NoemaPackages
#if canImport(MLX)
import MLX
#endif

#if canImport(UIKit) || os(macOS)
extension ChatVM {
    static func saturatingTokenAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    func estimateTokensSync(_ text: String) -> Int {
        // Conservative chars-per-token estimate (~3.5). Observed ratios are 4.4–4.9
        // for English text with chat templates, so this intentionally overestimates
        // to ensure preflight trimming catches context overflow before the server rejects.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return max(1, Int(ceil(Double(trimmed.utf8.count) / 3.5)))
    }

    // MARK: - Context budget breakdown (segmented meter)

    /// One segment of the chat context meter. Kept as a value type so the view can
    /// render the segmented bar and the collapsible breakdown from a single snapshot.
    struct ContextBudgetBreakdown: Equatable {
        var messages: Int
        var system: Int
        var tools: Int
        var retrieval: Int
        var images: Int
        var typed: Int
        var reserved: Int
        var usablePromptTokens: Int
        var contextWindow: Int

        /// Everything currently occupying the prompt portion of the window.
        var used: Int { messages + system + tools + retrieval + images + typed }
        /// Window space not yet consumed by the prompt or the response reserve.
        var free: Int { max(0, contextWindow - used - reserved) }
    }

    /// Exact token cost of each tool's wire definition, keyed by registry name. Filled
    /// from the real `ToolSpec`s (the same JSON sent to the model as the `tools` array),
    /// so the meter reflects the actual tool definitions rather than a guess.

    /// Loads the exact per-tool schema token cost once from the generated tool specs.
    /// Cheap after the first run (specs are static for the app session); invalidates the
    /// overhead cache so the meter picks up the real numbers as soon as they arrive.
    private func ensureToolSchemaCostsLoaded() {
        guard !toolSchemaCostsLoaded, !toolSchemaCostsLoading else { return }
        toolSchemaCostsLoading = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let specs = await self.fetchToolSpecs()
            let encoder = JSONEncoder()
            var map: [String: Int] = [:]
            for spec in specs {
                guard let data = try? encoder.encode(spec),
                      let json = String(data: data, encoding: .utf8) else { continue }
                map[spec.function.name] = self.estimateTokensSync(json)
            }
            self.toolSchemaTokenCostByName = map
            self.toolSchemaCostsLoaded = true
            self.toolSchemaCostsLoading = false
            self.promptOverheadCache = nil
        }
    }

    /// Tools that are both armed and actually usable right now. Mirrors the chip
    /// availability logic in the composer so the meter agrees with the toggles.
    private func liveToolKinds() -> Set<String> {
        let isAFM = loadedFormat == .afm
        let store = SettingsStore.shared
        var kinds: Set<String> = []
        if !isAFM && store.webSearchEnabled && store.webSearchArmed { kinds.insert("web") }
        if !isAFM && store.pythonEnabled && store.pythonArmed && PythonRuntime.status().isAvailable { kinds.insert("python") }
        if !isAFM && store.memoryEnabled && activeToolPermissions.memory { kinds.insert("memory") }
        return kinds
    }

    /// Tool kinds the context meter should count: before the first prompt this tracks
    /// the live toggles (so it can go down); once anything has been committed it is the
    /// union of committed and live, so disabling a previously-used tool never subtracts.
    func contextMeterToolKinds() -> Set<String> {
        let committed = activeIndex.flatMap { sessions.indices.contains($0) ? sessions[$0].committedToolKinds : nil } ?? []
        let live = liveToolKinds()
        return committed.isEmpty ? live : committed.union(live)
    }

    /// Latches the tools active at send time into the conversation's committed set so
    /// the meter keeps counting them for the rest of the conversation.
    func commitActiveToolsToContext() {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let live = liveToolKinds()
        guard !live.isEmpty else { return }
        var committed = sessions[idx].committedToolKinds ?? []
        let merged = committed.union(live)
        if merged != committed {
            committed = merged
            sessions[idx].committedToolKinds = committed
            promptOverheadCache = nil
        }
    }

    /// The model's tool availability filtered to the meter's latched kinds. Always-on
    /// tools the backend supports (calculator, unit converter) are kept, since their
    /// schemas are sent regardless of the chat toggles.
    private func meterToolAvailability(for kinds: Set<String>) -> ToolAvailability {
        let raw = systemPromptToolAvailabilityOverride ?? ToolAvailability.current(currentFormat: loadedFormat)
        return ToolAvailability(
            webSearch: raw.webSearch && kinds.contains("web"),
            python: raw.python && kinds.contains("python"),
            memory: raw.memory && kinds.contains("memory"),
            calculator: raw.calculator,
            unitConverter: raw.unitConverter,
            // Always-on on-device tools (master-toggle gated): their guidance is rendered
            // regardless of the meter's latched kinds, so pass them through. This lets the
            // meter's guidanceDelta account for the new in-prompt text. Their SCHEMA cost is
            // still counted separately via globalToolSpecNames(), so no double counting.
            datasetSearch: raw.datasetSearch && !isPDFOnlyDocumentAccess,
            pdfRead: raw.pdfRead,
            chartRender: raw.chartRender,
            calendar: raw.calendar,
            phoneAFriend: raw.phoneAFriend
        )
    }

    private func systemPromptTextForMeter(availability: ToolAvailability) -> String {
        renderSystemPromptText(
            using: activeSessionPromptDataset,
            toolAvailability: availability,
            includeThinkRestriction: activeRemoteBackendID == nil,
            memorySnapshot: nil,
            scratchpadSnapshot: activeTurnScratchpadSnapshot,
            editableIntro: effectiveEditableSystemPromptIntro
        )
    }

    /// Registry names of the tools whose schemas are sent for a given availability.
    private func enabledToolSpecNames(for availability: ToolAvailability) -> [String] {
        var names: [String] = []
        if availability.webSearch { names.append("noema.web.retrieve") }
        if availability.python { names.append("noema.python.execute") }
        if availability.memory { names.append("noema.memory") }
        if availability.calculator { names.append("noema.math.calculate") }
        if availability.unitConverter { names.append("noema.units.convert") }
        return names
    }

    /// The always-available on-device tools (dataset search, PDF, charts, calendar),
    /// each gated by its master toggle. Only counted when the model can call tools.
    private func globalToolSpecNames() -> [String] {
        guard supportsToolsFlag else { return [] }
        // Match the in-prompt gate (SystemPromptResolver.onDeviceToolAvailable): never count
        // on-device tool schemas for a local MLX model or an AFM model, since those have their
        // own tool systems and are not advertised these tools in-prompt. Remote sessions leave
        // loadedFormat nil, so they still count (they receive the schemas via the tools array).
        let isRemote = UserDefaults.standard.object(forKey: "currentModelIsRemote") as? Bool ?? false
        if let f = loadedFormat {
            if f == .mlx && !isRemote { return [] }
            if f == .afm { return [] }
        }
        let store = SettingsStore.shared
        var names: [String] = []
        if store.datasetSearchToolEnabled && !isPDFOnlyDocumentAccess { names.append("noema.rag.search") }
        // Automatic: counted only while the active indexed dataset contains a PDF
        // (matches pdfReadToolAvailability).
        if store.pdfToolEnabled && UserDefaults.standard.bool(forKey: "pdfToolPresent") { names.append("noema.pdf.read") }
        if store.chartToolEnabled { names.append("noema.chart.render") }
        if store.calendarToolEnabled {
            names.append("noema.calendar.events")
            names.append("noema.calendar.addEvent")
        }
        if PhoneAFriendGate.isAvailable() { names.append(PhoneAFriendTool.toolName) }
        return names
    }


    /// Splits the rendered prompt overhead into a stable "System" portion and a latched
    /// "Tools" portion. Tools = the exact tool-schema JSON cost (from the real `ToolSpec`s
    /// sent to the model) plus the measured system-prompt guidance delta. Cached on the
    /// prompt-shaping inputs so it isn't recomputed on every keystroke or streamed token.
    func promptOverheadBreakdown() -> (system: Int, tools: Int) {
        // Nothing is occupying the context window until a local model is resident or a
        // remote backend is connected; skip the (non-trivial) system-prompt render.
        guard modelLoaded || activeRemoteBackendID != nil else { return (0, 0) }
        ensureToolSchemaCostsLoaded()
        let kinds = contextMeterToolKinds()
        let sortedKinds = kinds.sorted().joined(separator: ",")
        let key = [
            sortedKinds,
            activeSessionRetrievalDataset?.datasetID ?? "",
            supportsImageInput ? "v\(pendingImageURLs.count)" : "t",
            loadedFormat?.rawValue ?? "",
            String((effectiveEditableSystemPromptIntro ?? "").hashValue),
            String((activeTurnScratchpadSnapshot ?? "").hashValue),
            activeRemoteBackendID == nil ? "think" : "nothink",
            toolSchemaCostsLoaded ? "schema" : "noschema",
            globalToolSpecNames().joined(separator: ",")
        ].joined(separator: "|")

        if let cache = promptOverheadCache, cache.key == key {
            return (cache.system, cache.tools)
        }

        let availability = meterToolAvailability(for: kinds)
        // System prompt without any tool guidance is the stable base.
        let systemBase = estimateTokensSync(systemPromptTextForMeter(availability: .none))
        // The tool guidance the system prompt gains for the enabled tools.
        let systemWithTools = estimateTokensSync(systemPromptTextForMeter(availability: availability))
        let guidanceDelta = max(0, systemWithTools - systemBase)
        // Exact schema JSON cost for each tool actually sent: the per-session web/python/
        // memory/calculator/units set plus the always-available on-device tools.
        let schemaNames = enabledToolSpecNames(for: availability) + globalToolSpecNames()
        let schemaTokens = schemaNames
            .reduce(0) { $0 + (toolSchemaTokenCostByName[$1] ?? 0) }
        let tools = guidanceDelta + schemaTokens

        promptOverheadCache = (key, systemBase, tools)
        return (systemBase, tools)
    }

    /// Full-conversation message tokens. Uses the server-measured count when available
    /// (assistant turns) and a cheap estimate otherwise, so it stays light even on long
    /// chats and during streaming.
    func conversationCompactionContextTokens(_ state: ConversationCompactionState) -> Int {
        let wrappedRecap = Self.systemPromptByApplyingConversationCompaction("", state: state)
        let estimatedRecapTokens = estimateTokensSync(state.summary)
        let wrapperTokens = max(0, estimateTokensSync(wrappedRecap) - estimatedRecapTokens)
        return Self.saturatingTokenAdd(state.summaryTokenEstimate, wrapperTokens)
    }

    var historyTokenCount: Int {
        let state: ConversationCompactionState? = {
            guard let index = streamSessionIndex ?? activeIndex,
                  sessions.indices.contains(index) else { return nil }
            guard let state = sessions[index].conversationCompaction else { return nil }
            let visibleIDs = Set(streamMsgs.map(\.id))
            return state.coveredMessageIDs.allSatisfy(visibleIDs.contains) ? state : nil
        }()
        let compactedHistory = Self.historyByApplyingConversationCompaction(streamMsgs, state: state)
        let messageTokens = compactedHistory.reduce(0) { total, message in
            // The rendered system prompt is stored as a hidden system message; it is
            // already accounted for by the "system" segment, so don't double-count it.
            guard message.role.lowercased() != "system" else { return total }
            return total + (message.perf?.tokenCount ?? estimateTokensSync(message.text))
        }
        let compactionTokens = state.map(conversationCompactionContextTokens) ?? 0
        return Self.saturatingTokenAdd(messageTokens, compactionTokens)
    }

    /// Assembles the segmented context-meter breakdown. `typedTokens`, `retrievalTokens`
    /// and `imageTokens` are supplied by the composer (it owns the draft text, the live
    /// RAG injection and the pending images).
    func contextBudgetBreakdown(typedTokens: Int, retrievalTokens: Int, imageTokens: Int) -> ContextBudgetBreakdown {
        let budget = Self.promptBudget(for: contextLimit)
        let overhead = promptOverheadBreakdown()
        return ContextBudgetBreakdown(
            messages: historyTokenCount,
            system: overhead.system,
            tools: overhead.tools,
            retrieval: max(0, retrievalTokens),
            images: max(0, imageTokens),
            typed: max(0, typedTokens),
            reserved: budget.reservedResponseTokens,
            usablePromptTokens: budget.usablePromptTokens,
            contextWindow: max(1, Int(contextLimit.rounded()))
        )
    }

    /// Exact token count via the loopback server's `/tokenize` endpoint.
    /// Returns nil when the server is not running or the call fails.
    func tokenCountViaServer(_ text: String) async -> Int? {
        let port = Int(LlamaServerBridge.port())
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/tokenize") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        let body: [String: Any] = ["content": text, "add_special": true, "parse_special": true]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData
        guard !NetworkKillSwitch.shouldBlock(request: req) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        NetworkKillSwitch.track(session: session)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [Any] else { return nil }
        return tokens.count
    }

    var contextLimit: Double {
        if loadedFormat == .afm {
            return Double(activeAFMClient?.effectiveContextLimit() ?? AFMLLMClient.onDeviceContextLimit())
        }
        return loadedSettings?.contextLength ?? 4096
    }
    var contextOverflowStrategy: ContextOverflowStrategy {
        ContextOverflowStrategy.from(contextOverflowStrategyRaw)
    }

    var contextOverflowAlertBody: String {
        guard let banner = contextOverflowBanner else {
            return String(localized: "The model context window was exceeded.")
        }
        var lines: [String] = [NSLocalizedString(banner.strategy.overflowActionKey, comment: "")]
        if let promptTokens = banner.promptTokens, let contextTokens = banner.contextTokens {
            let promptString = NumberFormatter.localizedString(from: NSNumber(value: promptTokens), number: .decimal)
            let contextString = NumberFormatter.localizedString(from: NSNumber(value: contextTokens), number: .decimal)
            let tokenLine = String.localizedStringWithFormat(
                String(localized: "Prompt tokens: %@ • Context limit: %@."),
                promptString,
                contextString
            )
            lines.append(tokenLine)
        } else if let contextTokens = banner.contextTokens {
            let contextString = NumberFormatter.localizedString(from: NSNumber(value: contextTokens), number: .decimal)
            let tokenLine = String.localizedStringWithFormat(
                String(localized: "Context limit: %@ tokens."),
                contextString
            )
            lines.append(tokenLine)
        }
        lines.append(NSLocalizedString(banner.strategy.overflowDeteriorationKey, comment: ""))
        return lines.joined(separator: "\n\n")
    }

    func contextOverflowBanner(for sessionID: Session.ID) -> ContextOverflowBannerState? {
        contextOverflowBanners[sessionID]
    }

    func registerContextOverflowForTesting(
        strategy: ContextOverflowStrategy = .stopAtLimit,
        promptTokens: Int? = nil,
        contextTokens: Int? = nil,
        rawMessage: String = "test-overflow"
    ) {
        let details = ContextOverflowDetails(
            promptTokens: promptTokens,
            contextTokens: contextTokens,
            rawMessage: rawMessage
        )
        registerContextOverflow(strategy: strategy, details: details)
    }

    private var currentStreamOrActiveSessionID: Session.ID? {
        if let streamSessionIndex, sessions.indices.contains(streamSessionIndex) {
            return sessions[streamSessionIndex].id
        }
        return activeSessionID
    }

    func registerContextOverflow(strategy: ContextOverflowStrategy, details: ContextOverflowDetails?) {
        guard let sessionID = currentStreamOrActiveSessionID else { return }
        let fallbackContext = currentPromptBudget().usablePromptTokens
        var banners = contextOverflowBanners
        banners[sessionID] = ContextOverflowBannerState(
            strategy: strategy,
            promptTokens: details?.promptTokens,
            contextTokens: details?.contextTokens ?? fallbackContext,
            timestamp: Date()
        )
        contextOverflowBanners = banners
    }

    /// Drop the overflow pill once a turn fits within the budget again, so it
    /// always reflects the most recent send rather than sticking forever.
    func clearContextOverflowForCurrentStream() {
        guard let sessionID = currentStreamOrActiveSessionID,
              contextOverflowBanners[sessionID] != nil else { return }
        var banners = contextOverflowBanners
        banners.removeValue(forKey: sessionID)
        contextOverflowBanners = banners
    }

    /// User-initiated dismissal from the status pill.
    func dismissActiveContextOverflowBanner() {
        guard let sessionID = activeSessionID,
              contextOverflowBanners[sessionID] != nil else { return }
        var banners = contextOverflowBanners
        banners.removeValue(forKey: sessionID)
        contextOverflowBanners = banners
    }

    func contextStopMessage(details: ContextOverflowDetails?) -> String {
        if let promptTokens = details?.promptTokens, let contextTokens = details?.contextTokens {
            let promptString = NumberFormatter.localizedString(from: NSNumber(value: promptTokens), number: .decimal)
            let contextString = NumberFormatter.localizedString(from: NSNumber(value: contextTokens), number: .decimal)
            return String.localizedStringWithFormat(
                String(localized: "Context Length Exceeded (%@ > %@ tokens). Stop at Limit is enabled, so this turn was not sent."),
                promptString,
                contextString
            )
        }
        return String(localized: "Context Length Exceeded. Stop at Limit is enabled, so this turn was not sent.")
    }

    func contextFallbackMessage(for strategy: ContextOverflowStrategy) -> String {
        switch strategy {
        case .truncateMiddle:
            return String(localized: "Context Length Exceeded. Middle turns were trimmed, but the prompt is still too large. Increase context length or shorten this chat.")
        case .rollingWindow:
            return String(localized: "Context Length Exceeded. Older turns were trimmed, but the prompt is still too large. Increase context length or shorten this chat.")
        case .stopAtLimit:
            return String(localized: "Context Length Exceeded. Stop at Limit is enabled, so generation was halted before sending.")
        }
    }

    private func extractFirstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        let tokenRange = match.range(at: 1)
        guard tokenRange.location != NSNotFound else { return nil }
        return Int(nsText.substring(with: tokenRange))
    }

    func parseContextOverflowDetails(from message: String) -> ContextOverflowDetails? {
        let lower = message.lowercased()
        let looksLikeOverflow = lower.contains("exceed_context_size_error")
            || (lower.contains("context") && lower.contains("exceed"))
            || lower.contains("available context size")
            // Multimodal prompt overflow: "input (N tokens) is larger than the max context size (M tokens)"
            || lower.contains("larger than the max context size")
        guard looksLikeOverflow else { return nil }

        let promptTokens =
            extractFirstInt(in: message, pattern: #""n_prompt_tokens"\s*:\s*(\d+)"#)
            ?? extractFirstInt(in: message, pattern: #"request\s*\((\d+)\s*tokens\)"#)
            ?? extractFirstInt(in: message, pattern: #"input\s*\((\d+)\s*tokens\)"#)
        let contextTokens =
            extractFirstInt(in: message, pattern: #""n_ctx"\s*:\s*(\d+)"#)
            ?? extractFirstInt(in: message, pattern: #"context size\s*\((\d+)\s*tokens\)"#)

        return ContextOverflowDetails(promptTokens: promptTokens, contextTokens: contextTokens, rawMessage: message)
    }

    private func renderedPromptForEstimation(history: [Msg], systemPrompt: String) -> String {
        if loadedFormat == .et {
            // ExecuTorch transmits only the newest turn during normal sends,
            // but every earlier turn is still resident in its KV cache. Estimate
            // the complete reconstructed conversation so compaction triggers on
            // actual cache occupancy rather than only the latest message.
            return PromptBuilder.build(
                template: promptTemplate,
                family: currentKind,
                history: historyWithReconstructedToolMessages(history),
                system: systemPrompt
            ).0
        }

        // Match the reconstructed tool messages used when actually building the
        // request so the token estimate doesn't undercount the replayed results.
        let rendered = prepareForGeneration(
            messages: historyWithReconstructedToolMessages(history),
            system: systemPrompt
        )
        switch rendered {
        case .plain(let prompt):
            return prompt
        case .messages(let arr):
            let msgs: [ChatVM.Msg] = arr.map { ChatVM.Msg(role: $0.role, text: $0.content) }
            let (prompt, _, _) = PromptBuilder.build(template: promptTemplate, family: currentKind, messages: msgs)
            return prompt
        }
    }

    func estimatedPromptTokens(for history: [Msg]) -> Int {
        estimateTokensSync(renderedPromptForEstimation(history: history, systemPrompt: systemPromptText))
    }

    func estimatedPromptTokens(for history: [Msg], systemPrompt: String) -> Int {
        estimateTokensSync(renderedPromptForEstimation(history: history, systemPrompt: systemPrompt))
    }

    func contextSoftLimitTokens() -> Int {
        currentPromptBudget().usablePromptTokens
    }

    func removableHistoryTurnRanges(
        for history: [Msg],
        excludingMessageIDs: Set<UUID> = []
    ) -> [Range<Int>] {
        Self.completeConversationTurns(
            in: history,
            excluding: excludingMessageIDs
        ).map(\.range)
    }

    /// Last-resort trim when no whole message can be removed (e.g. a single
    /// pasted document larger than the context window): shrink the largest
    /// trimmable message body in place, honoring the strategy — rolling window
    /// keeps the tail, truncate-middle keeps head + tail. Returns false when
    /// nothing useful can be shrunk further.
    func shrinkOversizedMessageForContext(
        _ history: inout [Msg],
        strategy: ContextOverflowStrategy,
        promptTokens: Int,
        tokenLimit: Int,
        preservingMessageIDs: Set<UUID> = []
    ) -> Bool {
        guard promptTokens > tokenLimit else { return false }
        let newestUserIndex = history.lastIndex(where: { message in
            let role = message.role.lowercased()
            return role == "user" || role == "🧑‍💻"
        })
        let shrinkableIndices = history.indices.filter { idx in
            let role = history[idx].role.lowercased()
            if role == "system" { return false }
            if preservingMessageIDs.contains(history[idx].id) { return false }
            // The user's current request is the one part of the turn that must
            // never be silently rewritten. If it cannot fit, surface a clear
            // error and let the user shorten it deliberately.
            if idx == newestUserIndex { return false }
            if history[idx].role == "🤖" && history[idx].streaming { return false }
            return !history[idx].text.isEmpty
        }
        guard let idx = shrinkableIndices.max(by: { history[$0].text.count < history[$1].text.count }) else {
            return false
        }
        let text = history[idx].text
        // Scale the text down proportionally to the overage, with a safety margin.
        let ratio = max(0.05, min(0.85, (Double(tokenLimit) / Double(promptTokens)) * 0.85))
        let targetCount = Int(Double(text.count) * ratio)
        // Below this size shrinking just destroys the message without fixing anything.
        guard targetCount >= 160, targetCount < text.count else { return false }
        let marker = "\n[… trimmed to fit the context window …]\n"
        switch strategy {
        case .rollingWindow:
            history[idx].text = marker + String(text.suffix(targetCount))
        case .truncateMiddle, .stopAtLimit:
            let head = targetCount / 2
            let tail = targetCount - head
            history[idx].text = String(text.prefix(head)) + marker + String(text.suffix(tail))
        }
        return true
    }

    func planHistoryForContextOverflow(
        history: [Msg],
        systemPrompt: String? = nil,
        protectingTurnMessageIDs: Set<UUID> = [],
        preservingMessageIDs: Set<UUID> = []
    ) -> ContextHistoryPlan {
        let limit = contextSoftLimitTokens()
        let strategy = contextOverflowStrategy
        let effectiveSystemPrompt = systemPrompt ?? systemPromptText
        let initialEstimate = estimatedPromptTokens(for: history, systemPrompt: effectiveSystemPrompt)

        guard initialEstimate > limit else {
            return ContextHistoryPlan(
                history: history,
                initialEstimate: initialEstimate,
                finalEstimate: initialEstimate,
                trimmed: false,
                requiresStop: false
            )
        }

        if strategy == .stopAtLimit {
            return ContextHistoryPlan(
                history: history,
                initialEstimate: initialEstimate,
                finalEstimate: initialEstimate,
                trimmed: false,
                requiresStop: true
            )
        }

        var working = history
        var finalEstimate = initialEstimate
        var trimmed = false
        var iterations = 0
        while finalEstimate > limit, iterations < 256 {
            let candidates = removableHistoryTurnRanges(
                for: working,
                excludingMessageIDs: protectingTurnMessageIDs
            )
            if !candidates.isEmpty {
                let removalRange: Range<Int>
                switch strategy {
                case .truncateMiddle:
                    removalRange = candidates[candidates.count / 2]
                case .rollingWindow:
                    removalRange = candidates[0]
                case .stopAtLimit:
                    removalRange = candidates[0]
                }
                working.removeSubrange(removalRange)
            } else if !shrinkOversizedMessageForContext(
                &working,
                strategy: strategy,
                promptTokens: finalEstimate,
                tokenLimit: limit,
                preservingMessageIDs: preservingMessageIDs
            ) {
                break
            }
            trimmed = true
            finalEstimate = estimatedPromptTokens(for: working, systemPrompt: effectiveSystemPrompt)
            iterations += 1
        }

        return ContextHistoryPlan(
            history: working,
            initialEstimate: initialEstimate,
            finalEstimate: finalEstimate,
            trimmed: trimmed,
            requiresStop: finalEstimate > limit
        )
    }

    /// Starts a persisted transcript receipt at the current visible answer
    /// boundary before the fresh continuation prompt is prepared.
    @MainActor
    @discardableResult
    func beginAutomaticOutputContinuation(
        messageIndex: Int,
        visibleText: String
    ) -> UUID? {
        guard streamMsgs.indices.contains(messageIndex) else { return nil }
        let event = Msg.OutputContinuationEvent(
            visibleCharacterOffset: visibleText.count,
            contextStrategyRaw: contextOverflowStrategy.rawValue
        )
        var messages = streamMsgs
        var events = messages[messageIndex].outputContinuationEvents ?? []
        events.append(event)
        messages[messageIndex].outputContinuationEvents = events
        streamMsgs = messages
        AccessibilityAnnouncer.announceLocalized(
            "Making room to continue. No action is needed; the response will resume automatically."
        )
        return event.id
    }

    @MainActor
    func resolveAutomaticOutputContinuation(
        messageIndex: Int,
        eventID: UUID,
        phase: Msg.OutputContinuationEvent.Phase
    ) {
        guard streamMsgs.indices.contains(messageIndex),
              var events = streamMsgs[messageIndex].outputContinuationEvents,
              let eventIndex = events.firstIndex(where: { $0.id == eventID }) else {
            return
        }
        guard events[eventIndex].phase == .preparing else { return }
        events[eventIndex].phase = phase
        events[eventIndex].completedAt = Date()
        var messages = streamMsgs
        messages[messageIndex].outputContinuationEvents = events
        streamMsgs = messages
    }

    @MainActor
    func resolvePreparingOutputContinuationsAsUnavailable(messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex),
              var events = streamMsgs[messageIndex].outputContinuationEvents else {
            return
        }
        var changed = false
        let now = Date()
        for index in events.indices where events[index].phase == .preparing {
            events[index].phase = .unavailable
            events[index].completedAt = now
            changed = true
        }
        guard changed else { return }
        var messages = streamMsgs
        messages[messageIndex].outputContinuationEvents = events
        streamMsgs = messages
    }

    /// Builds a model-only continuation turn after a backend reports that it
    /// stopped for length. The visible transcript remains one assistant bubble.
    /// Earlier complete turns may be removed according to the selected overflow
    /// strategy, while the original request is preserved verbatim and only
    /// the tail of the visible partial answer is replayed. Hidden reasoning
    /// is never fed back into the model for a continuation pass.
    func planAutomaticOutputContinuation(
        history: [Msg],
        assistantMessageID: UUID,
        partialAssistantText: String,
        systemPrompt: String
    ) -> ContextHistoryPlan? {
        guard contextOverflowStrategy != .stopAtLimit,
              let assistantIndex = history.firstIndex(where: { $0.id == assistantMessageID }) else {
            return nil
        }

        let sourceUserIndex = history[..<assistantIndex].lastIndex { message in
            let role = message.role.lowercased()
            return role == "user" || role == "🧑‍💻"
        }
        guard let sourceUserIndex else { return nil }

        var replayAssistantText = AssistantOutputSanitizer.strippingReasoningBlocks(
            from: visibleAssistantText(from: partialAssistantText)
        )
        if replayAssistantText.isEmpty {
            replayAssistantText = "[No user-visible answer was emitted before the context limit.]"
        }
        // A continuation needs the local wording at the cut point, not the
        // complete answer prefix. Keeping roughly one third of the usable prompt
        // for this checkpoint leaves meaningful decode room even at 1.5K context.
        let replayTokenTarget = max(128, min(384, currentPromptBudget().usablePromptTokens / 3))
        let replayCharacterLimit = max(480, replayTokenTarget * 3)
        if replayAssistantText.count > replayCharacterLimit {
            replayAssistantText = "[… earlier response already shown …]\n" + String(
                replayAssistantText.suffix(replayCharacterLimit)
            )
        }

        var continuationHistory = history
        continuationHistory[assistantIndex].text = replayAssistantText
        continuationHistory[assistantIndex].streaming = false

        let instruction = Msg(
            role: "user",
            text: "Continue the assistant response after the replayed checkpoint. Start with the first new sentence. Do not repeat the checkpoint text or its final heading. Do not call tools, add hidden reasoning, or mention this continuation. Give only the remaining final answer and finish it concisely.",
            timestamp: Date()
        )
        continuationHistory.append(instruction)

        return planHistoryForContextOverflow(
            history: continuationHistory,
            systemPrompt: systemPrompt,
            protectingTurnMessageIDs: [
                continuationHistory[sourceUserIndex].id,
                continuationHistory[assistantIndex].id
            ],
            preservingMessageIDs: [
                continuationHistory[sourceUserIndex].id,
                instruction.id
            ]
        )
    }
}
#endif
