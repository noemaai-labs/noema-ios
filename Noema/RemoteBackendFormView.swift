import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RemoteBackendFormView: View {
    @Environment(\.dismiss) private var dismiss
#if os(macOS)
    @Environment(\.macModalDismiss) private var macModalDismiss
#endif
    let onSave: (RemoteBackendDraft) async throws -> Void

    @State private var draft = RemoteBackendDraft()
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?
    @State private var chatPathEdited = false
    @State private var modelsPathEdited = false
    @State private var updatingDefaults = false
    @State private var lastEndpointType: RemoteBackend.EndpointType = .openAI
    @State private var nameEdited = false

    private enum Field: Hashable {
        case name, baseURL, hostID, chatPath, modelsPath, auth
        case openRouterAPIKey
        case customModel(Int)
    }

    var body: some View {
#if os(macOS)
        macBody
#else
        navigationBody
#endif
    }

#if !os(macOS)
    private var navigationBody: some View {
        NavigationStack {
            Form {
                requirementsSection
                backendSection
                endpointTypeSection
                endpointPathsSection
                ollamaHelpSection
                authenticationSection
                modelIdentifiersSection
            }
            .formStyle(.grouped)
            .navigationTitle(LocalizedStringKey("Custom Backend"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { prepareDefaults() }
            .onChange(of: draft.endpointType, perform: handleEndpointTypeChange)
            .onChange(of: draft.chatPath) { _ in
                if !updatingDefaults { chatPathEdited = true }
            }
            .onChange(of: draft.modelsPath) { _ in
                if !updatingDefaults { modelsPathEdited = true }
            }
            .onChange(of: draft.name) { _ in
                if !updatingDefaults { nameEdited = true }
            }
                .alert(LocalizedStringKey("Unable to Save"), isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    Button(LocalizedStringKey("OK"), role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "")
                }
        }
    }
#else
    private var navigationBody: some View { EmptyView() }
#endif

#if os(macOS)
    private var macBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MacInfoNote(icon: "square.and.pencil") {
                        Text(LocalizedStringKey("Field requirements will depend on your specific backend deployment."))
                    }

                    MacFormCard(title: LocalizedStringKey("Backend")) {
                        backendFields
                    }

                    MacFormCard(title: LocalizedStringKey("Endpoint Type")) {
                        EndpointTypeGrid(selection: $draft.endpointType)
                    }

                    if !draft.endpointType.isRelay && !draft.endpointType.isOpenRouter {
                        MacFormCard(title: LocalizedStringKey("Endpoints")) {
                            endpointPathFields
                        }
                    }

                    if draft.endpointType == .ollama {
                        MacInfoNote(icon: "info.circle") {
                            Text(LocalizedStringKey("When connecting from another device, point the base URL to your computer (for example http://192.168.0.10:11434) and start Ollama with `OLLAMA_HOST=0.0.0.0` so it accepts remote clients."))
                        }
                    }

                    if !draft.endpointType.isRelay {
                        MacFormCard(title: LocalizedStringKey("Authentication")) {
                            authenticationFields
                        }
                    }

                    MacFormCard(title: LocalizedStringKey("Model Identifiers")) {
                        modelIdentifierFields
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
                .padding(.vertical, 16)

            HStack(spacing: 12) {
                Button(LocalizedStringKey("Cancel")) { close() }
                    .buttonStyle(.plain)
                Spacer()
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.9)
                }
                Button(LocalizedStringKey("Save")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .disabled(!canSave || isSaving)
            }
            .padding(.top, 0)
        }
        .padding(EdgeInsets(top: 24, leading: 28, bottom: 24, trailing: 28))
        .task { prepareDefaults() }
        .onChange(of: draft.endpointType, perform: handleEndpointTypeChange)
        .onChange(of: draft.chatPath) { _ in
            if !updatingDefaults { chatPathEdited = true }
        }
        .onChange(of: draft.modelsPath) { _ in
            if !updatingDefaults { modelsPathEdited = true }
        }
        .onChange(of: draft.name) { _ in
            if !updatingDefaults { nameEdited = true }
        }
        .alert(LocalizedStringKey("Unable to Save"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(LocalizedStringKey("OK"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
#endif

    @ViewBuilder
    private var requirementsSection: some View {
        Section { requirementsContent }
    }

    @ViewBuilder
    private var requirementsContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey("Field requirements will depend on your specific backend deployment."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
    }

#if os(macOS)
#endif

    @ViewBuilder
    private var backendSection: some View {
        Section(LocalizedStringKey("Backend")) { backendFields }
    }

    @ViewBuilder
    private var backendFields: some View {
        TextField(LocalizedStringKey("Name"), text: $draft.name)
            .focused($focusedField, equals: .name)
#if !os(macOS)
            .platformAutocapitalization(.words)
#else
            .textFieldStyle(.roundedBorder)
#endif
        backendDetailFields
        if let warning = loopbackWarningText {
            Label(warning, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var backendDetailFields: some View {
        if draft.endpointType.isRelay {
#if os(macOS)
            TextField(LocalizedStringKey("CloudKit container identifier"), text: $draft.baseURL)
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: Field.baseURL)
                .textFieldStyle(.roundedBorder)
#endif
            TextField(LocalizedStringKey("Host device ID"), text: $draft.relayHostDeviceID)
#if !os(macOS)
                .platformAutocapitalization(.never)
#endif
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: Field.hostID)
#if os(macOS)
                .textFieldStyle(.roundedBorder)
#endif
#if (os(iOS) || os(visionOS)) && canImport(CoreBluetooth)
            RelayBluetoothDiscoveryView(containerID: $draft.baseURL,
                                        hostDeviceID: $draft.relayHostDeviceID,
                                        lanURL: $draft.relayLANURL,
                                        apiToken: $draft.relayAPIToken,
                                        wifiSSID: $draft.relayWiFiSSID)
                .padding(.top, 8)
#endif
        } else {
            TextField(LocalizedStringKey("Base URL"), text: $draft.baseURL)
#if canImport(UIKit)
                .platformKeyboardType(.url)
#endif
#if !os(macOS)
                .platformAutocapitalization(.never)
#endif
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: Field.baseURL)
#if os(macOS)
                .textFieldStyle(.roundedBorder)
#endif
        }
    }

    @ViewBuilder
    private var endpointTypeSection: some View {
        Section(LocalizedStringKey("Endpoint Type")) {
#if os(macOS)
            EndpointTypeGrid(selection: $draft.endpointType)
#else
            EndpointTypeSelectionBoxes(selection: $draft.endpointType)
#endif
        }
    }

    @ViewBuilder
    private var endpointPathsSection: some View {
        if !draft.endpointType.isRelay && !draft.endpointType.isOpenRouter {
            Section(LocalizedStringKey("Endpoints")) { endpointPathFields }
        }
    }

    @ViewBuilder
    private var endpointPathFields: some View {
        TextField(draft.endpointType.defaultChatPath, text: $draft.chatPath)
#if !os(macOS)
            .platformAutocapitalization(.never)
#endif
            .autocorrectionDisabled(true)
            .focused($focusedField, equals: .chatPath)
#if os(macOS)
            .textFieldStyle(.roundedBorder)
#endif
        TextField(draft.endpointType.defaultModelsPath, text: $draft.modelsPath)
#if !os(macOS)
            .platformAutocapitalization(.never)
#endif
            .autocorrectionDisabled(true)
            .focused($focusedField, equals: .modelsPath)
#if os(macOS)
            .textFieldStyle(.roundedBorder)
#endif
    }

    @ViewBuilder
    private var ollamaHelpSection: some View {
        if draft.endpointType == .ollama {
            Section { ollamaHelpContent }
        }
    }

    @ViewBuilder
    private var ollamaHelpContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(LocalizedStringKey("When connecting from another device, point the base URL to your computer (for example http://192.168.0.10:11434) and start Ollama with `OLLAMA_HOST=0.0.0.0` so it accepts remote clients."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "info.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var authenticationSection: some View {
        if !draft.endpointType.isRelay {
            Section(LocalizedStringKey("Authentication")) { authenticationFields }
        }
    }

    @ViewBuilder
    private var authenticationFields: some View {
        if draft.endpointType.isOpenRouter {
            SecureField(LocalizedStringKey("OpenRouter API key"), text: $draft.openRouterAPIKey)
#if !os(macOS)
                .platformAutocapitalization(.never)
#endif
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .openRouterAPIKey)
#if os(macOS)
                .textFieldStyle(.roundedBorder)
#endif
            Link(LocalizedStringKey("Create OpenRouter API Key"), destination: URL(string: "https://openrouter.ai/keys")!)
            Text(LocalizedStringKey("OpenRouter uses standard Bearer API-key authentication. We'll verify the key before saving this endpoint."))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            TextField(LocalizedStringKey("Auth header (optional)"), text: $draft.authHeader, axis: .vertical)
#if !os(macOS)
                .platformAutocapitalization(.never)
#endif
                .autocorrectionDisabled(true)
                .focused($focusedField, equals: .auth)
#if os(macOS)
                .textFieldStyle(.roundedBorder)
#endif
        }
    }

    @ViewBuilder
    private var modelIdentifiersSection: some View {
        Section(LocalizedStringKey("Model Identifiers")) { modelIdentifierFields }
    }

    @ViewBuilder
    private var modelIdentifierFields: some View {
        ForEach(Array(draft.customModelIDs.enumerated()), id: \.offset) { index, _ in
            HStack(alignment: .top, spacing: 8) {
                TextField(LocalizedStringKey("Model identifier"), text: customModelBinding(at: index), axis: .vertical)
#if !os(macOS)
                    .platformAutocapitalization(.never)
#endif
                    .autocorrectionDisabled(true)
                    .focused($focusedField, equals: .customModel(index))
#if os(macOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    if draft.customModelIDs.count > 1 {
                        Button {
                            removeCustomModelField(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(LocalizedStringKey("Remove identifier"))
                    }
            }
        }
        Button {
            addCustomModelField()
        } label: {
            Label(LocalizedStringKey("Add Identifier"), systemImage: "plus.circle")
        }
        .buttonStyle(.borderless)
        Text(LocalizedStringKey("Specify your model identifiers, or reload your custom models later."))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
#if os(macOS)
        ToolbarItemGroup(placement: .automatic) {
            Button(LocalizedStringKey("Cancel")) { close() }
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text(LocalizedStringKey("Save"))
                }
            }
            .disabled(!canSave || isSaving)
        }
#else
        ToolbarItem(placement: .cancellationAction) {
            Button(LocalizedStringKey("Cancel")) { close() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView()
                } else {
                    Text(LocalizedStringKey("Save"))
                }
            }
            .disabled(!canSave || isSaving)
        }
#endif
    }

    private func prepareDefaults() {
        draft.chatPath = draft.endpointType.defaultChatPath
        draft.modelsPath = draft.endpointType.defaultModelsPath
        chatPathEdited = false
        modelsPathEdited = false
        nameEdited = false
        lastEndpointType = draft.endpointType
        applyRelayDefaultsIfNeeded()
    }

    private func handleEndpointTypeChange(_ newValue: RemoteBackend.EndpointType) {
        let previousType = lastEndpointType
        updatingDefaults = true
        let trimmedChat = draft.chatPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !chatPathEdited || trimmedChat == previousType.defaultChatPath.lowercased() {
            draft.chatPath = newValue.defaultChatPath
            chatPathEdited = false
        }
        let trimmedModels = draft.modelsPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !modelsPathEdited || trimmedModels == previousType.defaultModelsPath.lowercased() {
            draft.modelsPath = newValue.defaultModelsPath
            modelsPathEdited = false
        }
        updatingDefaults = false
        lastEndpointType = newValue
        applyRelayDefaultsIfNeeded()
    }

    private func applyRelayDefaultsIfNeeded() {
        if draft.endpointType.isOpenRouter {
            updatingDefaults = true
            defer { updatingDefaults = false }
            let canonical = RemoteBackend.openRouterDefaultBaseURL.absoluteString
            if draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != canonical {
                draft.baseURL = canonical
            }
            if !nameEdited && draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draft.name = draft.endpointType.displayName
            }
            return
        }
#if !os(macOS)
        guard draft.endpointType.isRelay else { return }
        let canonical = RelayConfiguration.containerIdentifier
        if draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != canonical {
            draft.baseURL = canonical
        }
#endif
    }

    private var canSave: Bool {
        let hasName = !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBase = !draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if draft.endpointType == .noemaRelay {
            let hasHost = !draft.relayHostDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasName && hasBase && hasHost
        }
        if draft.endpointType.isRelay {
            return hasName && hasBase
        }
        if draft.endpointType.isOpenRouter {
            let hasKey = !draft.openRouterAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return hasName && hasBase && hasKey
        }
        return hasName && hasBase
    }

    private var loopbackWarningText: String? {
        guard draft.usesLoopbackHost else { return nil }
        var message = String(localized: "Connections to localhost may not work from other devices. Replace it with your machine's LAN IP address to allow remote access.")
        if draft.endpointType == .ollama {
            message += " " + String(localized: "Launch Ollama with `OLLAMA_HOST=0.0.0.0` so it can accept remote clients.")
        }
        return message
    }

    private func save() async {
        guard !isSaving else { return }
        focusedField = nil
        isSaving = true
        do {
            if draft.endpointType.isOpenRouter {
                _ = try await RemoteBackendAPI.verifyOpenRouterAPIKey(draft.openRouterAPIKey)
            }
            try await onSave(draft)
            close()
        } catch {
            if let backendError = error as? RemoteBackendError {
                errorMessage = backendError.errorDescription ?? "Unknown error"
            } else {
                errorMessage = RemoteBackend.localizedErrorDescription(for: error)
            }
        }
        isSaving = false
    }

    private func close() {
#if os(macOS)
        macModalDismiss()
#else
        dismiss()
#endif
    }

    private func customModelBinding(at index: Int) -> Binding<String> {
        Binding<String> {
            guard draft.customModelIDs.indices.contains(index) else { return "" }
            return draft.customModelIDs[index]
        } set: { newValue in
            while draft.customModelIDs.count <= index {
                draft.customModelIDs.append("")
            }
            if draft.customModelIDs[index] != newValue {
                draft.customModelIDs[index] = newValue
            }
        }
    }

    private func addCustomModelField() {
        draft.appendCustomModelSlot()
        focusedField = .customModel(max(0, draft.customModelIDs.count - 1))
    }

    private func removeCustomModelField(at index: Int) {
        draft.removeCustomModel(at: index)
        let newCount = draft.customModelIDs.count
        if let currentFocus = focusedField, case .customModel(let focusedIndex) = currentFocus {
            if focusedIndex == index {
                focusedField = .customModel(min(index, max(0, newCount - 1)))
            } else if focusedIndex > index {
                focusedField = .customModel(focusedIndex - 1)
            }
        }
    }
}

#if os(macOS)
private struct EndpointTypeGrid: View {
    @Binding var selection: RemoteBackend.EndpointType
    @State private var hovered: RemoteBackend.EndpointType?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16, alignment: .leading)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(RemoteBackend.EndpointType.remoteEndpointOptions) { type in
                let isSelected = selection == type
                let isHovered = hovered == type

                Button {
                    selection = type
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(isSelected ? 0.22 : 0.12))
                                    .frame(width: 40, height: 40)
                                Image(systemName: type.symbolName)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(isSelected ? Color.accentColor : Color.accentColor.opacity(0.75))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(type.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(type.description)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                            .opacity(0.08)
                        let details = type.isRelay
                            ? String(localized: "Uses Noema Relay configuration")
                            : String.localizedStringWithFormat(
                                String(localized: "Chat: %@\nModels: %@"),
                                type.defaultChatPath,
                                type.defaultModelsPath
                            )
                        Text(details)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(
                                isSelected
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(isHovered ? 0.09 : 0.04)
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.primary.opacity(isSelected ? 0.35 : 0.08), lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hovered = hovering ? type : (hovered == type ? nil : hovered)
                }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selection)
    }
}

private struct MacFormCard<Content: View>: View {
    var title: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(FontTheme.heading(size: 15))
                .foregroundStyle(AppTheme.text)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}

private struct MacInfoNote<Content: View>: View {
    var icon: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            content
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AppTheme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
    }
}
#endif

