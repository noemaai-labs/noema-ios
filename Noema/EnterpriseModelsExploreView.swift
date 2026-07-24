import SwiftUI

struct EnterpriseModelsExploreView: View {
    let allowedModelIDs: [String]

    @EnvironmentObject var modelManager: AppModelManager
    @EnvironmentObject var chatVM: ChatVM
    @EnvironmentObject var downloadController: DownloadController
#if os(macOS)
    @EnvironmentObject var macModalPresenter: MacModalPresenter
    @EnvironmentObject var tabRouter: TabRouter
#endif
    @ObservedObject private var enterpriseManager = EnterprisePolicyManager.shared

    @State private var selected: ModelDetails?
    @State private var loadingID: String?
    @State private var failedID: String?

    private var registry: HuggingFaceRegistry {
        HuggingFaceRegistry(token: UserDefaults.standard.string(forKey: "huggingFaceToken") ?? "")
    }

    var body: some View {
#if os(macOS)
        macBody
#else
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
        }
#endif
    }

#if os(macOS)
    private var macBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IndustrialSectionHeader(LocalizedStringKey("Managed by your organization")) {
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.5))
                }
                if allowedModelIDs.isEmpty {
                    Text(LocalizedStringKey("No models are approved for your roles yet."))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                } else {
                    VStack(spacing: 2) {
                        ForEach(allowedModelIDs, id: \.self) { modelID in
                            IndustrialHoverRow {
                                modelRow(modelID)
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                Text(LocalizedStringKey("Your organization limits Explore to these approved models."))
                    .industrialStat()
                    .padding(.top, 12)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presentDetail(_ detail: ModelDetails) {
        macModalPresenter.present(
            title: nil,
            subtitle: nil,
            showCloseButton: true,
            dimensions: MacModalDimensions(
                minWidth: 660,
                idealWidth: 720,
                maxWidth: 800,
                minHeight: 620,
                idealHeight: 700,
                maxHeight: 820
            ),
            contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
        ) {
            ExploreDetailView(
                detail: detail,
                downloadController: downloadController,
                remoteDownloadTargetBackendID: nil,
                formatFilter: nil
            )
            .environmentObject(modelManager)
            .environmentObject(chatVM)
            .environmentObject(tabRouter)
        }
    }
#endif

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
#if os(macOS)
                        .controlSize(.small)
#endif
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
            let detail = try await registry.details(for: modelID)
#if os(macOS)
            presentDetail(detail)
#else
            selected = detail
#endif
        } catch {
            failedID = modelID
        }
    }
}
