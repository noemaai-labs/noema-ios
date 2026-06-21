import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct RAGInspectorSummaryContent: View {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    @ObservedObject var datasetManager: DatasetManager
    let openInspector: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: hasRAGSnapshot ? "doc.text.magnifyingglass" : "doc.text")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(hasRAGSnapshot ? Color.green : Color.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(LocalizedStringKey("RAG Inspector"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(verbatim: summaryLine)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: openInspector) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LocalizedStringKey("Open RAG Inspector"))
            }

            HStack(spacing: 8) {
                RAGInspectorCapsule(title: LocalizedStringKey("Dataset"), value: datasetValue)
                RAGInspectorCapsule(title: LocalizedStringKey("Chunks"), value: chunkValue)
                RAGInspectorCapsule(title: LocalizedStringKey("Score"), value: scoreValue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: openInspector)
    }

    private var snapshot: ChatVM.RAGInspectionSnapshot? {
        chatVM.latestRAGInspectionSnapshot
    }

    private var activeDataset: LocalDataset? {
        chatVM.activeSessionDataset ?? modelManager.activeDataset ?? datasetManager.selectedDataset
    }

    private var hasRAGSnapshot: Bool {
        snapshot != nil
    }

    private var summaryLine: String {
        if let info = snapshot?.info {
            return "\(info.datasetName) · \(methodValue(info.method))"
        }
        if let activeDataset {
            return String.localizedStringWithFormat(
                String(localized: "%@ ready for retrieval inspection"),
                activeDataset.name
            )
        }
        return String(localized: "No active dataset")
    }

    private var datasetValue: String {
        activeDataset == nil ? String(localized: "None") : String(localized: "Active")
    }

    private var chunkValue: String {
        guard let info = snapshot?.info else { return String(localized: "None") }
        return "\(info.injectedChunkCount)/\(info.retrievedChunkCount)"
    }

    private var scoreValue: String {
        guard let score = snapshot?.citations.compactMap(\.score).first else {
            return String(localized: "N/A")
        }
        return Self.scoreFormatter.string(from: NSNumber(value: score)) ?? String(format: "%.2f", score)
    }

    private func methodValue(_ method: ChatVM.Msg.RAGInjectionInfo.Method?) -> String {
        switch method {
        case .fullContent:
            return String(localized: "Full Content")
        case .rag:
            return String(localized: "Chunk Retrieval")
        case nil:
            return String(localized: "Deciding")
        }
    }

    private static let scoreFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

struct RAGInspectorView: View {
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var datasetManager: DatasetManager
    @AppStorage("ragMaxChunks") private var ragMaxChunks = 5
    @AppStorage("ragMinScore") private var ragMinScore = 0.5
    @State private var refreshedAt = Date()
    @State private var embeddingReady = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var copyMessage: String?

