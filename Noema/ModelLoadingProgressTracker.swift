// ModelLoadingProgressTracker.swift
import Foundation
import SwiftUI
import NoemaPackages

/// Tracks model loading progress using backend-reported signals when available.
@MainActor
final class ModelLoadingProgressTracker: ObservableObject {
    enum LoadingPhase: Int, CaseIterable, Sendable {
        case initializing
        case loadingFile
        case loadingKernels
        case creatingContext
        case finalizing
        case complete
    }

    @Published var currentPhase: LoadingPhase = .initializing
    @Published var progress: Double = 0.0
    @Published var phaseLabel: String = "Loading"
    @Published var isLoading: Bool = false

    private(set) var loadingFormat: ModelFormat = .gguf

    private var timer: Timer?
    private var loadStartTime: Date = .distantPast
    private var targetProgress: Double = 0.0
    private var backendProgress: Double = 0.0
    private var hasBackendSignal = false
    private let inProgressCap: Double = 0.97
    private let minVisibleDuration: TimeInterval = 0.35

    private var logObserver: NSObjectProtocol?
    private var mlxProgressObserver: NSObjectProtocol?

    init() {
        logObserver = NotificationCenter.default.addObserver(
            forName: .llamaLogMessage,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let self,
                self.isLoading,
                self.loadingFormat == .gguf,
                let message = note.userInfo?["message"] as? String
            else { return }
            self.consumeLlamaLog(message)
        }

        mlxProgressObserver = NotificationCenter.default.addObserver(
            forName: .mlxModelLoadProgress,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let self,
                self.isLoading,
                self.loadingFormat == .mlx,
                let value = note.userInfo?["progress"] as? Double
            else { return }
            self.reportBackendProgress(value)
        }
    }

    @MainActor deinit {
        timer?.invalidate()
        if let observer = logObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mlxProgressObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func startLoading(for format: ModelFormat) {
        loadingFormat = format
        loadStartTime = Date()
        isLoading = true

        currentPhase = .initializing
        phaseLabel = "Loading"
        progress = 0.0
        targetProgress = 0.02
        backendProgress = 0.0
        hasBackendSignal = false

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    /// Reports backend progress in [0, 1]. Values are treated as monotonic.
    func reportBackendProgress(_ value: Double) {
        guard isLoading else { return }
        let clamped = min(inProgressCap, max(0.0, value))
        hasBackendSignal = true
        if clamped > backendProgress {
            backendProgress = clamped
            targetProgress = max(targetProgress, clamped)
            updatePhase(for: clamped)
        }
    }

    func completeLoading() {
        guard isLoading else { return }

        currentPhase = .complete
        phaseLabel = "Ready"
        targetProgress = 1.0
        backendProgress = 1.0

        let elapsed = Date().timeIntervalSince(loadStartTime)
        let delay = max(0.0, minVisibleDuration - elapsed)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.progress = 1.0
            self.isLoading = false
        }
    }

    private func tick() {
        guard isLoading else { return }

        if loadingFormat == .gguf {
            let raw = LlamaServerBridge.loadProgress()
            let loading = LlamaServerBridge.isLoading()
            if loading || raw > 0 {
                // Keep headroom so only explicit completion reaches 100%.
                reportBackendProgress(raw * 0.96)
            }
        }

        let elapsed = Date().timeIntervalSince(loadStartTime)
        let fallback = fallbackProgress(elapsed: elapsed, format: loadingFormat)
        if !hasBackendSignal {
            targetProgress = max(targetProgress, fallback)
            updatePhase(for: targetProgress)
        } else {
            targetProgress = max(targetProgress, min(inProgressCap, fallback * 0.6))
        }

        let destination = min(currentPhase == .complete ? 1.0 : inProgressCap, targetProgress)
        let delta = destination - progress
        if delta > 0 {
            let step = max(0.0025, delta * 0.2)
            progress = min(destination, progress + step)
        }
    }

    private func fallbackProgress(elapsed: TimeInterval, format: ModelFormat) -> Double {
        let tau: TimeInterval
        let cap: Double
        switch format {
        case .gguf:
            tau = 30.0
            cap = 0.55
        case .mlx:
            tau = 18.0
            cap = 0.45
        case .et, .ane:
            tau = 16.0
            cap = 0.42
        case .afm:
            tau = 8.0
            cap = 0.35
        case .coreai:
            tau = 8.0
            cap = 0.35
        }
        let t = max(0, elapsed)
        return min(cap, cap * (1 - exp(-t / tau)))
    }

    private func updatePhase(for value: Double) {
        let p = max(0.0, min(1.0, value))
        switch p {
        case ..<0.08:
            currentPhase = .initializing
        case ..<0.35:
            currentPhase = .loadingFile
        case ..<0.65:
            currentPhase = .loadingKernels
        case ..<0.88:
            currentPhase = .creatingContext
        case ..<0.995:
            currentPhase = .finalizing
        default:
            currentPhase = .complete
        }
    }

    private func consumeLlamaLog(_ message: String) {
        let lower = message.lowercased()
        if lower.contains("loading model from") || lower.contains("loaded meta data") {
            reportBackendProgress(0.25)
            return
        }
        if lower.contains("ggml_metal") || lower.contains("ggml_cuda") || lower.contains("ggml_vulkan") || lower.contains("ggml_cpu") {
            reportBackendProgress(0.55)
            return
        }
        if lower.contains("llama_init_from_model") || lower.contains("llama_new_context_with_model") || lower.contains("kv cache") {
            reportBackendProgress(0.82)
            return
        }
        if lower.contains("model load time") || lower.contains("llama_model_loader: done") {
            reportBackendProgress(0.94)
        }
    }
}

extension ModelLoadingProgressTracker {
    static var preview: ModelLoadingProgressTracker {
        let tracker = ModelLoadingProgressTracker()
        tracker.isLoading = true
        tracker.progress = 0.65
        tracker.currentPhase = .loadingKernels
        tracker.phaseLabel = "Loading"
        return tracker
    }
}

// MARK: - Progress View Component
struct ModelLoadingProgressView: View {
    @ObservedObject var tracker: ModelLoadingProgressTracker

    var body: some View {
        VStack(spacing: 6) {
            Text("Loading")
                .font(.caption2)
                .foregroundColor(.secondary)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 140, height: 4)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: 140 * tracker.progress, height: 4)
                    .animation(.easeInOut(duration: 0.15), value: tracker.progress)
            }
        }
    }
}

// MARK: - Preview
#if DEBUG
#Preview {
    ZStack {
        Color(.systemBackground)
            .ignoresSafeArea()

        VStack {
            Spacer()

            ModelLoadingNotificationView(
                modelManager: {
                    let manager = PreviewModelManager()
                    manager.loadingModelName = "Llama-3.2-3B-Instruct-Q4"
                    return manager
                }(),
                loadingTracker: ModelLoadingProgressTracker.preview
            )

            Spacer()
        }
    }
}
#endif
