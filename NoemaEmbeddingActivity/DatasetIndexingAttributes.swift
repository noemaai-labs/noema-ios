// DatasetIndexingAttributes.swift
import ActivityKit
import Foundation

// IMPORTANT: This file mirrors the app-side definitions in
// `Noema/DatasetLiveActivityController.swift`. ActivityKit matches the
// activity to this widget by type name and Codable shape, so the two
// declarations must stay byte-for-byte compatible.

enum DatasetProcessingStage: String, Codable, Sendable {
    case extracting
    case compressing
    case embedding
    case completed
    case failed
}

struct DatasetIndexingAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Current pipeline stage, used for icon and tint selection.
        var stage: DatasetProcessingStage
        /// 0.0 ... 1.0 progress within the pipeline.
        var progress: Double
        /// Localized stage title rendered verbatim (localization lives app-side).
        var stageTitle: String
        /// Optional localized status detail line.
        var detail: String?
        /// Optional localized "~1m 05s" remaining-time string rendered verbatim.
        var etaText: String?
        /// True while the app is backgrounded and work is suspended; the
        /// widget renders an "open the app to continue" call to action.
        var isPaused: Bool
    }

    var datasetID: String
    var name: String
}