#if (os(iOS) || os(visionOS)) && canImport(CoreBluetooth)
private struct RelayBluetoothDiscoveryView: View {
    @Binding var containerID: String
    @Binding var hostDeviceID: String
    @Binding var lanURL: String
    @Binding var apiToken: String
    @Binding var wifiSSID: String
    @StateObject private var scanner = RelayBluetoothScanner()

    @State private var connectionPhase: ConnectionPhase = .idle

    private enum ConnectionPhase: Equatable {
        case idle
        case testing(UUID)
        case confirmed(UUID)
        case failed(UUID, String)

        static func == (lhs: ConnectionPhase, rhs: ConnectionPhase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case let (.testing(a), .testing(b)): return a == b
            case let (.confirmed(a), .confirmed(b)): return a == b
            case let (.failed(aID, aMessage), .failed(bID, bMessage)): return aID == bID && aMessage == bMessage
            default: return false
            }
        }

        var relayID: UUID? {
            switch self {
            case .idle: return nil
            case .testing(let id): return id
            case .confirmed(let id): return id
            case .failed(let id, _): return id
            }
        }
    }

    private var isActiveScan: Bool {
        switch scanner.state {
        case .scanning, .poweringOn:
            return true
        default:
            return false
        }
    }

    private var isTestingConnection: Bool {
        if case .testing = connectionPhase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            proximityGuidance
            scanningCard
            if !scanner.discovered.isEmpty {
                discoveredList
            } else if isActiveScan {
                scanningHint
            }
            if let feedback = connectionFeedback {
                Text(feedback.text)
                    .font(.footnote)
                    .foregroundStyle(feedback.color)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onDisappear { scanner.stopScanning() }
        .animation(.easeInOut(duration: 0.25), value: scanner.discovered.count)
        .animation(.easeInOut(duration: 0.25), value: connectionPhase)
    }

    private var stateDescription: String {
        switch scanner.state {
        case .idle:
            return String(localized: "Keep this device near the Mac that's running Noema Relay to import its settings.", locale: LocalizationManager.preferredLocale())
        case .poweringOn:
            return String(localized: "Enabling Bluetooth…", locale: LocalizationManager.preferredLocale())
        case .scanning:
            return String(localized: "Scanning nearby devices. Move closer to your Mac if you don't see it yet.", locale: LocalizationManager.preferredLocale())
        case .unauthorized:
            return String(localized: "Bluetooth access is required to pair with the Mac relay.", locale: LocalizationManager.preferredLocale())
        case .error(let message):
            return message
        }
    }

    private var proximityGuidance: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 48, height: 48)
                .overlay(
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey("Stay close to your Mac"))
                    .font(.subheadline.weight(.semibold))
                Text(LocalizedStringKey("Keep this iPhone or iPad within a few feet of the Mac that is advertising Noema Relay. We'll pull the relay details automatically once connected."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
    }

    private var scanningCard: some View {
        VStack(spacing: 16) {
            ProximityPulse(isActive: isActiveScan)
                .frame(maxWidth: .infinity)
                .frame(height: 180)

            let title: LocalizedStringKey = isActiveScan
                ? LocalizedStringKey("Scanning for your Mac relay…")
                : LocalizedStringKey("Ready to scan nearby relays")
            Text(title)
                .font(.headline)

            Text(stateDescription)
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            scanButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .tertiarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var scanButton: some View {
        if #available(iOS 15.0, macOS 12.0, macCatalyst 15.0, *) {
            if isActiveScan {
                Button {
                    toggleScan()
                } label: {
                    scanButtonLabel
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isTestingConnection)
            } else {
                Button {
                    toggleScan()
                } label: {
                    scanButtonLabel
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isTestingConnection)
            }
        } else {
            Button {
                toggleScan()
            } label: {
                Label(isActiveScan ? LocalizedStringKey("Stop Scanning") : LocalizedStringKey("Start Scan"),
                      systemImage: isActiveScan ? "stop.circle.fill" : "dot.radiowaves.up.forward")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(isActiveScan ? Color.clear : Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(DefaultButtonStyle())
            .controlSize(.large)
            .disabled(isTestingConnection)
        }
    }

    private var scanButtonLabel: some View {
        Label(isActiveScan ? LocalizedStringKey("Stop Scanning") : LocalizedStringKey("Start Scan"),
              systemImage: isActiveScan ? "stop.circle.fill" : "dot.radiowaves.up.forward")
        .frame(maxWidth: .infinity)
    }

    private var scanningHint: some View {
        Text(LocalizedStringKey("Move your device closer to the Mac running the relay if it doesn't appear right away. Bluetooth discovery usually completes within a few seconds."))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private var discoveredList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey("Nearby Relays"))
                .font(.headline)

            LazyVStack(spacing: 12) {
                ForEach(scanner.discovered) { relay in
                    Button {
                        selectRelay(relay)
                    } label: {
                        relayRow(for: relay)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTestingConnection && connectionPhase.relayID != relay.id)
                }
            }
        }
    }

    private func relayRow(for relay: RelayBluetoothScanner.DiscoveredRelay) -> some View {
        let isHighlighted = isRelayHighlighted(relay)
        return HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 44, height: 44)
                .overlay(
                    Image(systemName: "macbook")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(relay.payload.deviceName)
                    .font(.subheadline.weight(.semibold))
                Text(relay.payload.provider)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(proximityDescription(for: relay))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !relay.payload.hostDeviceID.isEmpty {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Host ID: %@", locale: LocalizationManager.preferredLocale()),
                            relay.payload.hostDeviceID
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                }
                if let lan = relay.payload.lanURL, !lan.isEmpty {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "LAN URL: %@", locale: LocalizationManager.preferredLocale()),
                            lan
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                }
                if let ssid = relay.payload.wifiSSID, !ssid.isEmpty {
                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "Wi-Fi: %@", locale: LocalizationManager.preferredLocale()),
                            ssid
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)

            connectionStatus(for: relay)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.1) : Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHighlighted ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.05), lineWidth: isHighlighted ? 2 : 1)
        )
    }

    @ViewBuilder
    private func connectionStatus(for relay: RelayBluetoothScanner.DiscoveredRelay) -> some View {
        switch connectionPhase {
        case .testing(let id) where id == relay.id:
            VStack(spacing: 6) {
                ProgressView()
                Text(LocalizedStringKey("Testing"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .confirmed(let id) where id == relay.id:
            VStack(spacing: 6) {
                if #available(iOS 17.0, visionOS 1.0, *) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.green)
                        .transition(.scale.combined(with: .opacity))
                        .symbolEffect(.bounce, options: .repeat(1), value: connectionPhase.relayID == relay.id)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(Color.green)
                        .transition(.scale.combined(with: .opacity))
                }
                Text("Connected")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
        case .failed(let id, _ ) where id == relay.id:
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color.orange)
                Text(LocalizedStringKey("Try again"))
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        default:
            SignalStrengthView(rssi: relay.rssi)
        }
    }

    private var connectionFeedback: (text: String, color: Color)? {
        switch connectionPhase {
        case .confirmed:
            return (String(localized: "Connection verified. Relay details imported from this Mac.", locale: LocalizationManager.preferredLocale()), .green)
        case .failed(_, let message):
            return (message, .red)
        default:
            return nil
        }
    }

    private func toggleScan() {
        if isActiveScan {
            scanner.stopScanning()
        } else {
            connectionPhase = .idle
            scanner.startScanning()
        }
    }

    private func selectRelay(_ relay: RelayBluetoothScanner.DiscoveredRelay) {
        withAnimation(.easeInOut(duration: 0.2)) {
            connectionPhase = .testing(relay.id)
        }

        Task {
            do {
                try await scanner.performConnectionTest(for: relay)
                await MainActor.run {
                    containerID = relay.payload.containerID
                    hostDeviceID = relay.payload.hostDeviceID
                    lanURL = relay.payload.lanURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    apiToken = relay.payload.apiToken ?? ""
                    wifiSSID = relay.payload.wifiSSID ?? ""
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8, blendDuration: 0.2)) {
                        connectionPhase = .confirmed(relay.id)
                    }
                }
                await MainActor.run {
                    scanner.stopScanning()
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        connectionPhase = .failed(relay.id, message)
                    }
                }
            }
        }
    }

    private func isRelayHighlighted(_ relay: RelayBluetoothScanner.DiscoveredRelay) -> Bool {
        switch connectionPhase {
        case .testing(let id), .confirmed(let id):
            return id == relay.id
        case .failed(let id, _):
            return id == relay.id
        case .idle:
            return false
        }
    }