    var body: some View {
        Form {
            Section(LocalizedStringKey("Retrieval Run")) {
                RAGInspectorStatusRow(
                    title: LocalizedStringKey("Latest Retrieval"),
                    value: snapshot == nil ? String(localized: "Waiting") : String(localized: "Captured"),
                    systemImage: snapshot == nil ? "hourglass" : "checkmark.circle.fill",
                    tint: snapshot == nil ? .orange : .green
                )
                RAGInspectorValueRow(title: LocalizedStringKey("Active Dataset"), value: activeDataset?.name ?? String(localized: "None"))
                RAGInspectorValueRow(title: LocalizedStringKey("Index State"), value: indexStateValue)
                if let info = snapshot?.info {
                    RAGInspectorValueRow(title: LocalizedStringKey("Stage"), value: stageValue(info.stage))
                    RAGInspectorValueRow(title: LocalizedStringKey("Method"), value: methodValue(info.method))
                    RAGInspectorValueRow(title: LocalizedStringKey("Decision"), value: info.decisionReason)
                    RAGInspectorValueRow(title: LocalizedStringKey("Chunks"), value: "\(info.injectedChunkCount)/\(info.retrievedChunkCount)")
                    RAGInspectorValueRow(title: LocalizedStringKey("Trimmed Chunks"), value: "\(info.trimmedChunkCount)")
                    RAGInspectorValueRow(title: LocalizedStringKey("Partial Chunk"), value: flag(info.partialChunkInjected))
                    RAGInspectorValueRow(title: LocalizedStringKey("Context Budget"), value: tokenPair(used: info.injectedContextTokens, total: info.contextBudgetTokens))
                    RAGInspectorValueRow(title: LocalizedStringKey("Configured Context"), value: "\(info.configuredContextTokens)")
                    RAGInspectorValueRow(title: LocalizedStringKey("Reserved Response"), value: "\(info.reservedResponseTokens)")
                }
                RAGInspectorValueRow(title: LocalizedStringKey("Last Refreshed"), value: refreshedAt.formatted(date: .omitted, time: .standard))
            }

            Section(LocalizedStringKey("Query")) {
                RAGInspectorValueRow(title: LocalizedStringKey("User Prompt"), value: snapshot?.queryText ?? String(localized: "No captured query"))
                RAGInspectorValueRow(title: LocalizedStringKey("Assistant Preview"), value: snapshot?.responsePreview ?? String(localized: "No assistant response captured"))
            }

            Section(LocalizedStringKey("Retrieved Chunks")) {
                if let citations = snapshot?.citations, !citations.isEmpty {
                    ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                        RAGInspectorChunkCard(index: index + 1, citation: citation)
                    }
                } else {
                    RAGInspectorValueRow(title: LocalizedStringKey("Chunks"), value: String(localized: "No chunks captured yet"))
                }
            }

            Section(LocalizedStringKey("Injected Context")) {
                RAGInspectorValueRow(title: LocalizedStringKey("Characters"), value: "\(snapshot?.retrievedContext.count ?? 0)")
                RAGInspectorValueRow(title: LocalizedStringKey("Preview"), value: injectedPreview)
                Button {
                    copyInjectedContext()
                } label: {
                    Label(LocalizedStringKey("Copy Injected Context"), systemImage: "doc.on.doc")
                }
                .disabled(snapshot?.retrievedContext.isEmpty ?? true)
                if let copyMessage {
                    Text(verbatim: copyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(LocalizedStringKey("Retrieval Settings")) {
                RAGInspectorValueRow(title: LocalizedStringKey("Max Chunks"), value: "\(ragMaxChunks)")
                RAGInspectorValueRow(title: LocalizedStringKey("Similarity Threshold"), value: String(format: "%.2f", ragMinScore))
                RAGInspectorValueRow(title: LocalizedStringKey("Embedding Model"), value: embeddingReady ? String(localized: "Ready") : String(localized: "Not Ready"))
                RAGInspectorValueRow(title: LocalizedStringKey("Dataset Status"), value: processingStatusValue)
            }

            Section(LocalizedStringKey("Inspector Export")) {
                Button {
                    refreshedAt = Date()
                    generateExport()
                } label: {
                    Label(LocalizedStringKey("Generate RAG Report"), systemImage: "doc.badge.gearshape")
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label(LocalizedStringKey("Share RAG JSON"), systemImage: "square.and.arrow.up")
                    }
                    RAGInspectorValueRow(title: LocalizedStringKey("Report File"), value: exportURL.lastPathComponent)
                }

                if let exportError {
                    RAGInspectorValueRow(title: LocalizedStringKey("Export Error"), value: exportError)
                }
            }
        }
        .navigationTitle(LocalizedStringKey("RAG Inspector"))
        .task {
            embeddingReady = await EmbeddingModel.shared.isReady()
        }
    }

    private var snapshot: ChatVM.RAGInspectionSnapshot? {
        chatVM.latestRAGInspectionSnapshot
    }

    private var activeDataset: LocalDataset? {
        chatVM.activeSessionDataset ?? modelManager.activeDataset ?? datasetManager.selectedDataset
    }

    private var indexStateValue: String {
        guard let dataset = activeDataset else { return String(localized: "No Dataset") }
        if dataset.requiresReindex { return String(localized: "Needs Reindex") }
        return dataset.isIndexed ? String(localized: "Indexed") : String(localized: "Not Indexed")
    }

    private var processingStatusValue: String {
        guard let dataset = activeDataset else { return String(localized: "No Dataset") }
        guard let status = datasetManager.processingStatus[dataset.datasetID] else {
            return dataset.isIndexed ? String(localized: "Indexed") : String(localized: "Idle")
        }
        return "\(stageValue(status.stage)) · \(Int(status.progress * 100))%"
    }

    private var injectedPreview: String {
        guard let context = snapshot?.retrievedContext.trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else {
            return String(localized: "No injected context captured")
        }
        if context.count <= 1800 { return context }
        return String(context.prefix(1800)) + "\n…"
    }

    private func flag(_ value: Bool) -> String {
        value ? String(localized: "Yes") : String(localized: "No")
    }

    private func tokenPair(used: Int, total: Int) -> String {
        "\(used)/\(total)"
    }

    private func stageValue(_ stage: ChatVM.Msg.RAGInjectionInfo.Stage) -> String {
        switch stage {
        case .deciding:
            return String(localized: "Deciding")
        case .chosen:
            return String(localized: "Chosen")
        case .injected:
            return String(localized: "Injected")
        }
    }

    private func stageValue(_ stage: DatasetProcessingStage) -> String {
        switch stage {
        case .extracting:
            return String(localized: "Extracting")
        case .compressing:
            return String(localized: "Compressing")
        case .embedding:
            return String(localized: "Embedding")
        case .completed:
            return String(localized: "Completed")
        case .failed:
            return String(localized: "Failed")
        }
    }

    private func methodValue(_ method: ChatVM.Msg.RAGInjectionInfo.Method?) -> String {
        switch method {
        case .fullContent:
            return String(localized: "Full Content")
        case .rag:
            return String(localized: "Chunk Retrieval")
        case nil:
            return String(localized: "Deciding")
        }
    }

    private func copyInjectedContext() {
        guard let context = snapshot?.retrievedContext, !context.isEmpty else { return }
#if canImport(UIKit)
        UIPasteboard.general.string = context
        copyMessage = String(localized: "Injected context copied")
#else
        copyMessage = String(localized: "Copy is unavailable on this platform")
#endif
    }

    private func generateExport() {
        let info = snapshot?.info
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "activeDataset": activeDatasetPayload,
            "embeddingReady": embeddingReady,
            "settings": [
                "ragMaxChunks": ragMaxChunks,
                "ragMinScore": ragMinScore
            ],
            "latestRun": [
                "messageID": nullable(snapshot?.messageID.uuidString),
                "timestamp": nullable(snapshot.map { ISO8601DateFormatter().string(from: $0.timestamp) }),
                "query": nullable(snapshot?.queryText),
                "stage": nullable(info?.stage.rawValue),
                "method": nullable(info?.method?.rawValue),
                "decisionReason": nullable(info?.decisionReason),
                "requestedMaxChunks": nullable(info?.requestedMaxChunks),
                "retrievedChunkCount": nullable(info?.retrievedChunkCount),
                "injectedChunkCount": nullable(info?.injectedChunkCount),
                "trimmedChunkCount": nullable(info?.trimmedChunkCount),
                "partialChunkInjected": nullable(info?.partialChunkInjected),
                "fullContentEstimateTokens": nullable(info?.fullContentEstimateTokens),
                "configuredContextTokens": nullable(info?.configuredContextTokens),
                "reservedResponseTokens": nullable(info?.reservedResponseTokens),
                "contextBudgetTokens": nullable(info?.contextBudgetTokens),
                "injectedContextTokens": nullable(info?.injectedContextTokens),
                "retrievedContextCharacters": nullable(snapshot?.retrievedContext.count),
                "citations": snapshot?.citations.enumerated().map { index, citation in
                    [
                        "index": index + 1,
                        "source": nullable(citation.source),
                        "score": nullable(citation.score),
                        "characters": citation.text.count,
                        "text": citation.text
                    ]
                } ?? []
            ]
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("noema-rag-inspector-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private var activeDatasetPayload: [String: Any] {
        guard let activeDataset else {
            return ["state": "none"]
        }
        return [
            "datasetID": activeDataset.datasetID,
            "name": activeDataset.name,
            "source": activeDataset.source,
            "sizeMB": activeDataset.sizeMB,
            "isIndexed": activeDataset.isIndexed,
            "requiresReindex": activeDataset.requiresReindex,
            "url": activeDataset.url.path
        ]
    }

    private func nullable(_ value: Any?) -> Any {
        value ?? NSNull()
    }
}

extension ChatVM {
    struct RAGInspectionSnapshot: Equatable {
        let messageID: UUID
        let timestamp: Date
        let queryText: String?
        let responsePreview: String?
        let retrievedContext: String
        let citations: [Msg.Citation]
        let info: Msg.RAGInjectionInfo?
    }

    var latestRAGInspectionSnapshot: RAGInspectionSnapshot? {
        let messages = msgs
        guard !messages.isEmpty else { return nil }

        for index in messages.indices.reversed() {
            let message = messages[index]
            let retrievedContext = message.retrievedContext ?? ""
            let citations = message.citations ?? []
            let hasRAGData = message.ragInjectionInfo != nil
                || !retrievedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !citations.isEmpty
            guard hasRAGData else { continue }

            let query = messages[..<index]
                .last { $0.role == "🧑‍💻" }?
                .text
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return RAGInspectionSnapshot(
                messageID: message.id,
                timestamp: message.timestamp,
                queryText: query?.isEmpty == true ? nil : query,
                responsePreview: message.trimmedVisibleAssistantText.isEmpty ? nil : String(message.trimmedVisibleAssistantText.prefix(700)),
                retrievedContext: retrievedContext,
                citations: citations,
                info: message.ragInjectionInfo
            )
        }

        return nil
    }
}

private struct RAGInspectorCapsule: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct RAGInspectorValueRow: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct RAGInspectorStatusRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(verbatim: value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

private struct RAGInspectorChunkCard: View {
    let index: Int
    let citation: ChatVM.Msg.Citation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String.localizedStringWithFormat(String(localized: "Chunk %d"), index))
                    .font(.body.weight(.semibold))
                Spacer(minLength: 8)
                if let score = citation.score {
                    Text(verbatim: Self.scoreFormatter.string(from: NSNumber(value: score)) ?? String(format: "%.2f", score))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

            if let source = citation.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                Label {
                    Text(verbatim: source)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                } icon: {
                    Image(systemName: "doc")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Text(verbatim: citation.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    private static let scoreFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
