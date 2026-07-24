import Foundation
import Combine
import SwiftUI

#if canImport(AVFoundation) && canImport(Speech)

enum VoiceTranscriberFactory {
    /// WhisperKit gets its own live path when it is the selected ASR engine and
    /// its model is installed; whisper.cpp and remote engines fall back to the
    /// Apple live transcriber (file attachments keep the full backend set).
    @MainActor
    static func make(autoEndpointing: Bool) -> any VoiceLiveTranscriber {
#if canImport(WhisperKit)
        if usesWhisperLive {
            return WhisperLiveTranscriber()
        }
#endif
        return AppleSpeechLiveTranscriber(autoEndpointing: autoEndpointing)
    }

    @MainActor
    static var displayName: String {
#if canImport(WhisperKit)
        if usesWhisperLive {
            return WhisperModelCatalog.activeRecord(for: .whisperKit)?.displayName ?? "Whisper"
        }
#endif
        return "Apple Speech"
    }

#if canImport(WhisperKit)
    @MainActor
    private static var usesWhisperLive: Bool {
        guard TranscriptionSettings.selectedEngineID == .whisperKit,
              let record = WhisperModelCatalog.activeRecord(for: .whisperKit) else { return false }
        return WhisperModelCatalog.installationState(for: record, runtime: .whisperKit) == .ready
    }
#endif
}

/// Drives one hands-free voice conversation: listen → transcribe → send →
/// speak the streamed reply sentence-by-sentence → listen again. Strictly
/// half-duplex: the mic is released before the first TTS sample plays.
@MainActor
final class VoiceModeController: ObservableObject {
    enum State: Equatable {
        case preparing
        case needsVoiceModel
        case listening
        case finalizing
        case thinking
        case speaking
        case paused
        case error(String)
    }

    @Published private(set) var state: State = .preparing
    @Published private(set) var liveTranscript = ""
    @Published private(set) var speakingCaption = ""
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var statusLine = ""
    @Published private(set) var isMuted = false
    @Published private(set) var usingToolNotice = false
    @Published private(set) var preparingDetail = ""

    private let chatVM: ChatVM
    private let sessionCoordinator = VoiceAudioSessionCoordinator()
    private var transcriber: (any VoiceLiveTranscriber)?
    private var outputEngine: (any VoiceOutputEngine)?
    private let speechComposer = SpeechStreamComposer()
    private var replyLocale = Locale.current

    private var transcriberEventsTask: Task<Void, Never>?
    private var turnEventsCancellable: AnyCancellable?
    private var streamTextCancellable: AnyCancellable?
    private var streamActiveCancellable: AnyCancellable?
    private var speechQueue: [String] = []
    private var speechPumpTask: Task<Void, Never>?
    private var pumpGeneration = 0
    private var prefetchedSpeech: (sentence: String, task: Task<PreparedSpeech, Error>)?
    private var sendWatchdogTask: Task<Void, Never>?
    private var turnCompleted = false
    private var streamBegan = false
    private var awaitingTurn = false
    private var expectingCancel = false
    private var sessionEnded = false
    private var began = false

    init(chatVM: ChatVM) {
        self.chatVM = chatVM
    }

    // MARK: - Lifecycle

