#if os(iOS)
import SwiftUI
import PhotosUI
import VisionKit
import UIKit

struct PassScannerFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var modelManager: AppModelManager
    @ObservedObject private var store = BoardingPassDraftStore.shared
    @ObservedObject private var walletService = WalletPassService.shared
    @AppStorage("offGrid") private var offGrid = false
    @AppStorage(PassScannerSettings.keepScansWithDraftsKey) private var keepScansWithDrafts = false
    @AppStorage(PassExtractionModelCatalog.extractionThinkingEnabledKey) private var extractionThinkingEnabled = false

    @State private var showDocumentCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var draft: BoardingPassDraft?
    @State private var isExtracting = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showSavedMessage = false
    @State private var showRawModelOutput = false
    @State private var rawModelOutput: String?
    @State private var draftPendingDeletion: BoardingPassDraft?

    private let extractor = BoardingPassExtractor()

    var body: some View {
        NavigationStack {
            Group {
                if let draft {
                    PassConfirmationView(
                        draft: Binding(
                            get: { self.draft ?? draft },
                            set: { updated in
                                self.draft = updated
                                store.save(updated)
                            }
                        ),
                        offGrid: offGrid,
                        isSigning: walletService.isSigning,
                        onSave: saveCurrentDraft,
                        onAddToWallet: addCurrentDraftToWallet
                    )
                } else {
                    PassScannerStartView(
                        isExtracting: isExtracting,
                        setupMessage: extractionSetupMessage,
                        showsThinkingToggle: activeExtractionModelSupportsThinking,
                        thinkingEnabled: $extractionThinkingEnabled,
                        drafts: store.drafts,
                        onScan: openScanner,
                        onSelectDraft: { draft in
                            self.draft = draft
                            rawModelOutput = nil
                        },
                        onDeleteDraft: { draft in
                            draftPendingDeletion = draft
                        },
                        pickerItem: $pickerItem
                    )
                }
            }
            .navigationTitle(LocalizedStringKey("Scan Pass"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Close")) { dismiss() }
                }
                if draft != nil || rawModelOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(LocalizedStringKey("Save")) { saveCurrentDraft() }
                                .disabled(draft == nil)
                            Button(LocalizedStringKey("Show Raw Output")) { showRawModelOutput = true }
                                .disabled(rawModelOutput?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel(Text(LocalizedStringKey("More")))
                    }
                }
            }
        }
        .sheet(isPresented: $showRawModelOutput) {
            RawModelOutputView(output: rawModelOutput ?? "")
        }
        .fullScreenCover(isPresented: $showDocumentCamera) {
            DocumentCameraScannerView(
                onComplete: { image in
                    showDocumentCamera = false
                    Task { await extract(image) }
                },
                onCancel: { showDocumentCamera = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await loadPickerItem(newItem) }
        }
        .alert(LocalizedStringKey("Pass Scanner"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(LocalizedStringKey("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(LocalizedStringKey("Draft Saved"), isPresented: $showSavedMessage) {
            Button(LocalizedStringKey("OK"), role: .cancel) { }
        } message: {
            Text(statusMessage ?? String(localized: "Saved to Pass Scanner drafts on this device."))
        }
        .confirmationDialog(LocalizedStringKey("Delete Saved Pass"), isPresented: Binding(
            get: { draftPendingDeletion != nil },
            set: { if !$0 { draftPendingDeletion = nil } }
        ), titleVisibility: .visible) {
            Button(LocalizedStringKey("Delete Saved Pass"), role: .destructive) {
                deletePendingDraft()
            }
            Button(LocalizedStringKey("Cancel"), role: .cancel) {
                draftPendingDeletion = nil
            }
        } message: {
            Text(LocalizedStringKey("This permanently removes the saved Wallet pass draft and any stored scan image. This action cannot be undone."))
        }
    }

    private func openScanner() {
        if let extractionSetupMessage {
            errorMessage = extractionSetupMessage
            return
        }
        guard VNDocumentCameraViewController.isSupported else {
            errorMessage = String(localized: "Document scanning is not available on this device. Import a photo instead.")
            return
        }
        showDocumentCamera = true
    }

    private func loadPickerItem(_ item: PhotosPickerItem) async {
        defer { Task { @MainActor in pickerItem = nil } }
        if let extractionSetupMessage {
            await MainActor.run {
                errorMessage = extractionSetupMessage
            }
            return
        }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            await MainActor.run {
                errorMessage = String(localized: "Couldn’t load the selected image.")
            }
            return
        }
        await extract(image)
    }

    @MainActor
    private func extract(_ image: UIImage) async {
        isExtracting = true
        rawModelOutput = nil
        defer { isExtracting = false }
        do {
            let result = try await extractor.extractResult(from: image, models: modelManager.downloadedModels)
            rawModelOutput = result.rawModelOutput
            var extracted = result.draft
            if keepScansWithDrafts, let data = image.jpegData(compressionQuality: 0.88) {
                let url = try store.writeRawImageData(data, for: extracted.id)
                extracted.rawImagePath = url.path
            }
            draft = extracted
            store.save(extracted)
        } catch let error as PassVisionExtractionOutputError {
            rawModelOutput = error.rawOutput
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var extractionSetupMessage: String? {
        let hasSelectedModel = !PassExtractionModelCatalog.activeModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !PassExtractionModelCatalog.activeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSelectedModel else {
            return String(localized: "Select a pass extraction model in Settings before scanning passes.")
        }
        guard let model = PassExtractionModelCatalog.activeModel(from: modelManager.downloadedModels) else {
            return String(localized: "The selected pass extraction model is missing. Choose another vision model in Settings.")
        }
        guard PassExtractionModelCatalog.isCompatibleVisionModel(model) else {
            return String(localized: "The selected pass extraction model cannot read images. Choose a local vision model.")
        }
        return nil
    }

    private var activeExtractionModelSupportsThinking: Bool {
        guard let model = PassExtractionModelCatalog.activeModel(from: modelManager.downloadedModels) else {
            return false
        }
        return PassExtractionModelCatalog.supportsExtractionThinking(model)
    }

    private func saveCurrentDraft() {
        guard let draft else { return }
        store.save(draft)
        statusMessage = String(localized: "Saved to Pass Scanner drafts on this device.")
        showSavedMessage = true
    }

    private func addCurrentDraftToWallet() {
        guard let draft else { return }
        store.save(draft)
        guard draft.isReadyForWallet else {
            errorMessage = String(localized: "Fix the required fields before adding this pass to Wallet.")
            return
        }
        guard !offGrid else {
            errorMessage = PassSigningError.offGrid.localizedDescription
            return
        }
        Task {
            do {
                try await walletService.signAndAdd(draft)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func deletePendingDraft() {
        guard let pending = draftPendingDeletion else { return }
        store.delete(pending)
        if draft?.id == pending.id {
            draft = nil
        }
        draftPendingDeletion = nil
    }
}

private struct RawModelOutputView: View {
    let output: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "No raw model output is available.") : output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle(LocalizedStringKey("Raw Model Output"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Close")) { dismiss() }
                }
            }
        }
    }
}

private struct PassScannerStartView: View {
    let isExtracting: Bool
    let setupMessage: String?
    let showsThinkingToggle: Bool
    @Binding var thinkingEnabled: Bool
    let drafts: [BoardingPassDraft]
    let onScan: () -> Void
    let onSelectDraft: (BoardingPassDraft) -> Void
    let onDeleteDraft: (BoardingPassDraft) -> Void
    @Binding var pickerItem: PhotosPickerItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(LocalizedStringKey("Scan or Import a Pass"))
                        .font(.title2.weight(.semibold))
                    Text(LocalizedStringKey("Noema reads each pass with your selected local vision model, using barcode and text evidence to prepare a draft for review."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LocalizedStringKey("Saved drafts stay in Pass Scanner on this device."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 12) {
                    if let setupMessage {
                        Label(setupMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if showsThinkingToggle {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(LocalizedStringKey("Model Thinking"), isOn: $thinkingEnabled)
                                .padding(.horizontal, 12)
                                .frame(height: 44)
                                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .accessibilityIdentifier("pass-scanner-model-thinking")
                            Text(LocalizedStringKey("Greatly increases scan time."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                        }
                    }

                    Button(action: onScan) {
                        Text(LocalizedStringKey("Scan with Camera"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(setupMessage != nil)
                    .accessibilityIdentifier("pass-scanner-camera")

                    PhotosPicker(selection: $pickerItem, matching: .images) {
                        Text(LocalizedStringKey("Import Photo"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(setupMessage != nil)
                    .accessibilityIdentifier("pass-scanner-import-photo")
                }

                if isExtracting {
                    ProgressView(LocalizedStringKey("Reading pass…"))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                }

                savedDraftsList
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    @ViewBuilder
    private var savedDraftsList: some View {
        if !drafts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalizedStringKey("Saved Drafts"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(drafts) { draft in
                        HStack(spacing: 0) {
                            Button {
                                onSelectDraft(draft)
                            } label: {
                                SavedDraftRow(draft: draft)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Button(role: .destructive) {
                                onDeleteDraft(draft)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.red)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(LocalizedStringKey("Delete Saved Pass")))
                        }

                        if draft.id != drafts.last?.id {
                            Divider()
                                .padding(.leading, 12)
                        }
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.top, 4)
        }
    }
}

private struct SavedDraftRow: View {
    let draft: BoardingPassDraft

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(draft.transportMode.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(12)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(LocalizedStringKey("Open saved draft")))
    }

    private var title: String {
        let service = draft.journey.serviceNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = "\(draft.journey.originCode) -> \(draft.journey.destinationCode)"
        return service.isEmpty ? route : "\(service) - \(route)"
    }

    private var subtitle: String {
        let traveler = draft.traveler.fullName.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedAt = draft.provenance.capturedAt.formatted(date: .abbreviated, time: .shortened)
        let prefix = traveler.isEmpty ? String(localized: "Saved Draft") : traveler
        return String.localizedStringWithFormat(String(localized: "%@ - saved %@"), prefix, savedAt)
    }
}

private struct PassConfirmationView: View {
    @Binding var draft: BoardingPassDraft
    let offGrid: Bool
    let isSigning: Bool
    let onSave: () -> Void
    let onAddToWallet: () -> Void

    private let fields: [BoardingPassEditableField] = BoardingPassEditableField.allCases
    private let themes: [PassTheme] = [
        .init(name: "Navy", background: "#0F3D5E", foreground: "#FFFFFF", label: "#DDEBFF", color: Color(red: 0.06, green: 0.24, blue: 0.37)),
        .init(name: "Graphite", background: "#1F2328", foreground: "#FFFFFF", label: "#D6D8DA", color: Color(red: 0.12, green: 0.14, blue: 0.16)),
        .init(name: "Ruby", background: "#7A1F2B", foreground: "#FFFFFF", label: "#FFDDE2", color: Color(red: 0.48, green: 0.12, blue: 0.17)),
        .init(name: "Forest", background: "#1F5A44", foreground: "#FFFFFF", label: "#DDF5E9", color: Color(red: 0.12, green: 0.35, blue: 0.27)),
        .init(name: "Sky", background: "#2F6FED", foreground: "#FFFFFF", label: "#EAF1FF", color: Color(red: 0.18, green: 0.44, blue: 0.93)),
        .init(name: "Teal", background: "#007C89", foreground: "#FFFFFF", label: "#DDF7FA", color: Color(red: 0.0, green: 0.49, blue: 0.54)),
        .init(name: "Plum", background: "#5B2A86", foreground: "#FFFFFF", label: "#F0E7FA", color: Color(red: 0.36, green: 0.16, blue: 0.53)),
        .init(name: "Magenta", background: "#B4236E", foreground: "#FFFFFF", label: "#FFE4F1", color: Color(red: 0.71, green: 0.14, blue: 0.43)),
        .init(name: "Copper", background: "#9A4D16", foreground: "#FFFFFF", label: "#FFEBD8", color: Color(red: 0.60, green: 0.30, blue: 0.09)),
        .init(name: "Gold", background: "#D6A012", foreground: "#111111", label: "#3F3320", color: Color(red: 0.84, green: 0.63, blue: 0.07)),
        .init(name: "Mint", background: "#6FCF97", foreground: "#111111", label: "#284434", color: Color(red: 0.44, green: 0.81, blue: 0.59)),
        .init(name: "Silver", background: "#D7DBE0", foreground: "#111111", label: "#42464D", color: Color(red: 0.84, green: 0.86, blue: 0.88))
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                PassPreviewCard(draft: draft)
                warningStack
                passTypePicker
                fieldEditor
                themePicker
                onlineSigningNotice
                actionRow
            }
            .padding(18)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("pass-confirmation-view")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let data = draft.thumbnailJPEGData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .frame(width: 64, height: 64)
                    .overlay(Image(systemName: "doc.text.viewfinder"))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(confidenceTitle)
                    .font(.headline)
                Text(draft.transportMode.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var confidenceTitle: String {
        let percent = Int((draft.confidence.overall * 100).rounded())
        return String.localizedStringWithFormat(String(localized: "Confidence: %d%%"), percent)
    }

    @ViewBuilder
    private var warningStack: some View {
        let issues = summaryIssues
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { issue in
                    Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private var fieldEditor: some View {
        VStack(spacing: 10) {
            ForEach(fields) { field in
                VStack(alignment: .leading, spacing: 5) {
                    Text(field.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(field.title, text: Binding(
                        get: { draft.stringValue(for: field) },
                        set: { draft.applyUserEdit(field: field, value: $0) }
                    ))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 10)
                    .frame(height: 40)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("pass-field-\(field.rawValue)")

                    ForEach(fieldIssues(for: field)) { issue in
                        Label(issue.message, systemImage: issue.severity == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                            .font(.caption)
                            .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var passTypePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("Pass Type"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(BoardingPassTransportMode.allCases) { mode in
                    Button {
                        setTransportMode(mode)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: mode.iconName)
                                .frame(width: 18)
                            Text(mode.displayName)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                            Spacer(minLength: 0)
                            if draft.transportMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .background(passTypeBackground(mode), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(draft.transportMode == mode ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: draft.transportMode == mode ? 1.5 : 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pass-type-\(mode.rawValue)")
                }
            }
        }
    }

    private func setTransportMode(_ mode: BoardingPassTransportMode) {
        draft.applyTransportMode(mode)
    }

    private func passTypeBackground(_ mode: BoardingPassTransportMode) -> Color {
        draft.transportMode == mode ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground)
    }

    private var summaryIssues: [ValidationIssue] {
        draft.validation.issues.filter { issue in
            !fields.contains { $0.matches(validationField: issue.field) }
        }
    }

    private func fieldIssues(for field: BoardingPassEditableField) -> [ValidationIssue] {
        draft.validation.issues.filter { field.matches(validationField: $0.field) }
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("Theme Color"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 12)], spacing: 12) {
                ForEach(themes) { theme in
                    Button {
                        draft.walletPresentation = .solidBackground(theme.background, for: draft.transportMode)
                    } label: {
                        Circle()
                            .fill(theme.color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(theme.background == draft.walletPresentation.backgroundColor ? 0.7 : 0.12), lineWidth: theme.background == draft.walletPresentation.backgroundColor ? 2 : 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(theme.name))
                }
            }

            ColorPicker(
                selection: Binding(
                    get: { Color(hexRGB: draft.walletPresentation.backgroundColor) },
                    set: { draft.walletPresentation = .solidBackground($0.hexRGB, for: draft.transportMode) }
                ),
                supportsOpacity: false
            ) {
                Text(LocalizedStringKey("Custom Background"))
                    .font(.subheadline)
            }
        }
    }

    private var onlineSigningNotice: some View {
        Label {
            Text(offGrid ? LocalizedStringKey("Off-grid Mode is on, so Wallet signing is disabled. Turn off Off-grid Mode and connect to the internet to add this pass.") : LocalizedStringKey("Internet is required to sign and add this pass to Wallet. Noema sends only the confirmed draft JSON to its signer, not the scan image."))
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: offGrid ? "wifi.slash" : "lock.shield")
        }
        .foregroundStyle(offGrid ? Color.orange : Color.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((offGrid ? Color.orange : Color.blue).opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: onSave) {
                Text(LocalizedStringKey("Save Draft"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Button(action: onAddToWallet) {
                if isSigning {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(offGrid ? LocalizedStringKey("Internet Required") : LocalizedStringKey("Sign Online & Add"))
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .minimumScaleFactor(0.76)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!draft.isReadyForWallet || isSigning || offGrid)
            .accessibilityIdentifier("pass-add-to-wallet")
        }
    }
}

private struct PassTheme: Identifiable {
    var id: String { background }
    var name: String
    var background: String
    var foreground: String
    var label: String
    var color: Color
}

private extension BoardingPassTransportMode {
    var iconName: String {
        switch self {
        case .air: return "airplane"
        case .train: return "tram.fill"
        case .bus: return "bus.fill"
        case .boat: return "ferry.fill"
        case .generic: return "ticket.fill"
        }
    }
}

private extension Color {
    init(hexRGB: String) {
        self = PassPreviewCard.color(from: hexRGB)
    }

    var hexRGB: String {
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return "#0F3D5E"
        }
        return String(
            format: "#%02X%02X%02X",
            Int(max(0, min(1, red)) * 255),
            Int(max(0, min(1, green)) * 255),
            Int(max(0, min(1, blue)) * 255)
        )
    }
}

private struct PassPreviewCard: View {
    let draft: BoardingPassDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(draft.issuer.name.isEmpty ? "Noema" : draft.issuer.name)
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(draft.journey.serviceNumber)
                    .font(.headline.monospacedDigit())
            }
            Text("\(draft.journey.originCode) -> \(draft.journey.destinationCode)")
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            HStack(spacing: 20) {
                previewField(label: String(localized: "Passenger"), value: draft.traveler.fullName)
                previewField(label: String(localized: "Seat"), value: draft.journey.seat ?? "--")
                previewField(label: String(localized: "Gate"), value: draft.journey.gate ?? draft.journey.platform ?? "--")
            }

            HStack {
                previewField(label: String(localized: "Board"), value: draft.journey.boardingTime ?? "--")
                previewField(label: String(localized: "Depart"), value: draft.journey.departureTime)
                Spacer()
                Image(systemName: barcodeIcon)
                    .font(.system(size: 28, weight: .semibold))
            }
        }
        .foregroundStyle(Color.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.color(from: draft.walletPresentation.backgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var barcodeIcon: String {
        switch draft.barcode.symbology {
        case .qr: return "qrcode"
        default: return "barcode.viewfinder"
        }
    }

    private func previewField(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.72))
            Text(value.isEmpty ? "--" : value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    static func color(from hex: String) -> Color {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return Color(red: 0.06, green: 0.24, blue: 0.37)
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

private struct DocumentCameraScannerView: UIViewControllerRepresentable {
    let onComplete: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete, onCancel: onCancel)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onComplete: (UIImage) -> Void
        let onCancel: () -> Void

        init(onComplete: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                onCancel()
                return
            }
            onComplete(scan.imageOfPage(at: 0))
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            onCancel()
        }
    }
}
#endif
