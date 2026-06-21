import SwiftUI

@MainActor
final class BackgroundModelUnloadController: ObservableObject {
    private var unloadTask: Task<Void, Never>?

    func cancelPendingUnload() {
        unloadTask?.cancel()
        unloadTask = nil
    }

    func scheduleIfNeeded(
        sceneState: BackgroundModelUnloadPolicy.SceneState,
        chatVM: ChatVM,
        modelManager: AppModelManager
    ) {
        cancelPendingUnload()

        let policy = BackgroundModelUnloadPolicy(defaults: .standard)
        let profile = makeProfile(sceneState: sceneState, chatVM: chatVM, modelManager: modelManager)
        let decision = policy.decision(for: profile)
        guard case let .unload(delaySeconds, reason) = decision else {
            Task { await logger.log("[BackgroundUnload] keep reason=\(String(describing: decision))") }
            return
        }

        unloadTask = Task { [weak self, weak chatVM] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard !Task.isCancelled, let chatVM else { return }
            guard await MainActor.run(body: { !chatVM.isStreaming }) else { return }
            Task { await logger.log("[BackgroundUnload] unload reason=\(reason) delay_s=\(String(format: "%.0f", delaySeconds))") }
            await chatVM.unload()
            await MainActor.run {
                self?.unloadTask = nil
            }
        }
    }

    private func makeProfile(
        sceneState: BackgroundModelUnloadPolicy.SceneState,
        chatVM: ChatVM,
        modelManager: AppModelManager
    ) -> BackgroundModelUnloadPolicy.Profile {
        let model = activeLocalModel(chatVM: chatVM, modelManager: modelManager)
        let settings = chatVM.loadedModelSettings ?? model.map { modelManager.settings(for: $0) }
        let budget = DeviceRAMInfo.current().conservativeLimitBytes()
        return BackgroundModelUnloadPolicy.Profile(
            hasActiveChatModel: chatVM.hasActiveChatModel,
            isStreaming: chatVM.isStreaming,
            format: chatVM.loadedModelFormat ?? model?.format,
            estimatedWorkingSetBytes: estimatedWorkingSetBytes(for: model, settings: settings),
            memoryBudgetBytes: budget,
            sceneState: sceneState
        )
    }

    private func activeLocalModel(chatVM: ChatVM, modelManager: AppModelManager) -> LocalModel? {
        if let url = chatVM.loadedModelURL {
            return modelManager.downloadedModels.first { $0.url == url || $0.url.path == url.path }
        }
        return modelManager.loadedModel
    }

    private func estimatedWorkingSetBytes(for model: LocalModel?, settings: ModelSettings?) -> Int64? {
        guard let model, let settings else { return nil }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: model.url.path)[.size]) as? Int64 else {
            return nil
        }
        return ModelRAMAdvisor.estimateAndBudget(
            format: model.format,
            sizeBytes: size,
            contextLength: Int(settings.contextLength),
            layerCount: model.totalLayers > 0 ? model.totalLayers : nil,
            moeInfo: model.moeInfo,
            kvCacheEstimate: model.format == .gguf ? .resolved(from: settings) : .f16F16
        ).estimate
    }
}