    func begin() async {
        guard !began else { return }
        began = true
        await logger.log("[Voice] begin canAccept=\(chatVM.canAcceptChatInput) recording=\(chatVM.isRecordingAudio) dictating=\(chatVM.isDictating)")

        guard chatVM.canAcceptChatInput else {
            state = .error(String(localized: "Load a model to use voice mode."))
            return
        }
        if chatVM.isRecordingAudio {
            state = .error(String(localized: "Stop the voice note recording first."))
            return
        }
        if chatVM.isDictating {
            await chatVM.stopLiveDictation()
        }

        // Permissions up front, so later prepare steps can be timed/timeouted
        // without racing a permission dialog.
        guard await VoiceMicrophonePermission.request() else {
            await logger.log("[Voice] mic permission denied")
            state = .error(String(localized: "Microphone permission is required to record audio."))
            return
        }

        sessionCoordinator.onInterruptionBegan = { [weak self] in self?.pause() }
        sessionCoordinator.onInterruptionEnded = { [weak self] shouldResume in
            if shouldResume { self?.resume() }
        }
        sessionCoordinator.onRouteLost = { [weak self] in self?.pause() }

        preparingDetail = String(localized: "Starting audio session…")
        do {
            try await sessionCoordinator.activate()
            await logger.log("[Voice] audio session active")
        } catch {
            await logger.log("[Voice] audio session activation failed: \(error.localizedDescription)")
            state = .error(error.localizedDescription)
            return
        }

        switch VoiceOutputEngineFactory.resolve() {
        case .needsVoiceModel:
            await logger.log("[Voice] neural weights not installed → needsVoiceModel card")
            state = .needsVoiceModel
            return
        case .engine(let engine):
            await logger.log("[Voice] resolved output engine=\(engine.id.rawValue)")
            await adopt(outputEngine: engine)
        }

        await setUpTranscriberAndListen()
    }

    /// Called from the needs-voice-model card ("Use System Voice Now", or after
    /// a completed download) to enter the conversation loop.
    func proceed(with engine: any VoiceOutputEngine) async {
        guard !sessionEnded else { return }
        await adopt(outputEngine: engine)
        await setUpTranscriberAndListen()
    }

    func end() {
        guard !sessionEnded else { return }
        sessionEnded = true
        Task { await logger.log("[Voice] session ended") }
        sendWatchdogTask?.cancel()
        speechPumpTask?.cancel()
        cancelPrefetch()
        speechQueue.removeAll()
        turnEventsCancellable = nil
        streamTextCancellable = nil
        streamActiveCancellable = nil
        transcriberEventsTask?.cancel()
        transcriber?.tearDown()
        transcriber = nil
        outputEngine?.stopSpeaking()
        let engine = outputEngine
        outputEngine = nil
        Task { await engine?.unload() }
        sessionCoordinator.deactivate()
        // A reply still streaming keeps streaming into the chat transcript.
    }

    // MARK: - User actions

    func interrupt() {
        guard state == .speaking || state == .thinking else { return }
        Task { await logger.log("[Voice] user interrupt (streaming=\(chatVM.isStreaming))") }
        expectingCancel = chatVM.isStreaming
        clearSpeechPipeline()
        if chatVM.isStreaming {
            chatVM.stop()
        }
        awaitingTurn = false
        Haptics.successLight()
        startListening(afterDelay: .milliseconds(150))
    }

    func toggleMuted() {
        if isMuted {
            isMuted = false
            if state == .paused { resume() }
        } else {
            isMuted = true
            if state == .listening || state == .finalizing {
                transcriber?.cancelUtterance()
                transcriber?.suspend()
                inputLevel = 0
                state = .paused
            }
        }
    }

    func resume() {
        guard !sessionEnded, state == .paused, !isMuted else { return }
        startListening(afterDelay: .zero)
    }

    func retryAfterError() {
        guard case .error = state, !sessionEnded else { return }
        if outputEngine == nil || transcriber == nil {
            began = false
            state = .preparing
            Task { await begin() }
        } else {
            startListening(afterDelay: .zero)
        }
    }

    // MARK: - Setup

    private func adopt(outputEngine engine: any VoiceOutputEngine) async {
        engine.levelHandler = { [weak self] level in
            self?.outputLevel = level
        }
        if engine.id == .neural {
            preparingDetail = String(localized: "Loading neural voice…")
        }
        let started = ContinuousClock.now
        let prepared = await prepareEngine(engine, timeoutSeconds: 90)
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        if prepared {
            outputEngine = engine
            await logger.log("[Voice] output engine ready id=\(engine.id.rawValue) in \(String(format: "%.1f", elapsed))s")
        } else if engine.id == .neural {
            // No explicit unload: the load may still be mid-flight after a
            // timeout; dropping the last reference cleans up when it settles.
            await logger.log("[Voice] neural engine failed/timed out after \(String(format: "%.1f", elapsed))s → system voice fallback")
            let fallback = SystemVoiceOutputEngine()
            fallback.levelHandler = { [weak self] level in self?.outputLevel = level }
            outputEngine = fallback
        } else {
            state = .error(String(localized: "Audio playback failed."))
            return
        }
        refreshStatusLine()
    }

