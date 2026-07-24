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

#if canImport(UIKit) || os(macOS)
// Utility helpers used by `ChatVM`.
extension ChatVM {
    // Inserts image placeholder tokens into the current template's latest user section so BOS/control tokens remain valid.
    // If the template isn't recognized, it falls back to prefixing simple placeholders at the beginning.
    private func injectImagesIntoPrompt(original: String, imageCount: Int, kind: ModelKind) -> String {
        guard imageCount > 0 else { return original }
        let s = original
        let tmpl = templateKind() ?? kind
        func placeholders(chatml: Bool) -> String {
            let token = chatml ? "<|image|>\n" : "<image>\n"
            return String(repeating: token, count: max(1, imageCount))
        }
        switch tmpl {
        case .llama3:
            // <|start_header_id|>user<|end_header_id|> ... <|eot_id|>
            let userOpen = "<|start_header_id|>user<|end_header_id|>\n"
            let eot = "<|eot_id|>"
            if let open = s.range(of: userOpen), let close = s.range(of: eot, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        case .gemma, .qwen, .smol, .lfm:
            // ChatML-style or Gemma turn: <|im_start|>user\n ... <|im_end|>
            let userOpen = "<|im_start|>user\n"
            let userClose = "<|im_end|>"
            if let open = s.range(of: userOpen, options: .backwards), let close = s.range(of: userClose, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: placeholders(chatml: true), at: close.lowerBound)
                return out
            }
            // Gemma-turn variant: <start_of_turn>user\n ... <end_of_turn>
            let gOpen = "<start_of_turn>user\n"
            let gClose = "<end_of_turn>"
            if let open = s.range(of: gOpen, options: .backwards), let close = s.range(of: gClose, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        case .mistral:
            // [INST] ... [/INST]
            let openTag = "[INST]"
            let closeTag = "[/INST]"
            if let open = s.range(of: openTag, options: .backwards), let close = s.range(of: closeTag, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: "\n" + placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        case .phi:
            // <|user|> ... <|assistant|>
            let uOpen = "<|user|>"
            let aOpen = "<|assistant|>"
            if let open = s.range(of: uOpen, options: .backwards), let close = s.range(of: aOpen, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: "\n" + placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        default:
            break
        }
        // Fallback: prefix placeholders
        return placeholders(chatml: false) + s
    }
    static func metalQuant(from url: URL) -> String? {
        let name = url.lastPathComponent
        if let r = name.range(of: #"q[0-9][A-Za-z0-9_]*"#, options: .regularExpression) {
            return String(name[r])
        }
        return nil
    }
    func templateKind() -> ModelKind? {
        guard let t = promptTemplate?.lowercased() else { return nil }
        if t.contains("<|begin_of_text|>") { return .llama3 }
        if t.contains("[inst]") { return .mistral }
        if t.contains("<|startoftext|>") { return .lfm }
        if t.contains("<|im_start|>") {
            if currentKind == .gemma { return .gemma }
            if currentKind == .lfm { return .lfm }
            // Smol and Qwen both serialize with ChatML tokens by default
            if currentKind == .smol { return .smol }
            if currentKind == .internlm { return .internlm }
            if currentKind == .yi { return .yi }
            return .qwen
        }
        // DeepSeek may use distinct BOS and role tags; detect via placeholders if present
        if (t.contains("<|user|>") && t.contains("<|assistant|>")) ||
           (t.contains("<｜user｜>") && t.contains("<｜assistant｜>")) ||
            t.contains("<｜begin▁of▁sentence｜>") {
            return .deepseek
        }
        if t.contains("<|system|>") { return .phi }
        return nil
    }

    /// Builds a prompt for the underlying model from a message history.
    /// Example: Gemma single turn history `["Hi"]` → prompt ends with
    /// "<|im_start|>assistant\n" and user sees no control tokens.
    func buildPrompt(kind: ModelKind, history: [ChatVM.Msg], systemPromptOverride: String? = nil) -> (String, [String], Int?) {
        // Use the unified formatter to prepare messages vs plain prompt
        let cfMessages: [ChatFormatter.Message] = history.map { m in
            let roleLower = m.role.lowercased()
            let normalizedRole: String
            if roleLower == "🧑‍💻".lowercased() { normalizedRole = "user" }
            else if roleLower == "🤖".lowercased() { normalizedRole = "assistant" }
            else { normalizedRole = roleLower }
            return ChatFormatter.Message(role: normalizedRole, content: m.text)
        }
        let systemPrompt = systemPromptOverride ?? systemPromptText
        Task {
            await logger.log(Self.systemPromptMetadataSummary(systemPrompt))
        }
        // Replay tool results from history so completion-style prompts keep the
        // tool call + result in context (mirrors the structured loopback path).
        let rendered = prepareForGeneration(
            messages: historyWithReconstructedToolMessages(history),
            system: systemPrompt
        )
        switch rendered {
        case .messages(let arr):
            // Convert back to ChatVM.Msg for our renderer
            let msgs: [ChatVM.Msg] = arr.map { ChatVM.Msg(role: $0.role, text: $0.content) }
            return PromptBuilder.build(template: promptTemplate, family: kind, messages: msgs)
        case .plain(let s):
            // Let caller pick default stops; provide generous token budget
            return (s, [], nil)
        }
    }

    /// New unified chat preparation that returns either a messages array (for chat-aware backends)
    /// or a single plain prompt string for completion-style backends.
    func prepareForGeneration(messages: [ChatVM.Msg], system: String) -> ChatFormatter.RenderedPrompt {
        let modelId: String = loadedURL?.lastPathComponent ?? "unknown"
        var cf = ChatFormatter.shared
        let family = currentKind

        // Convert to ChatFormatter.Message list (preserve order and roles)
        let msgs: [ChatFormatter.Message] = messages.map { m in
            ChatFormatter.Message(role: m.role.lowercased() == "🧑‍💻".lowercased() ? "user" : (m.role.lowercased() == "🤖".lowercased() ? "assistant" : m.role.lowercased()), content: m.text)
        }

        let rendered = cf.prepareForGeneration(
            modelId: modelId,
            template: promptTemplate,
            family: family,
            messages: msgs,
            system: system
        )

        // Runtime validation: ensure system content appears before first user span
        func validate(_ prompt: String, sys: String) -> Bool {
            let s = sys.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            let lower = prompt.lowercased()
            let sysIdx = lower.range(of: s.lowercased())?.lowerBound
            let userIdx = lower.range(of: "user:")?.lowerBound
            if let sysIdx, let userIdx { return sysIdx < userIdx }
            return sysIdx != nil
        }

        switch rendered {
        case .messages(let arr):
            // Cheap join to validate order without changing the authoritative structure
            let flat = arr.map { "\($0.role.capitalized): \($0.content)" }.joined(separator: "\n")
            if !validate(flat, sys: system) {
                Task { await logger.log("[Warn][Prompt] System text missing after render; model=\(modelId) hash=\(system.hashValue)") }
                // Conservative fallback: re-render via inline-first-user path
                var cf2 = ChatFormatter.shared
                let re = cf2.prepareForGeneration(
                    modelId: modelId,
                    template: promptTemplate,
                    family: family,
                    messages: arr.map { ChatFormatter.Message(role: $0.role, content: $0.content) },
                    system: system,
                    forceInlineWhenTemplatePresent: true
                )
                return re
            }
            return .messages(arr)
        case .plain(let s):
            if !validate(s, sys: system) {
                Task { await logger.log("[Warn][Prompt] System text missing in plain render; model=\(modelId) hash=\(system.hashValue)") }
                // For plain, prepend explicitly
                let fixed = "System: " + system + "\n\n" + s
                return .plain(fixed)
            }
            return .plain(s)
        }
    }

    /// Removes any model specific control tokens from the raw output.
    func cleanOutput(_ raw: String, kind: ModelKind) -> String {
        var t = raw
        let tmplKind = templateKind() ?? kind
        switch tmplKind {
        case .gemma, .qwen, .smol, .lfm:
            if tmplKind == .gemma && gemmaAutoTemplated {
                t = t.replacingOccurrences(of: "<start_of_turn>model", with: "")
                t = t.replacingOccurrences(of: "<start_of_turn>user", with: "")
                t = t.replacingOccurrences(of: "<start_of_turn>system", with: "")
                t = t.replacingOccurrences(of: "<end_of_turn>", with: "")
                t = t.replacingOccurrences(of: "<bos>", with: "")
                t = t.replacingOccurrences(of: "<eos>", with: "")
            } else {
                t = t.replacingOccurrences(of: "<|im_start|>assistant", with: "")
                t = t.replacingOccurrences(of: "<|im_start|>user", with: "")
                t = t.replacingOccurrences(of: "<|im_end|>", with: "")
                t = t.replacingOccurrences(of: "<\\|im_.*?\\|>\n?", with: "", options: .regularExpression)
            }
        case .internlm:
            // ChatML-like tokens
            t = t.replacingOccurrences(of: "<|im_start|>assistant", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>user", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>system", with: "")
            t = t.replacingOccurrences(of: "<|im_end|>", with: "")
        case .yi:
            t = t.replacingOccurrences(of: "<|startoftext|>", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>assistant", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>user", with: "")
            t = t.replacingOccurrences(of: "<|im_end|>", with: "")
        case .deepseek:
            // Remove DeepSeek control tokens (canonical fullwidth; also strip legacy/ascii variants)
            t = t.replacingOccurrences(of: "<｜begin▁of▁sentence｜>", with: "")
            t = t.replacingOccurrences(of: "<｜User｜>", with: "")
            t = t.replacingOccurrences(of: "<｜Assistant｜>", with: "")
            // Legacy/weird variants (left in for robustness)
            t = t.replacingOccurrences(of: "<攼 begin▁of▁sentence放>", with: "")
            t = t.replacingOccurrences(of: "<|User|>", with: "")
            t = t.replacingOccurrences(of: "<|Assistant|>", with: "")
        case .llama3:
            t = t.replacingOccurrences(of: "<|begin_of_text|>", with: "")
            t = t.replacingOccurrences(of: "<|start_header_id|>", with: "")
            t = t.replacingOccurrences(of: "<|end_header_id|>", with: "")
            t = t.replacingOccurrences(of: "<|eot_id|>", with: "")
            t = t.replacingOccurrences(of: "<\\|.*?\\|>", with: "", options: .regularExpression)
        case .mistral:
            t = t.replacingOccurrences(of: "<s>", with: "")
            t = t.replacingOccurrences(of: "</s>", with: "")
            t = t.replacingOccurrences(of: "[INST]", with: "")
            t = t.replacingOccurrences(of: "[/INST]", with: "")
        case .phi:
            t = t.replacingOccurrences(of: "<|system|>", with: "")
            t = t.replacingOccurrences(of: "<|user|>", with: "")
            t = t.replacingOccurrences(of: "<|assistant|>", with: "")
            t = t.replacingOccurrences(of: "<|end|>", with: "")
        default:
            t = t.replacingOccurrences(of: "System:", with: "")
            t = t.replacingOccurrences(of: "User:", with: "")
            if t.hasPrefix("Assistant:") {
                t = String(t.dropFirst("Assistant:".count))
            }
        }
        return AssistantOutputSanitizer
            .strippingTrailingControlMarkers(from: t)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into `.text` and `.code` pieces based on fenced triple backticks.
    /// Recognizes optional language hints immediately following the opening ```.
    static func parseCodeBlocks(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var currentText = ""
        let lines = text.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                if !currentText.isEmpty {
                    pieces.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }

                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }

                if !codeLines.isEmpty {
                    let code = codeLines.joined(separator: "\n")
                    pieces.append(.code(code, language: lang.isEmpty ? nil : lang))
                }
            } else {
                currentText += (currentText.isEmpty ? "" : "\n") + line
            }
            i += 1
        }

        if !currentText.isEmpty {
            pieces.append(.text(currentText.trimmingCharacters(in: .newlines)))
        }

        return pieces
    }

    // Build the model-facing prompt without changing the visible chat bubble text.
    nonisolated static func promptText(userText: String, mediaAttachments: [ChatMediaAttachment]) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeTimestamps = TranscriptionSettings.includesTimestampsInPrompt
        let transcriptBlocks = mediaAttachments.compactMap { $0.promptBlock(includeTimestamps: includeTimestamps) }
        guard !transcriptBlocks.isEmpty else { return trimmed }

        var parts: [String] = []
        if !trimmed.isEmpty {
            parts.append(trimmed)
        } else {
            parts.append(String(localized: "Use the attached transcript to answer."))
        }
        parts.append(transcriptBlocks.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    nonisolated static func modelFacingHistory(visibleHistory: [Msg], modelInput: String) -> [Msg] {
        var history = visibleHistory
        if let userIndex = history.indices.dropLast().last(where: { history[$0].role == "🧑‍💻" }) {
            history[userIndex].text = modelInput
        }
        return history
    }

    /// Shows automatic document access once per document/model pairing. Full-document
    /// context remains attached to later turns for prompt rebuilding and cache reuse, but
    /// repeating its receipt would imply that Noema had supplied the document again.
    nonisolated static func shouldShowDocumentAccessReceipt(for message: Msg, in history: [Msg]) -> Bool {
        guard message.documentAccessDecision != nil || message.ragInjectionInfo != nil else {
            return false
        }
        guard let messageIndex = history.firstIndex(where: { $0.id == message.id }) else {
            return true
        }

        let usesAutomaticContext = message.documentAccessDecision?.effectiveStrategy.usesAutomaticContext
            ?? (message.ragInjectionInfo != nil)
        guard usesAutomaticContext else { return true }

        // A new semantic retrieval is a real per-turn event and should always be visible,
        // even when the same dataset previously fit as full-document context.
        if message.ragInjectionInfo?.method == .rag {
            return true
        }

        let currentDocument = documentReceiptIdentity(at: messageIndex, in: history)
        let currentModel = documentReceiptModelIdentity(for: message)

        for priorIndex in history.indices where priorIndex < messageIndex {
            let prior = history[priorIndex]
            guard prior.ragInjectionInfo?.stage == .injected,
                  prior.ragInjectionInfo?.method == .fullContent,
                  documentReceiptIdentity(at: priorIndex, in: history).matches(currentDocument),
                  documentReceiptModelsMatch(currentModel, documentReceiptModelIdentity(for: prior)) else {
                continue
            }
            return false
        }
        return true
    }

    /// A one-time, model-facing context transition that is distinct from conversation
    /// compaction. It is emitted only when the same dataset was fully resident on the
    /// preceding document-access turn and the current turn settled on semantic retrieval.
    nonisolated struct DocumentContextTransitionReceipt: Equatable {
        let datasetName: String
        let fullDocumentTokens: Int
        let configuredContextTokens: Int
        let reservedResponseTokens: Int
        let retrievedContextTokens: Int
    }

    nonisolated static func documentContextTransitionReceipt(
        for message: Msg,
        in history: [Msg]
    ) -> DocumentContextTransitionReceipt? {
        guard let messageIndex = history.firstIndex(where: { $0.id == message.id }),
              let currentInfo = message.ragInjectionInfo,
              currentInfo.stage == .injected,
              currentInfo.method == .rag,
              let fullDocumentTokens = currentInfo.fullContentEstimateTokens,
              fullDocumentTokens > 0 else {
            return nil
        }

        let currentDocument = documentReceiptIdentity(at: messageIndex, in: history)
        var priorDocumentAccess: Msg.RAGInjectionInfo?

        for priorIndex in history.indices.reversed() where priorIndex < messageIndex {
            let prior = history[priorIndex]
            guard let priorInfo = prior.ragInjectionInfo,
                  priorInfo.stage == .injected,
                  documentReceiptIdentity(at: priorIndex, in: history).matches(currentDocument) else {
                continue
            }
            priorDocumentAccess = priorInfo
            break
        }

        // Looking only at the most recent access event makes this a transition receipt,
        // rather than a receipt that repeats on every subsequent retrieval turn.
        guard priorDocumentAccess?.method == .fullContent else { return nil }

        return DocumentContextTransitionReceipt(
            datasetName: currentInfo.datasetName,
            fullDocumentTokens: fullDocumentTokens,
            configuredContextTokens: currentInfo.configuredContextTokens,
            reservedResponseTokens: currentInfo.reservedResponseTokens,
            retrievedContextTokens: currentInfo.injectedContextTokens
        )
    }

    private nonisolated struct DocumentReceiptIdentity {
        let datasetID: String?
        let datasetName: String?

        func matches(_ other: Self) -> Bool {
            if let datasetID, let otherID = other.datasetID {
                return datasetID == otherID
            }
            guard let datasetName, let otherName = other.datasetName else { return false }
            return datasetName.caseInsensitiveCompare(otherName) == .orderedSame
        }
    }

    private nonisolated static func documentReceiptIdentity(at index: Int, in history: [Msg]) -> DocumentReceiptIdentity {
        let message = history[index]
        var datasetID = message.datasetID?.trimmingCharacters(in: .whitespacesAndNewlines)
        var datasetName = message.documentAccessDecision?.datasetName
            ?? message.ragInjectionInfo?.datasetName
            ?? message.datasetName

        // Assistant receipts do not duplicate the dataset ID. The immediately preceding
        // user turn carries the send-time dataset snapshot, which avoids conflating two
        // separately imported datasets that happen to share a display name.
        if message.role != "🧑‍💻" {
            for priorIndex in history.indices.reversed() where priorIndex < index {
                let prior = history[priorIndex]
                guard prior.role == "🧑‍💻" else { continue }
                if datasetID?.isEmpty != false {
                    datasetID = prior.datasetID?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if datasetName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    datasetName = prior.datasetName
                }
                break
            }
        }

        let normalizedID = normalizedDocumentReceiptValue(datasetID)
        let normalizedName = normalizedDocumentReceiptValue(datasetName)
        return DocumentReceiptIdentity(datasetID: normalizedID, datasetName: normalizedName)
    }

    private nonisolated static func documentReceiptModelIdentity(for message: Msg) -> String? {
        if message.ranOnPrivateCloudCompute == true {
            return "pcc|" + (normalizedDocumentReceiptValue(message.remoteModelName) ?? "unknown")
        }
        if message.usedRemoteBackend == true {
            return "remote|" + (normalizedDocumentReceiptValue(message.remoteBackendName) ?? "unknown")
                + "|" + (normalizedDocumentReceiptValue(message.remoteModelName) ?? "unknown")
        }
        if let localModelName = normalizedDocumentReceiptValue(message.localModelName) {
            return "local|" + localModelName
        }
        return nil
    }

    private nonisolated static func normalizedDocumentReceiptValue(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !normalized.isEmpty else { return nil }
        return normalized
    }

    private nonisolated static func documentReceiptModelsMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        // Older persisted messages may predate model-origin metadata. Within that
        // compatibility case, treat the session as continuous instead of reintroducing
        // duplicate receipts after an app update.
        guard let lhs, let rhs else { return true }
        return lhs == rhs
    }

    @MainActor
    func savePendingMediaFile(from sourceURL: URL, originalFilename overrideFilename: String? = nil) async {
        guard let kind = TranscriptionMediaSupport.kind(for: sourceURL) else {
            audioRecordingError = String(localized: "This media format is not supported for transcription.")
            return
        }

        let fm = FileManager.default
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? (kind == .audio ? "m4a" : "mov") : sourceURL.pathExtension
        let filename = UUID().uuidString + "." + ext
        let destination = Self.attachmentStorageDirectory().appendingPathComponent(filename)

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            if Self.isPath(sourceURL.path, inside: Self.attachmentStorageDirectory()) {
                if sourceURL.path != destination.path {
                    try fm.copyItem(at: sourceURL, to: destination)
                }
            } else {
                try fm.copyItem(at: sourceURL, to: destination)
            }
            let bytes = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            let duration = await mediaDurationSeconds(for: destination)
            let normalizedOverride = overrideFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachment = ChatMediaAttachment(
                kind: kind,
                originalFilename: normalizedOverride?.isEmpty == false
                    ? (normalizedOverride ?? sourceURL.lastPathComponent)
                    : sourceURL.lastPathComponent,
                storedPath: destination.path,
                fileSizeBytes: bytes,
                durationSeconds: duration
            )
            pendingMediaAttachments.append(
                attachment
            )
            Task { await logger.log("[ASR][Attach] kind=\(kind.rawValue) name=\(attachment.originalFilename) path=\(destination.path)") }
            if TranscriptionSettings.autoTranscribesAttachments {
                if TranscriptionSettings.selectedEngineID == .audioLanguageModel,
                   !TranscriptionSettings.hasConfirmedRemoteUpload {
                    audioRecordingError = String(localized: "Confirm remote ASR upload before transcribing this media.")
                } else {
                    beginTranscribingPendingMediaAttachment(id: attachment.id)
                }
            }
        } catch {
            audioRecordingError = error.localizedDescription
            Task { await logger.log("[ASR][Attach] failed=\(error.localizedDescription)") }
        }
    }

