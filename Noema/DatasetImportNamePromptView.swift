import SwiftUI

struct DatasetImportNamePromptView: View {
    @Binding var datasetName: String
    let onCancel: () -> Void
    let onImport: () async -> Void

    @EnvironmentObject private var datasetManager: DatasetManager
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LocalizedStringKey("Dataset name"), text: $datasetName)
                        .focused($isNameFocused)
#if os(iOS) || os(visionOS)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled(true)
#endif
                } header: {
                    Text(LocalizedStringKey("Name your dataset"))
                }
                if !datasetManager.mediaImportProgressItems.isEmpty {
                    Section {
                        ForEach(datasetManager.mediaImportProgressItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: mediaImportIconName(for: item.state))
                                    .foregroundStyle(mediaImportColor(for: item.state))
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.filename)
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(nil)
                                    Text(mediaImportStatusText(for: item.state))
                                        .font(.caption2)
                                        .foregroundStyle(mediaImportColor(for: item.state))
                                        .lineLimit(nil)
                                }
                            }
                        }
                    } header: {
                        Text(LocalizedStringKey("Media transcription progress"))
                    }
                }
            }
            .navigationTitle(LocalizedStringKey("Import Dataset"))
#if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Cancel")) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("Import")) {
                        Task { await onImport() }
                    }
                    .disabled(datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                // Defer focus to avoid "attempt to present while already presenting" warnings on iOS.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isNameFocused = true
                }
            }
        }
    }

    private func mediaImportIconName(for state: DatasetManager.MediaImportProgressState) -> String {
        switch state {
        case .pending: return "clock"
        case .transcribing: return "waveform"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func mediaImportColor(for state: DatasetManager.MediaImportProgressState) -> Color {
        switch state {
        case .pending: return .secondary
        case .transcribing: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private func mediaImportStatusText(for state: DatasetManager.MediaImportProgressState) -> LocalizedStringKey {
        switch state {
        case .pending: return "Waiting"
        case .transcribing: return "Transcribing"
        case .succeeded: return "Imported"
        case .failed: return "Failed"
        }
    }
}
