// EnterpriseModelsExploreView.swift
// Replaces the Explore models tab when a Noema Teams policy carries an explicit model
// allowlist: a curated list of company-approved models, no search. Rows open the same
// ExploreDetailView used by the regular Explore flow, so downloads work identically.
import SwiftUI

struct EnterpriseModelsExploreView: View {
    let allowedModelIDs: [String]

    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var downloadController: DownloadController
    @ObservedObject private var enterpriseManager = EnterprisePolicyManager.shared

    @State private var selected: ModelDetails?
    @State private var loadingID: String?
    @State private var failedID: String?

    private var registry: HuggingFaceRegistry {
        HuggingFaceRegistry(token: UserDefaults.standard.string(forKey: "huggingFaceToken") ?? "")
    }

    var body: some View {
        List {
            Section {
                ForEach(allowedModelIDs, id: \.self) { modelID in
                    modelRow(modelID)
                }
            } header: {
                Label(LocalizedStringKey("Managed by your organization"), systemImage: "building.2.fill")
            } footer: {
                Text(LocalizedStringKey("Your organization limits Explore to these approved models."))
            }
            if allowedModelIDs.isEmpty {
                Section {
                    Text(LocalizedStringKey("No models are approved for your roles yet."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $selected) { detail in
            ExploreDetailView(
                detail: detail,
                downloadController: downloadController,
                remoteDownloadTargetBackendID: nil,
                formatFilter: nil
            )
            .environmentObject(modelManager)
            .environmentObject(chatVM)
#if os(macOS)
            .frame(minWidth: 640, idealWidth: 720, minHeight: 640, idealHeight: 760)
#endif
        }
    }

    private func isDownloaded(_ modelID: String) -> Bool {
        modelManager.downloadedModels.contains { $0.modelID.caseInsensitiveCompare(modelID) == .orderedSame }
    }

    private func modelRow(_ modelID: String) -> some View {
        Button {
            Task { await openDetails(modelID) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: (modelID as NSString).lastPathComponent)
                        .foregroundStyle(.primary)
                    Text(verbatim: modelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if failedID == modelID {
                        Text(LocalizedStringKey("Couldn't load this model's details."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer()
                if loadingID == modelID {
                    ProgressView()
                } else if isDownloaded(modelID) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openDetails(_ modelID: String) async {
        guard loadingID == nil else { return }
        failedID = nil
        loadingID = modelID
        defer { loadingID = nil }
        do {
            selected = try await registry.details(for: modelID)
        } catch {
            failedID = modelID
        }
    }
}
