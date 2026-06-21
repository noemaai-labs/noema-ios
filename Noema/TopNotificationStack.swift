import SwiftUI

struct TopNotificationStack<Manager: ModelLoadingManaging>: View {
    @ObservedObject var datasetManager: DatasetManager
    @ObservedObject var modelManager: Manager
    @ObservedObject var loadingTracker: ModelLoadingProgressTracker

    var body: some View {
        VStack(spacing: 12) {
            EmbeddingLiveActivityView(datasetManager: datasetManager)
            ModelLoadingNotificationView(modelManager: modelManager, loadingTracker: loadingTracker)
        }
    }
}
