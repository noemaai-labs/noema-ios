#if os(iOS)
import SwiftUI

struct PassExtractionModelsView: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var refreshToken = UUID()

    private var selectedPath: String {
        _ = refreshToken
        return PassExtractionModelCatalog.activeModel(from: modelManager.downloadedModels)?.url.path
            ?? PassExtractionModelCatalog.activeModelPath
    }

    private var compatibleModels: [LocalModel] {
        PassExtractionModelCatalog.compatibleModels(from: modelManager.downloadedModels)
    }

    private var selectedModelMissing: Bool {
        PassExtractionModelCatalog.isSelectedModelMissing(in: modelManager.downloadedModels)
    }

    var body: some View {
        List {
            if selectedModelMissing {
                Section {
                    Label(LocalizedStringKey("Selected extraction model is missing"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if compatibleModels.isEmpty {
                    Text(LocalizedStringKey("Install a local vision model before scanning passes."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(compatibleModels, id: \.url) { model in
                        Button {
                            PassExtractionModelCatalog.setActiveModel(model)
                            refreshToken = UUID()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedPath == model.url.path ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selectedPath == model.url.path ? Color.accentColor : Color.secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name)
                                        .foregroundStyle(AppTheme.text)
                                    Text(modelDetailText(model))
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text(LocalizedStringKey("Downloaded Vision Models"))
            } footer: {
                Text(LocalizedStringKey("Pass Scanner uses this model to read tickets and returns structured fields for review."))
            }

            Section {
                ForEach(PassExtractionModelCatalog.recommendedModelIDs, id: \.self) { modelID in
                    HStack {
                        Text(modelID)
                        Spacer()
                        Text(LocalizedStringKey("Explore"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(LocalizedStringKey("Recommended"))
            } footer: {
                Text(LocalizedStringKey("Download one of these from Explore, then return here to select it."))
            }
        }
        .navigationTitle(LocalizedStringKey("Pass Extraction Model"))
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(modelManager.$downloadedModels) { _ in
            refreshToken = UUID()
        }
    }

    private func modelDetailText(_ model: LocalModel) -> String {
        let size = String(format: "%.1f GB", model.sizeGB)
        return "\(model.format.displayName) - \(model.quant) - \(size)"
    }
}
#endif