    private func mediaDurationSeconds(for url: URL) async -> TimeInterval? {
#if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
#else
        return nil
#endif
    }

    @MainActor
    func removePendingMediaAttachment(id: ChatMediaAttachment.ID) {
        mediaTranscriptionTasks[id]?.cancel()
        mediaTranscriptionTasks[id] = nil
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = pendingMediaAttachments.remove(at: index)
        let referencedByMessage = sessions.contains { session in
            session.messages.contains { msg in
                msg.mediaAttachments?.contains(where: { $0.id == id }) == true
            }
        }
        guard !referencedByMessage else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: attachment.storedPath))
        if let sidecar = attachment.transcriptSidecarPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sidecar))
        }
    }

    @MainActor
    func beginTranscribingPendingMediaAttachment(id: ChatMediaAttachment.ID) {
        guard mediaTranscriptionTasks[id] == nil else { return }
        let task = Task { [weak self] in
            await self?.transcribePendingMediaAttachment(id: id)
            await MainActor.run {
                self?.mediaTranscriptionTasks[id] = nil
            }
        }
        mediaTranscriptionTasks[id] = task
    }

    @MainActor
    func cancelPendingMediaTranscription(id: ChatMediaAttachment.ID) {
        mediaTranscriptionTasks[id]?.cancel()
        mediaTranscriptionTasks[id] = nil
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingMediaAttachments[index].status = .notStarted
        pendingMediaAttachments[index].partialTranscript = nil
        pendingMediaAttachments[index].errorMessage = nil
    }

    @MainActor
    func transcribePendingMediaAttachment(id: ChatMediaAttachment.ID) async {
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        var attachment = pendingMediaAttachments[index]
        attachment.status = .transcribing
        attachment.errorMessage = nil
        pendingMediaAttachments[index] = attachment

        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        let options = TranscriptionSettings.requestOptions(offGrid: offGrid)
        let mediaURL = URL(fileURLWithPath: attachment.storedPath)
        let selectedEngineID = TranscriptionSettings.selectedEngineID
        // Capture the Sendable filename so the @Sendable onEvent closure doesn't
        // capture the non-Sendable `attachment` across isolation.
        let originalFilename = attachment.originalFilename
        Task {
            await logger.log("[ASR][Transcribe] start name=\(attachment.originalFilename) engine=\(selectedEngineID.rawValue) locale=\(options.localeIdentifier) off_grid=\(offGrid) bytes=\(attachment.fileSizeBytes ?? -1) duration=\(attachment.durationSeconds.map { String(format: "%.2f", $0) } ?? "unknown")")
        }

        do {
            let backend: any TranscriptionBackend = try TranscriptionBackendFactory.makeBackend(for: selectedEngineID)
            Task { await logger.log("[ASR][Transcribe] backend.ready requested=\(selectedEngineID.rawValue) actual=\(backend.engineID.rawValue)") }
            let rawArtifact = try await backend.transcribe(
                mediaURL: mediaURL,
                originalFilename: attachment.originalFilename,
                options: options,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let currentIndex = self.pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
                        switch event {
                        case .partial(let text):
                            self.pendingMediaAttachments[currentIndex].partialTranscript = text
                            Task { await logger.log("[ASR][Transcribe] partial name=\(originalFilename) chars=\(text.count)") }
                        case .completed:
                            break
                        }
                    }
                }
            )
            let artifact = rawArtifact.withProvenance(engineID: selectedEngineID, options: options)

            guard let currentIndex = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
            let sidecar = try writeTranscriptSidecar(artifact)
            pendingMediaAttachments[currentIndex].status = .completed
            pendingMediaAttachments[currentIndex].partialTranscript = nil
            pendingMediaAttachments[currentIndex].transcript = artifact
            pendingMediaAttachments[currentIndex].transcriptSidecarPath = sidecar.path
            Haptics.successLight()
            AccessibilityAnnouncer.announceLocalized("Transcription complete")
            Task { await logger.log("[ASR][Transcribe] completed name=\(attachment.originalFilename) chars=\(artifact.transcriptText.count)") }
        } catch {
            if Task.isCancelled { return }
            guard let currentIndex = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
            pendingMediaAttachments[currentIndex].status = .failed
            pendingMediaAttachments[currentIndex].errorMessage = error.localizedDescription
            Haptics.error()
            AccessibilityAnnouncer.announce(error.localizedDescription)
            Task { await logger.log("[ASR][Transcribe] failed name=\(attachment.originalFilename) engine=\(selectedEngineID.rawValue) error_type=\(String(describing: type(of: error))) error=\(error.localizedDescription)") }
        }
    }

    @MainActor
    func updatePendingMediaTranscript(id: ChatMediaAttachment.ID, title: String, transcriptText: String) {
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }),
              let artifact = pendingMediaAttachments[index].transcript else { return }
        let updated = artifact.updatingReview(title: title, transcriptText: transcriptText)
        pendingMediaAttachments[index].transcript = updated
        if let sidecarURL = try? writeTranscriptSidecar(updated) {
            pendingMediaAttachments[index].transcriptSidecarPath = sidecarURL.path
        }
    }

    @MainActor
    func updateMessageMediaTranscript(messageID: Msg.ID, attachmentID: ChatMediaAttachment.ID, title: String, transcriptText: String) {
        var messages = msgs
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              var attachments = messages[messageIndex].mediaAttachments,
              let attachmentIndex = attachments.firstIndex(where: { $0.id == attachmentID }),
              let artifact = attachments[attachmentIndex].transcript else { return }
        let updated = artifact.updatingReview(title: title, transcriptText: transcriptText)
        attachments[attachmentIndex].transcript = updated
        if let sidecarURL = try? writeTranscriptSidecar(updated) {
            attachments[attachmentIndex].transcriptSidecarPath = sidecarURL.path
        }
        messages[messageIndex].mediaAttachments = attachments
        msgs = messages
        saveSessions()
    }

    @MainActor
    func saveTranscriptAttachmentAsDataset(_ attachment: ChatMediaAttachment) async -> Result<LocalDataset, Error> {
        guard let artifact = attachment.transcript else {
            return .failure(Self.transcriptSaveError(String(localized: "No transcript was saved.")))
        }
        guard let datasetManager else {
            return .failure(Self.transcriptSaveError(String(localized: "Stored is unavailable.")))
        }
        let dir = Self.attachmentStorageDirectory()
            .appendingPathComponent("TranscriptExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = attachment.originalFilename
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let textURL = dir.appendingPathComponent((base.isEmpty ? artifact.id.uuidString : base) + ".transcript.txt")
        let body = artifact.exportText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try body.data(using: .utf8)?.write(to: textURL, options: [.atomic])
            if let dataset = await datasetManager.importDocuments(
                from: [textURL],
                suggestedName: String.localizedStringWithFormat(String(localized: "%@ Transcript"), attachment.originalFilename)
            ) {
                let metadataDir = DatasetIndexIO.transcriptMetadataDirectoryURL(for: dataset.url)
                try? FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
                let metadataURL = metadataDir.appendingPathComponent((base.isEmpty ? artifact.id.uuidString : base) + ".transcript.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(artifact).write(to: metadataURL, options: [.atomic])
                Task { await logger.log("[ASR][Dataset] saved transcript dataset=\(dataset.datasetID) name=\(dataset.name)") }
                return .success(dataset)
            }
            return .failure(Self.transcriptSaveError(String(localized: "No transcript was saved.")))
        } catch {
            Task { await logger.log("[ASR][Dataset] export failed=\(error.localizedDescription)") }
            return .failure(error)
        }
    }

    @MainActor
    func saveTranscriptAttachment(_ attachment: ChatMediaAttachment, toExistingDataset dataset: LocalDataset) async -> Result<LocalDataset, Error> {
        guard let artifact = attachment.transcript else {
            return .failure(Self.transcriptSaveError(String(localized: "No transcript was saved.")))
        }
        let base = Self.safeTranscriptBaseName(attachment.originalFilename, fallback: artifact.id.uuidString)
        let mediaTranscriptDir = dataset.url.appendingPathComponent("Media Transcripts", isDirectory: true)
        let metadataDir = DatasetIndexIO.transcriptMetadataDirectoryURL(for: dataset.url)
        do {
            try FileManager.default.createDirectory(at: mediaTranscriptDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
            let textURL = Self.uniqueTranscriptURL(in: mediaTranscriptDir, base: base, ext: "transcript.txt")
            let metadataURL = Self.uniqueTranscriptURL(in: metadataDir, base: base, ext: "transcript.json")
            try artifact.exportText.trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8)?.write(to: textURL, options: [.atomic])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(artifact).write(to: metadataURL, options: [.atomic])
            datasetManager?.reloadFromDisk()
            Task { await logger.log("[ASR][Dataset] saved transcript existing dataset=\(dataset.datasetID) name=\(dataset.name)") }
            return .success(dataset)
        } catch {
            Task { await logger.log("[ASR][Dataset] existing save failed=\(error.localizedDescription)") }
            return .failure(error)
        }
    }

    private static func safeTranscriptBaseName(_ name: String, fallback: String) -> String {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return base.isEmpty ? fallback : base
    }

    private static func uniqueTranscriptURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(base + "." + ext)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(base + "-\(suffix)." + ext)
            suffix += 1
        }
        return candidate
    }

    private static func transcriptSaveError(_ message: String) -> NSError {
        NSError(
            domain: "Noema.TranscriptSave",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    @MainActor
    private func writeTranscriptSidecar(_ artifact: TranscriptArtifact) throws -> URL {
        let sidecarURL = Self.attachmentStorageDirectory()
            .appendingPathComponent(artifact.id.uuidString + ".transcript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact).write(to: sidecarURL, options: [.atomic])
        return sidecarURL
    }

#if canImport(AVFoundation)
    @MainActor
    func toggleAudioRecording() async {
        if isRecordingAudio {
            await stopAudioRecording()
        } else {
            await startAudioRecording()
        }
    }

    @MainActor
    private func startAudioRecording() async {
#if canImport(Speech)
        if isDictating {
            await stopLiveDictation()
        }
#endif
        audioRecordingError = nil
        do {
#if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            let granted: Bool
#if os(iOS)
            if #available(iOS 17.0, *) {
                granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
            } else {
                granted = await withCheckedContinuation { continuation in
                    session.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
            }
#else
            granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
#endif
            guard granted else {
                audioRecordingError = String(localized: "Microphone permission is required to record audio.")
                Haptics.error()
                AccessibilityAnnouncer.announceLocalized("Microphone permission is required to record audio.")
                return
            }
            // Activation blocks; keep it off the main thread (the OS warns
            // "AVAudioSession activate/deactivate called on main thread").
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            }.value
#endif
            let url = Self.attachmentStorageDirectory().appendingPathComponent(UUID().uuidString + ".m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            audioRecordingURL = url
            audioRecordingFriendlyName = Self.friendlyVoiceNoteName()
            audioRecordingStartedAt = Date()
            micLevelMeter.reset()
            isRecordingAudio = true
            Haptics.successLight()
            AccessibilityAnnouncer.announceLocalized("Recording started")
            startAudioRecordingMeter()
        } catch {
            audioRecordingError = error.localizedDescription
            Haptics.error()
            AccessibilityAnnouncer.announce(error.localizedDescription)
        }
    }

    @MainActor
    private func stopAudioRecording() async {
        let friendlyName = audioRecordingFriendlyName
        audioRecordingMeterTask?.cancel()
        audioRecordingMeterTask = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecordingAudio = false
        audioRecordingStartedAt = nil
        micLevelMeter.reset()
        audioRecordingFriendlyName = nil
#if os(iOS) || os(visionOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
        guard let url = audioRecordingURL else { return }
        audioRecordingURL = nil
        Haptics.successLight()
        AccessibilityAnnouncer.announceLocalized("Recording stopped")
        await savePendingMediaFile(from: url, originalFilename: friendlyName)
    }

    @MainActor
    private func startAudioRecordingMeter() {
        audioRecordingMeterTask?.cancel()
        audioRecordingMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.audioRecorder?.updateMeters()
                if let power = self?.audioRecorder?.averagePower(forChannel: 0), power.isFinite {
                    self?.micLevelMeter.push(max(0, min(1, (power + 55) / 55)))
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private static func friendlyVoiceNoteName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return String.localizedStringWithFormat(String(localized: "Voice Note %@.m4a"), formatter.string(from: date))
    }
#endif

    // Heuristic for GGUF VLMs when Hub metadata is unavailable (offline or missing tags)
    @MainActor
    func savePendingImage(_ image: UIImage) async {
        guard let normalized = AttachmentImageNormalizer.normalizeAttachmentImage(image) else { return }
        await savePendingNormalizedAttachment(normalized, source: "image")
    }

    @MainActor
    func savePendingImageData(_ data: Data) async {
        guard let normalized = AttachmentImageNormalizer.normalizeAttachmentData(data) else { return }
        await savePendingNormalizedAttachment(normalized, source: "data")
    }

    @MainActor
    func removePendingImage(at index: Int) {
        guard pendingImageURLs.indices.contains(index) else { return }
        let url = pendingImageURLs.remove(at: index)
        pendingThumbnails.removeValue(forKey: url)
        let referencedByMessage = sessions.contains { session in
            session.messages.contains { msg in
                msg.imagePaths?.contains(url.path) == true
            }
        }
        if !referencedByMessage {
            try? FileManager.default.removeItem(at: url)
        }
        Task { await logger.log("[Images][Remove] removed=\(url.lastPathComponent) pending=\(pendingImageURLs.count)") }
    }

    // Accessor used by views to fetch cached thumbnails
    func pendingThumbnail(for url: URL) -> UIImage? {
        pendingThumbnails[url]
    }

    @MainActor
    private func savePendingNormalizedAttachment(_ normalized: AttachmentImageNormalizer.Result, source: String) async {
        let dir = Self.attachmentStorageDirectory()
        let url = dir.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try normalized.data.write(to: url, options: [.atomic])
        } catch {
            Task { await logger.log("[Images][Attach] write-failed path=\(url.path) error=\(error.localizedDescription)") }
            return
        }

        let target = CGSize(width: 160, height: 160)
        if let thumb = ImageThumbnailCache.shared.thumbnail(for: url.path, pointSize: target, maxScale: 1) {
            pendingThumbnails[url] = thumb
        }

        pendingImageURLs.append(url)

        let originalWidth = normalized.originalPixelWidth ?? normalized.pixelWidth
        let originalHeight = normalized.originalPixelHeight ?? normalized.pixelHeight
        Task {
            await logger.log(
                "[Images][Attach] saved=\(url.lastPathComponent) source=\(source) original=\(originalWidth)x\(originalHeight) normalized=\(normalized.pixelWidth)x\(normalized.pixelHeight) clamped=\(normalized.wasClamped) suspicious=\(normalized.suspiciouslyLargeSource) path=\(url.path) pending=\(pendingImageURLs.count)"
            )
        }
    }

    /// Handle rolling thoughts for <think> tags during streaming
    func handleRollingThoughts(raw: String, messageIndex: Int) async {
        let thinkBlocks = parseThinkBlocks(from: raw)
        guard !thinkBlocks.isEmpty else { return }

        for (index, thinkBlock) in thinkBlocks.enumerated() {
            guard messageIndex >= 0 && messageIndex < streamMsgs.count else { continue }
            let msgId = streamMsgs[messageIndex].id.uuidString
            let thinkKey = "message-\(msgId)-think-\(index)"

            guard !thinkBlock.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let viewModel: RollingThoughtViewModel
            if let existing = rollingThoughtViewModels[thinkKey] {
                viewModel = existing
            } else {
                viewModel = RollingThoughtViewModel()
                rollingThoughtViewModels[thinkKey] = viewModel
            }

            // Assign the authoritative think text directly. `raw` already holds the
            // full content parsed from the growing stream buffer, so feeding a delta
            // through a token stream (the old approach) only introduced a race that
            // duplicated text and broke completion. Setting it outright is race-free
            // and keeps fullText exactly equal to thinkBlock.content.
            viewModel.setContent(thinkBlock.content)

            // Mark complete once the closing </think> has arrived. Because fullText
            // now matches the block exactly, this fires reliably (no deferral needed).
            // finish() preserves an expanded box while still flagging completion.
            if thinkBlock.isComplete && viewModel.phase != .complete {
                viewModel.finish()
                let storageKey = "RollingThought." + thinkKey
                viewModel.saveState(forKey: storageKey)
            }
        }
    }

    /// Parse think blocks from raw text
    private func parseThinkBlocks(from text: String) -> [(content: String, isComplete: Bool)] {
        var blocks: [(String, Bool)] = []
        var rest = text[...]

        // Strip stray think tags AND any tool anchor that landed inside the block.
        // A tool call emitted from within reasoning inserts `<noema_tool_anchor/>`
        // mid-<think>; it must not leak into the displayed reasoning text, and
        // removing it keeps this block's content identical to what the renderer's
        // parser produces (their think-ordinals must stay in lockstep — the
        // rolling-thought view models are keyed by that ordinal).
        func sanitize(_ raw: String) -> String {
            raw.replacingOccurrences(of: "<think>", with: "")
                .replacingOccurrences(of: "</think>", with: "")
                .replacingOccurrences(of: noemaToolAnchorToken, with: "")
        }

        // Implicit-open reasoning: some chat templates (DeepSeek-R1, Qwen3 *-Thinking)
        // pre-open the think block in the prompt, so the model streams only the
        // reasoning body followed by a lone </think>. When a closing tag arrives with
        // no preceding <think>, treat everything up to it as a completed think block.
        if let close = rest.range(of: "</think>"),
           rest.range(of: "<think>").map({ close.lowerBound < $0.lowerBound }) ?? true {
            blocks.append((sanitize(String(rest[..<close.lowerBound])), true))
            rest = rest[close.upperBound...]
        }

        while let start = rest.range(of: "<think>") {
            rest = rest[start.upperBound...]
            if let end = rest.range(of: "</think>") {
                blocks.append((sanitize(String(rest[..<end.lowerBound])), true))
                rest = rest[end.upperBound...]
            } else {
                blocks.append((sanitize(String(rest)), false))
                break
            }
        }

        // Index densely over NON-EMPTY reasoning only. An empty block must not
        // occupy an ordinal, or the view-model keys drift out of sync with the
        // renderer (which likewise skips empty think pieces) and a later block's
        // reasoning renders twice as duplicate REASONING rows.
        return blocks.filter { !$0.0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Recreate rolling thought view models for existing messages
    func recreateRollingThoughtViewModels() {
        // Build allowed keys for current session and content map
        var allowedKeys: Set<String> = []
        var keyToContent: [String: (content: String, isComplete: Bool)] = [:]
        for msg in msgs {
            guard msg.role == "🤖" || msg.role.lowercased() == "assistant" else { continue }
            let blocks = parseThinkBlocks(from: msg.text)
            for (idx, block) in blocks.enumerated() {
                let content = block.content
                let isComplete = block.isComplete
                guard !content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { continue }
                let key = "message-\(msg.id.uuidString)-think-\(idx)"
                allowedKeys.insert(key)
                keyToContent[key] = (content, isComplete)
            }
        }

        // Compute removals and additions first
        var keysToRemove: [String] = []
        for key in rollingThoughtViewModels.keys where !allowedKeys.contains(key) {
            keysToRemove.append(key)
        }

        var modelsToAdd: [String: RollingThoughtViewModel] = [:]
        for key in allowedKeys where rollingThoughtViewModels[key] == nil {
            let vm = RollingThoughtViewModel()
            if let tuple = keyToContent[key] {
                vm.fullText = tuple.content
                vm.updateRollingLines()
                vm.phase = tuple.isComplete ? .complete : .expanded
            }
            modelsToAdd[key] = vm
        }

        // Apply all mutations in one deferred main-queue pass to avoid nested updates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for key in keysToRemove {
                self.rollingThoughtViewModels[key]?.cancel()
                self.rollingThoughtViewModels.removeValue(forKey: key)
            }
            for (key, vm) in modelsToAdd {
                self.rollingThoughtViewModels[key] = vm
            }
        }
    }

    /// Returns assistant-visible text only when it appears after the latest control
    /// segment (`<think>`/tool markers). If controls are present and no trailing
    /// answer text exists yet, this returns nil.
    func strictFinalAnswerText(for message: Msg) -> String? {
        strictFinalAnswerText(forText: message.text, toolCalls: message.toolCalls)
    }

    /// Same as `strictFinalAnswerText(for:)` but operates on a raw visible-text string.
    /// Used by the streaming loops so the final-answer haptic can be evaluated against the
    /// live text without first writing it into `sessions`.
    func strictFinalAnswerText(forText text: String, toolCalls: [ToolCall]?) -> String? {
        let pieces = parse(text, toolCalls: toolCalls)
        guard !pieces.isEmpty else { return nil }

        let lastControlIndex = pieces.lastIndex { piece in
            switch piece {
            case .think, .tool:
                return true
            default:
                return false
            }
        }

        var trailingText: [String] = []
        for (index, piece) in pieces.enumerated() {
            guard case .text(let text) = piece else { continue }
            if let last = lastControlIndex, index <= last { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                trailingText.append(trimmed)
            }
        }

        let trailingCombined = trailingText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingCombined.isEmpty {
            return trailingCombined
        }

        let plainCombined = pieces.compactMap { piece -> String? in
            guard case .text(let text) = piece else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return plainCombined.isEmpty ? nil : plainCombined
    }

    /// Returns only the assistant-visible answer text, stripping think/tool blocks
    /// and preferring content that appears after the final control segment.
    func finalAnswerText(for message: Msg) -> String? {
        let pieces = parse(message.text, toolCalls: message.toolCalls)
        guard !pieces.isEmpty else { return nil }

        let lastControlIndex = pieces.lastIndex { piece in
            switch piece {
            case .think, .tool:
                return true
            default:
                return false
            }
        }

        var segments: [String] = []
        for (index, piece) in pieces.enumerated() {
            guard case .text(let text) = piece else { continue }
            if let last = lastControlIndex, index <= last { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
        }

        var combined = segments.joined(separator: "\n")
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallbackSegments = pieces.compactMap { piece -> String? in
                guard case .text(let text) = piece else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            combined = fallbackSegments.joined(separator: "\n")
        }

        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ChatVM: ModelBenchmarkingViewModel {
    func unloadAfterBenchmark() async {
        await unload()
    }
}
#endif