    @MainActor
    private final class PrepareRace {
        private var resumed = false
        private let continuation: CheckedContinuation<Bool, Never>

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: Bool) {
            guard !resumed else { return }
            resumed = true
            continuation.resume(returning: value)
        }
    }

    /// Races prepare against a deadline so a wedged model load degrades to the
    /// system voice instead of pinning the session on "Preparing" forever.
    /// No permission dialogs run inside engine prepare, so the timeout is safe.
    /// (Plain tasks + a once-flag: the region-isolation checker rejects the
    /// equivalent TaskGroup formulation.)
    private func prepareEngine(_ engine: any VoiceOutputEngine, timeoutSeconds: Double) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let race = PrepareRace(continuation)
            Task { @MainActor in
                var prepared = false
                do {
                    try await engine.prepare()
                    prepared = true
                } catch {
                    await logger.log("[Voice] engine prepare failed: \(error.localizedDescription)")
                }
                race.resume(prepared)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                race.resume(false)
            }
        }
    }

    private func setUpTranscriberAndListen() async {
        preparingDetail = String(localized: "Loading speech recognition…")
        var transcriber = VoiceTranscriberFactory.make(autoEndpointing: true)
        await logger.log("[Voice] transcriber=\(String(describing: type(of: transcriber))) preparing")
        let started = ContinuousClock.now
        do {
            try await transcriber.prepare()
        } catch {
            await logger.log("[Voice] transcriber prepare failed: \(error.localizedDescription)")
#if canImport(WhisperKit)
            if transcriber is WhisperLiveTranscriber {
                await logger.log("[Voice] falling back to Apple Speech live transcriber")
                transcriber.tearDown()
                let fallback = AppleSpeechLiveTranscriber(autoEndpointing: true)
                do {
                    try await fallback.prepare()
                    transcriber = fallback
                } catch {
                    state = .error(error.localizedDescription)
                    return
                }
            } else {
                state = .error(error.localizedDescription)
                return
            }
#else
            state = .error(error.localizedDescription)
            return
#endif
        }
        let elapsed = (ContinuousClock.now - started) / .seconds(1)
        await logger.log("[Voice] transcriber ready in \(String(format: "%.1f", elapsed))s")
        self.transcriber = transcriber
        replyLocale = Locale(identifier: AppleSpeechTranscriptionBackend.resolveLocaleIdentifier(
            TranscriptionSettings.preferredLocaleIdentifier
        ))
        refreshStatusLine()
        consumeTranscriberEvents(from: transcriber)
        subscribeToChatVM()
        startListening(afterDelay: .zero)
    }

    private func refreshStatusLine() {
        var parts: [String] = []
        if let outputEngine {
            parts.append(outputEngine.statusDescription)
        }
        parts.append(VoiceTranscriberFactory.displayName)
        statusLine = parts.joined(separator: " · ")
    }

    // MARK: - Listening

    private func startListening(afterDelay delay: Duration) {
        guard !sessionEnded, !isMuted else { return }
        Task { @MainActor [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, !self.sessionEnded, !self.isMuted else { return }
            switch self.state {
            case .paused, .needsVoiceModel:
                return
            default:
                break
            }
            self.liveTranscript = ""
            self.speakingCaption = ""
            self.usingToolNotice = false
            self.preparingDetail = ""
            do {
                try await self.transcriber?.startUtterance()
                self.state = .listening
                Task { await logger.log("[Voice] listening") }
            } catch {
                Task { await logger.log("[Voice] startUtterance failed: \(error.localizedDescription)") }
                self.state = .error(error.localizedDescription)
            }
        }
    }

    private func consumeTranscriberEvents(from transcriber: any VoiceLiveTranscriber) {
        transcriberEventsTask?.cancel()
        transcriberEventsTask = Task { @MainActor [weak self] in
            for await event in transcriber.events {
                guard let self, !self.sessionEnded else { break }
                switch event {
                case .level(let level):
                    if self.state == .listening { self.inputLevel = level }
                case .partial(let text):
                    if self.state == .listening { self.liveTranscript = text }
                case .finalized(let text):
                    guard self.state == .listening else { break }
                    self.inputLevel = 0
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await logger.log("[Voice] utterance finalized chars=\(trimmed.count)") }
                    if trimmed.isEmpty {
                        self.startListening(afterDelay: .milliseconds(200))
                    } else {
                        self.liveTranscript = trimmed
                        self.sendTurn(trimmed)
                    }
                case .failed(let message):
                    Task { await logger.log("[Voice] transcriber failed: \(message)") }
                    if self.state == .listening || self.state == .finalizing {
                        self.state = .error(message)
                    }
                }
            }
        }
    }

    // MARK: - Turn

    private func sendTurn(_ text: String) {
        state = .finalizing
        transcriber?.suspend()

        speechComposer.reset()
        speechQueue.removeAll()
        turnCompleted = false
        streamBegan = false
        awaitingTurn = true
        expectingCancel = false
        usingToolNotice = false

        state = .thinking
        Haptics.successLight()
        Task { await logger.log("[Voice] sending turn chars=\(text.count)") }
        Task { await chatVM.sendMessage(text) }

        sendWatchdogTask?.cancel()
        sendWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard let self, !Task.isCancelled, !self.sessionEnded else { return }
            if self.awaitingTurn, !self.streamBegan, !self.chatVM.isStreaming, !self.turnCompleted {
                // The send was silently blocked (guards keep the prompt); go back
                // to listening rather than hanging in "thinking".
                Task { await logger.log("[Voice] send watchdog fired — no stream began, re-arming") }
                self.awaitingTurn = false
                self.startListening(afterDelay: .zero)
            }
        }
    }

    private func subscribeToChatVM() {
        streamActiveCancellable = chatVM.streamingStore.$activeID
            .receive(on: RunLoop.main)
            .sink { [weak self] activeID in
                guard let self, self.awaitingTurn else { return }
                if activeID != nil { self.streamBegan = true }
            }

        streamTextCancellable = chatVM.streamingStore.$visibleText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                guard let self, self.awaitingTurn, !text.isEmpty else { return }
                self.enqueue(sentences: self.speechComposer.ingest(text))
            }

        turnEventsCancellable = chatVM.assistantTurnEvents
            .receive(on: RunLoop.main)
            .sink { [weak self] event in
                self?.handleTurnEvent(event)
            }
    }

    private func handleTurnEvent(_ event: ChatVM.AssistantTurnEvent) {
        guard awaitingTurn, !sessionEnded else { return }
        Task { await logger.log("[Voice] turn event: \(event)") }
        switch event {
        case .continuingWithTool:
            usingToolNotice = true
        case .completed(let messageID):
            turnCompleted = true
            sendWatchdogTask?.cancel()
            let finalText = chatVM.msgs.first(where: { $0.id == messageID })?.text
                ?? chatVM.streamingStore.visibleText
            enqueue(sentences: speechComposer.flush(finalText))
            maybeFinishTurn()
        case .failed:
            awaitingTurn = false
            clearSpeechPipeline()
            state = .error(String(localized: "The model stopped unexpectedly."))
        case .cancelled:
            if expectingCancel {
                expectingCancel = false
            } else {
                awaitingTurn = false
                clearSpeechPipeline()
                startListening(afterDelay: .milliseconds(300))
            }
        }
    }

    // MARK: - Speech pump

    private func enqueue(sentences: [String]) {
        guard !sentences.isEmpty else {
            maybeFinishTurn()
            return
        }
        speechQueue.append(contentsOf: sentences)
        pumpSpeech()
    }

    private func pumpSpeech() {
        guard speechPumpTask == nil, !sessionEnded else { return }
        pumpGeneration += 1
        let generation = pumpGeneration
        speechPumpTask = Task { @MainActor [weak self] in
            while let self, !self.sessionEnded, !Task.isCancelled,
                  self.pumpGeneration == generation, !self.speechQueue.isEmpty {
                let sentence = self.speechQueue.removeFirst()
                if self.state == .thinking { self.state = .speaking }

                let synthTask: Task<PreparedSpeech, Error>
                if let prefetched = self.prefetchedSpeech, prefetched.sentence == sentence {
                    synthTask = prefetched.task
                    self.prefetchedSpeech = nil
                } else {
                    self.cancelPrefetch()
                    synthTask = self.makeSynthTask(for: sentence)
                }

                let prepared: PreparedSpeech
                do {
                    prepared = try await synthTask.value
                } catch {
                    guard !Task.isCancelled, self.pumpGeneration == generation else { break }
                    await self.recoverFromSpeakFailure(sentence: sentence, message: error.localizedDescription)
                    continue
                }
                guard !Task.isCancelled, self.pumpGeneration == generation else { break }

                // The next sentence synthesizes while this one plays; with a
                // sub-realtime neural engine this hides most of the gap.
                if let next = self.speechQueue.first {
                    self.prefetchedSpeech = (next, self.makeSynthTask(for: next))
                }

                self.speakingCaption = sentence
                do {
                    try await self.outputEngine?.play(prepared)
                } catch {
                    guard !Task.isCancelled, self.pumpGeneration == generation else { break }
                    await self.recoverFromSpeakFailure(sentence: sentence, message: error.localizedDescription)
                }
            }
            guard let self, self.pumpGeneration == generation else { return }
            self.speechPumpTask = nil
            self.maybeFinishTurn()
        }
    }

    private func makeSynthTask(for sentence: String) -> Task<PreparedSpeech, Error> {
        let engine = outputEngine
        let locale = replyLocale
        return Task { @MainActor in
            guard let engine else { throw CancellationError() }
            return try await engine.prepareUtterance(sentence, localeHint: locale)
        }
    }

    private func cancelPrefetch() {
        prefetchedSpeech?.task.cancel()
        prefetchedSpeech = nil
    }

    private func recoverFromSpeakFailure(sentence: String, message: String) async {
        await logger.log("[Voice] speak failed: \(message)")
        guard outputEngine?.id == .neural else { return }
        outputEngine?.stopSpeaking()
        let engine = outputEngine
        Task { await engine?.unload() }
        let fallback = SystemVoiceOutputEngine()
        fallback.levelHandler = { [weak self] level in self?.outputLevel = level }
        outputEngine = fallback
        refreshStatusLine()
        if let prepared = try? await fallback.prepareUtterance(sentence, localeHint: replyLocale) {
            try? await fallback.play(prepared)
        }
    }

    private func maybeFinishTurn() {
        guard awaitingTurn, turnCompleted, speechQueue.isEmpty, speechPumpTask == nil else { return }
        guard state == .speaking || state == .thinking else { return }
        awaitingTurn = false
        speakingCaption = ""
        outputLevel = 0
        Haptics.successLight()
        startListening(afterDelay: .milliseconds(300))
    }

    private func clearSpeechPipeline() {
        speechQueue.removeAll()
        pumpGeneration += 1
        cancelPrefetch()
        speechPumpTask?.cancel()
        speechPumpTask = nil
        outputEngine?.stopSpeaking()
        speakingCaption = ""
        outputLevel = 0
    }

    // MARK: - Interruptions

    private func pause() {
        guard !sessionEnded else { return }
        Task { await logger.log("[Voice] paused (interruption/route change)") }
        clearSpeechPipeline()
        transcriber?.cancelUtterance()
        transcriber?.suspend()
        inputLevel = 0
        if state != .needsVoiceModel, state != .preparing {
            state = .paused
        }
    }
}
#endif