private func proximityDescription(for relay: RelayBluetoothScanner.DiscoveredRelay) -> String {
    let value = relay.rssi.doubleValue
    let locale = LocalizationManager.preferredLocale()
    if value == 0 {
        return String(localized: "Signal strength unavailable", locale: locale)
    }
    switch value {
    case let v where v >= -55:
        return String(localized: "Very close", locale: locale)
    case let v where v >= -65:
        return String(localized: "Nearby", locale: locale)
    case let v where v >= -75:
        return String(localized: "Within one room", locale: locale)
    default:
        return String(localized: "Move closer for a stronger signal", locale: locale)
    }
}
}

private struct ProximityPulse: View {
    var isActive: Bool
    @State private var ripple = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(isActive ? 0.35 : 0.0), lineWidth: 2)
                .frame(width: ripple ? 180 : 110, height: ripple ? 180 : 110)
                .opacity(isActive ? (ripple ? 0.0 : 0.35) : 0.0)

            Circle()
                .stroke(Color.accentColor.opacity(isActive ? 0.25 : 0.0), lineWidth: 2)
                .frame(width: ripple ? 150 : 90, height: ripple ? 150 : 90)
                .opacity(isActive ? (ripple ? 0.0 : 0.3) : 0.0)

            Circle()
                .fill(Color.accentColor.opacity(0.18))
                .frame(width: 96, height: 96)
                .overlay(
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )
        }
        .frame(width: 180, height: 180)
        .onAppear(perform: updateAnimation)
        .onChange(of: isActive) { _ in updateAnimation() }
        .animation(
            isActive
                ? .easeOut(duration: 1.8).repeatForever(autoreverses: false)
                : .default,
            value: ripple
        )
    }

    private func updateAnimation() {
        guard isActive else {
            ripple = false
            return
        }
        ripple = false
        DispatchQueue.main.async {
            ripple = true
        }
    }
}

private struct SignalStrengthView: View {
    var rssi: NSNumber

    private var filledBars: Int {
        let value = rssi.doubleValue
        if value == 0 { return 0 }
        if value >= -55 { return 4 }
        if value >= -65 { return 3 }
        if value >= -75 { return 2 }
        if value >= -85 { return 1 }
        return 0
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < filledBars ? Color.accentColor : Color.accentColor.opacity(0.2))
                        .frame(width: 5, height: CGFloat(8 + index * 6))
                }
            }
            Text(LocalizedStringKey("Signal"))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
