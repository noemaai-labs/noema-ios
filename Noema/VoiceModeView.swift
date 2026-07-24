import SwiftUI

#if canImport(AVFoundation) && canImport(Speech)
/// Full-screen hands-free conversation surface. Presentation: fullScreenCover
/// on iOS/visionOS, sheet on macOS. Closing it reveals the turns as regular
/// chat messages — they were streamed through the normal send pipeline.
struct VoiceModeView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var controller: VoiceModeController
    @ObservedObject private var downloadStore = VoiceModelDownloadStore.shared

    init(chatVM: ChatVM) {
        _controller = StateObject(wrappedValue: VoiceModeController(chatVM: chatVM))
    }

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                Spacer(minLength: 12)
                orbSection
                    .frame(maxHeight: .infinity)
                captionSection
                    .frame(minHeight: 130, alignment: .top)
                controls
            }
            .padding(20)
        }
        .task { await controller.begin() }
        .onDisappear { controller.end() }
        .onChangeCompat(of: controller.state) { _, newState in
            announce(newState)
        }
#if os(macOS)
        .frame(minWidth: 420, idealWidth: 440, minHeight: 560, idealHeight: 600)
#endif
    }

    private var backdrop: some View {
        LinearGradient(
            colors: [Color(red: 0.05, green: 0.05, blue: 0.07), Color(red: 0.10, green: 0.10, blue: 0.13)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateTint)
                        .frame(width: 6, height: 6)
                    Text("Voice")
                        .textCase(.uppercase)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                if !controller.statusLine.isEmpty {
                    Text(controller.statusLine)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End Voice Mode"))
            .accessibilityHint(Text("Closes voice mode and shows the conversation as chat messages."))
        }
    }

    private var orbSection: some View {
        VStack(spacing: 22) {
            VoiceStateOrb(
                tint: stateTint,
                level: controller.state == .speaking ? controller.outputLevel : controller.inputLevel,
                animating: orbAnimating,
                reduceMotion: reduceMotion
            )
            Text(stateLabel)
                .textCase(.uppercase)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { handleCenterTap() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(stateLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text(centerTapHint))
    }

    @ViewBuilder
    private var captionSection: some View {
        VStack(spacing: 12) {
            switch controller.state {
            case .preparing:
                ProgressView()
                    .tint(.white)
                if !controller.preparingDetail.isEmpty {
                    Text(controller.preparingDetail)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            case .needsVoiceModel:
                needsVoiceModelCard
            case .listening:
                if controller.liveTranscript.isEmpty {
                    Text("Speak whenever you're ready.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.4))
                } else {
                    Text(controller.liveTranscript)
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                }
            case .finalizing, .thinking:
                if controller.usingToolNotice {
                    Text("Using tools")
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            case .speaking:
                Text(controller.speakingCaption)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .id(controller.speakingCaption)
                    .transition(.opacity)
                Text("Tap to interrupt")
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            case .paused:
                Text("Paused")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                Text("Tap to resume")
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            case .error(let message):
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button {
                    controller.retryAfterError()
                } label: {
                    Text("Retry")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .animation(.easeInOut(duration: 0.18), value: controller.speakingCaption)
    }

    private var needsVoiceModelCard: some View {
        VStack(spacing: 14) {
            Text("Neural voice not downloaded")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
            Text(String.localizedStringWithFormat(
                String(localized: "Download the neural voice (about %@) or continue with the system voice."),
                ByteCountFormatter.string(fromByteCount: VoiceModelCatalog.approximateSizeBytes, countStyle: .file)
            ))
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)

            if downloadStore.isDownloading {
                VStack(spacing: 6) {
                    ProgressView(value: downloadStore.progress)
                        .tint(.white)
                        .frame(maxWidth: 220)
                    Text(LocalizedStringKey(downloadStore.isPreparing ? "Preparing voice model…" : "Downloading voice model…"))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                Button {
                    Task {
                        await downloadStore.downloadIfNeeded()
                        if VoiceModelCatalog.installState() == .ready {
                            switch VoiceOutputEngineFactory.resolve() {
                            case .engine(let engine):
                                await controller.proceed(with: engine)
                            case .needsVoiceModel:
                                break
                            }
                        }
                    }
                } label: {
                    Text("Download")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            if let error = downloadStore.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await controller.proceed(with: SystemVoiceOutputEngine()) }
            } label: {
                Text("Use System Voice")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(downloadStore.isDownloading)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                controller.toggleMuted()
            } label: {
                Image(systemName: controller.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(controller.isMuted ? Color.red : Color.white.opacity(0.85))
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(controller.isMuted ? "Unmute microphone" : "Mute microphone"))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color.red.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("End Voice Mode"))
        }
        .padding(.bottom, 8)
    }

    // MARK: - Helpers

    private var stateTint: Color {
        switch controller.state {
        case .listening: return ChatTheme.readyTint
        case .finalizing, .thinking: return ChatTheme.busyTint
        case .speaking: return .accentColor
        case .error: return .red
        default: return Color.white.opacity(0.35)
        }
    }

    private var orbAnimating: Bool {
        switch controller.state {
        case .listening, .thinking, .speaking, .finalizing: return true
        default: return false
        }
    }

    private var stateLabel: LocalizedStringKey {
        switch controller.state {
        case .preparing: return "Preparing"
        case .needsVoiceModel: return "Voice model required"
        case .listening: return "Listening"
        case .finalizing, .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .paused: return "Paused"
        case .error: return "Error"
        }
    }

    private var centerTapHint: LocalizedStringKey {
        switch controller.state {
        case .speaking, .thinking: return "Interrupts the reply and listens again."
        case .paused: return "Resumes listening."
        default: return "Shows the conversation state."
        }
    }

    private func handleCenterTap() {
        switch controller.state {
        case .speaking, .thinking:
            controller.interrupt()
        case .paused:
            controller.resume()
        default:
            break
        }
    }

    private func announce(_ state: VoiceModeController.State) {
        switch state {
        case .listening:
            AccessibilityAnnouncer.announceLocalized("Listening")
        case .speaking:
            AccessibilityAnnouncer.announceLocalized("Speaking")
        case .paused:
            AccessibilityAnnouncer.announceLocalized("Paused")
        default:
            break
        }
    }
}

private struct VoiceStateOrb: View {
    let tint: Color
    let level: Float
    let animating: Bool
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !animating)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = (reduceMotion || !animating) ? 0 : 0.05 * sin(time * 1.9)
            let live = CGFloat(min(1, max(0, level))) * 0.32
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10))
                    .scaleEffect(1.0 + CGFloat(breath) * 1.8 + live * 0.9)
                Circle()
                    .fill(tint.opacity(0.18))
                    .scaleEffect(0.76 + CGFloat(breath) * 1.3 + live * 0.6)
                Circle()
                    .fill(tint.opacity(0.85))
                    .scaleEffect(0.52 + CGFloat(breath) + live * 0.35)
            }
        }
        .frame(width: 190, height: 190)
        .accessibilityHidden(true)
    }
}
#endif
