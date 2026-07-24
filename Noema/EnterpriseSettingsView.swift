import QuickLook
import SwiftUI

struct EnterpriseSettingsView: View {
    @ObservedObject private var manager = EnterprisePolicyManager.shared

    @State private var companyCode = ""
    @State private var email = ""
    @State private var verificationCode = ""
    @State private var confirmDisconnect = false
    @State private var isRefreshing = false
    @State private var refreshDone = false
    @State private var approvalPollTask: Task<Void, Never>?
    @State private var expandedDatasetID: String?
    @State private var datasetFiles: [String: [EnterpriseDatasetFile]] = [:]
    @State private var loadingFilesID: String?
    @State private var previewURL: URL?
    @State private var previewLoadingPath: String?
    @State private var previewErrorDatasetID: String?

    var body: some View {
        platformContent
            .quickLookPreview($previewURL)
            .animation(.snappy(duration: 0.3), value: manager.state)
            .onAppear { startApprovalPollingIfNeeded() }
            .onDisappear { approvalPollTask?.cancel() }
            .onChange(of: manager.state) { _, _ in startApprovalPollingIfNeeded() }
            .confirmationDialog(
                LocalizedStringKey("Disconnect from this workspace?"),
                isPresented: $confirmDisconnect,
                titleVisibility: .visible
            ) {
                if isDatasetOnlyWorkspace {
                    Button(LocalizedStringKey("Keep company datasets")) {
                        Task { await manager.disconnect(keepDatasets: true) }
                    }
                    Button(LocalizedStringKey("Remove company datasets"), role: .destructive) {
                        Task { await manager.disconnect() }
                    }
                } else {
                    Button(LocalizedStringKey("Leave & delete company data"), role: .destructive) {
                        Task { await manager.disconnect() }
                    }
                }
                Button(LocalizedStringKey("Cancel"), role: .cancel) {}
            } message: {
                if isDatasetOnlyWorkspace {
                    Text(LocalizedStringKey("You can keep saved company datasets on this device as personal datasets, or remove them now."))
                } else {
                    Text(LocalizedStringKey("Your organization uses Full Noema Control: all company datasets on this device are deleted when you leave."))
                }
            }
    }

    /// macOS rebuilds the Form as industrial cards inside the settings sheet;
    /// iOS keeps the native Form plus its navigation title. Shared behaviour
    /// (polling, QuickLook, the disconnect dialog) lives on `body`.
    private var platformContent: some View {
#if os(macOS)
        macBody
#else
        formBody
            .navigationTitle(LocalizedStringKey("Enterprise"))
#endif
    }

    private var formBody: some View {
        Form {
            switch manager.state {
            case .none, .disconnected:
                connectForm
            case .connecting:
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text(LocalizedStringKey("Contacting your workspace…"))
                            .foregroundStyle(.secondary)
                    }
                }
            case .awaitingEmailVerification:
                verificationForm
            case .pendingApproval:
                pendingApprovalSection
            case .connected, .policyExpired, .deviceRevoked, .policyInvalid:
                connectedSections
            }
        }
    }

    /// Dataset-only workspaces let leavers keep saved company datasets; Full Noema
    /// Control mandates deletion on leave.
    private var isDatasetOnlyWorkspace: Bool {
        (manager.policy?.governanceMode ?? "full") == "datasets"
    }

    /// The reconnect deadline + window, only while a trusted connection is in force.
    /// Hidden once the device is revoked/invalid (its data is already gone or denied).
    private var reconnectCountdown: (deadline: Date, days: Int)? {
        guard manager.state == .connected || manager.state == .policyExpired else { return nil }
        guard let deadline = manager.reconnectDeadline, let days = manager.reconnectIntervalDays else { return nil }
        return (deadline, days)
    }

    // MARK: Connect

    private var connectForm: some View {
        Group {
            Section {
                TextField(LocalizedStringKey("Company code"), text: $companyCode)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
#if os(iOS) || os(visionOS)
                    .textInputAutocapitalization(.characters)
#endif
                TextField(LocalizedStringKey("Work email"), text: $email)
                    .autocorrectionDisabled()
#if os(iOS) || os(visionOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
#endif
            } header: {
                Text(LocalizedStringKey("Connect to company"))
            } footer: {
                Text(LocalizedStringKey("Your administrator shares the company code. We'll email you a verification code."))
            }
            Section {
                Button {
                    tapHaptic()
                    Task { await manager.connect(companyCode: companyCode, email: email) }
                } label: {
                    Group {
                        if manager.isBusy {
                            ProgressView()
                        } else {
                            Text(LocalizedStringKey("Connect"))
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(manager.isBusy || companyCode.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@"))
            } footer: {
                errorFooter
            }
        }
    }

    private var verificationForm: some View {
        Group {
            Section {
                TextField(LocalizedStringKey("Verification code"), text: $verificationCode)
                    .font(.title3.monospaced())
                    .autocorrectionDisabled()
#if os(iOS) || os(visionOS)
                    .keyboardType(.numberPad)
#endif
                if let devCode = manager.devVerificationCode {
                    Text("dev code: \(devCode)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(LocalizedStringKey("Check your email"))
            } footer: {
                if let context = manager.storedContext {
                    Text(String(
                        format: String(localized: "We sent a 6-digit code to %@.", locale: LocalizationManager.preferredLocale()),
                        context.email
                    ))
                }
            }
            Section {
                Button {
                    tapHaptic()
                    Task {
                        await manager.submitVerificationCode(verificationCode.trimmingCharacters(in: .whitespaces))
                        verificationCode = ""
                        if case .connected = manager.state { Haptics.success() }
                    }
                } label: {
                    Group {
                        if manager.isBusy {
                            ProgressView()
                        } else {
                            Text(LocalizedStringKey("Verify"))
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .disabled(manager.isBusy || verificationCode.trimmingCharacters(in: .whitespaces).count < 4)
            } footer: {
                errorFooter
            }
            Section {
                Button(LocalizedStringKey("Cancel"), role: .destructive) {
                    manager.cancelEnrollment()
                }
                .buttonStyle(EnterprisePressableRowStyle())
            }
        }
    }

    private var pendingApprovalSection: some View {
        Group {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey("Waiting for admin approval"))
                        if let context = manager.storedContext, let name = context.tenantName {
                            Text(name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text(LocalizedStringKey("An administrator needs to approve your request. You can leave this screen — Noema connects automatically once approved."))
            }
            Section {
                Button(LocalizedStringKey("Cancel request"), role: .destructive) {
                    manager.cancelEnrollment()
                }
            } footer: {
                errorFooter
            }
        }
    }

    // MARK: Connected

    @ViewBuilder
    private var connectedSections: some View {
        if manager.state != .connected {
            Section {
                statusBanner
            }
        }
        if let policy = manager.policy {
            Section {
                workspaceHero(policy)
            }
            .listRowBackground(Color.clear)
            if let countdown = reconnectCountdown {
                Section {
                    ReconnectCountdownView(deadline: countdown.deadline, intervalDays: countdown.days)
                } header: {
                    Text(LocalizedStringKey("Offline access"))
                } footer: {
                    Text(String(
                        format: String(
                            localized: "This device must reconnect to %@ at least once every %lld days. If it stays offline past the deadline, all company data is removed from this device automatically. Going back online resets the countdown.",
                            locale: LocalizationManager.preferredLocale()
                        ),
                        policy.tenantName, Int64(countdown.days)
                    ))
                }
            }
            Section(LocalizedStringKey("Workspace")) {
                row(LocalizedStringKey("Company code"), policy.companyCode, monospaced: true)
                row(LocalizedStringKey("Roles"), policy.roleNames.joined(separator: ", "))
            }
            Section(LocalizedStringKey("Policy")) {
                row(LocalizedStringKey("Version"), "\(policy.policyVersion)")
                row(LocalizedStringKey("Expires"), policy.expiresAt.formatted(date: .abbreviated, time: .shortened))
                if let lastSync = manager.lastSyncAt {
                    row(LocalizedStringKey("Last sync"), lastSync.formatted(date: .abbreviated, time: .shortened))
                }
                row(LocalizedStringKey("Device ID"), String(policy.deviceID.prefix(8)), monospaced: true)
            }
            Section(LocalizedStringKey("What your roles allow")) {
                row(LocalizedStringKey("Tools"), allowSummary(policy.allowedToolNames))
                row(LocalizedStringKey("Model formats"), allowSummary(policy.allowedModelFormats))
                row(LocalizedStringKey("Remote backends"), remoteSummary(policy))
                if policy.requiresOffGrid {
                    Label(LocalizedStringKey("Off-grid mode is required by your organization"), systemImage: "wifi.slash")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            Section(LocalizedStringKey("Company datasets")) {
                if manager.availableDatasets.isEmpty {
                    Text(LocalizedStringKey("No datasets are shared with your roles yet."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.availableDatasets, id: \.enterpriseDatasetID) { manifest in
                        datasetCard(manifest)
                    }
                }
            }
        }
        Section {
            Button {
                runRefresh()
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        if isRefreshing {
                            ProgressView()
#if os(iOS) || os(visionOS)
                                .controlSize(.small)
#endif
                        } else if refreshDone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(width: 24, height: 20)
                    Text(refreshDone ? LocalizedStringKey("Up to date") : LocalizedStringKey("Refresh policy"))
                        .foregroundStyle(refreshDone ? Color.green : Color.accentColor)
                    Spacer()
                }
                .contentShape(Rectangle())
                .animation(.snappy(duration: 0.25), value: isRefreshing)
                .animation(.snappy(duration: 0.25), value: refreshDone)
            }
            .buttonStyle(EnterprisePressableRowStyle())
            .disabled(isRefreshing)
            Button {
                tapHaptic()
                confirmDisconnect = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle")
                        .frame(width: 24, height: 20)
                    Text(LocalizedStringKey("Disconnect"))
                    Spacer()
                }
                .foregroundStyle(.red)
                .contentShape(Rectangle())
            }
            .buttonStyle(EnterprisePressableRowStyle())
        } footer: {
            errorFooter
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch manager.state {
        case .policyExpired:
            Label {
                Text(LocalizedStringKey("Policy expired — Noema keeps enforcing the last policy and will sync when the workspace is reachable."))
            } icon: {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
            }
        case .deviceRevoked:
            Label {
                Text(LocalizedStringKey("This device's access was revoked by your organization. Company datasets were removed."))
            } icon: {
                Image(systemName: "nosign").foregroundStyle(.red)
            }
        case .policyInvalid:
            Label {
                Text(LocalizedStringKey("The last policy from your workspace couldn't be trusted. Restrictions stay active; company datasets are unavailable."))
            } icon: {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.red)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var errorFooter: some View {
        if let message = manager.lastErrorMessage {
            Text(message).foregroundStyle(.red)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(monospaced ? .callout.monospaced() : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func allowSummary(_ list: [String]?) -> String {
        guard let list else {
            return String(localized: "All", locale: LocalizationManager.preferredLocale())
        }
        if list.isEmpty {
            return String(localized: "None", locale: LocalizationManager.preferredLocale())
        }
        return list.map { $0.replacingOccurrences(of: "noema.", with: "") }.joined(separator: ", ")
    }

    private func remoteSummary(_ policy: EnterprisePolicy) -> String {
        guard policy.remoteInferenceAllowed else {
            return String(localized: "Local only", locale: LocalizationManager.preferredLocale())
        }
        if policy.allowedRemoteEndpointTypes == nil && policy.allowedRemoteBackendIDs == nil {
            return String(localized: "All", locale: LocalizationManager.preferredLocale())
        }
        return String(localized: "Restricted", locale: LocalizationManager.preferredLocale())
    }

    // MARK: Company dataset cards

    @ViewBuilder
    private func datasetCard(_ manifest: EnterpriseDatasetManifest) -> some View {
        let isExpanded = expandedDatasetID == manifest.enterpriseDatasetID
        let isInstalled = manager.installedDatasetIDs.contains(manifest.datasetID)
        let isInstalling = manager.installingDatasetIDs.contains(manifest.datasetID)

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedDatasetID = isExpanded ? nil : manifest.enterpriseDatasetID
                }
                if !isExpanded {
                    Task { await loadFiles(manifest) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isInstalled ? Color.green : Color.accentColor)
                        .frame(width: 34, height: 34)
                        .background(
                            (isInstalled ? Color.green : Color.accentColor).opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(manifest.name)
                            .foregroundStyle(.primary)
                        Text("v\(manifest.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isInstalled {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    if let description = manifest.description, !description.isEmpty {
                        Text(verbatim: description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if loadingFilesID == manifest.enterpriseDatasetID {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                    } else if let files = datasetFiles[manifest.enterpriseDatasetID], !files.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(files, id: \.relPath) { file in
                                fileRow(manifest: manifest, file: file)
                                if file.relPath != files.last?.relPath {
                                    Divider()
                                }
                            }
                        }
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    if previewErrorDatasetID == manifest.enterpriseDatasetID {
                        Text(LocalizedStringKey("Couldn't load the file preview."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    datasetActions(
                        manifest,
                        isInstalled: isInstalled,
                        isInstalling: isInstalling
                    )
                }
                .padding(.top, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func datasetActions(_ manifest: EnterpriseDatasetManifest, isInstalled: Bool, isInstalling: Bool) -> some View {
        if isInstalled {
            HStack {
                Label(LocalizedStringKey("In Stored"), systemImage: "checkmark.seal.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                Spacer()
                Button(role: .destructive) {
                    Task {
                        await manager.removeDataset(manifest)
                    }
                } label: {
                    Text(LocalizedStringKey("Remove from this device"))
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        } else if EnterprisePolicyGate.datasetDownloadAllowed {
            Button {
                Task {
                    await manager.installDataset(manifest)
                }
            } label: {
                HStack(spacing: 8) {
                    if isInstalling {
                        ProgressView()
                            .controlSize(.small)
                        Text(LocalizedStringKey("Adding to Stored…"))
                    } else {
                        Image(systemName: "tray.and.arrow.down.fill")
                        Text(LocalizedStringKey("Save to Stored"))
                    }
                }
                .font(.callout.weight(.medium))
                .industrialCTAWidth()
                .padding(.vertical, 9)
            }
            .buttonStyle(.industrial(.prominent))
            .disabled(isInstalling)
        }
    }

    private func fileRow(manifest: EnterpriseDatasetManifest, file: EnterpriseDatasetFile) -> some View {
        Button {
            Task { await previewFile(manifest: manifest, file: file) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: fileIcon(for: file.relPath))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(verbatim: (file.relPath as NSString).lastPathComponent)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if previewLoadingPath == file.relPath {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: file.sizeBytes, countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fileIcon(for relPath: String) -> String {
        switch (relPath as NSString).pathExtension.lowercased() {
        case "pdf": return "doc.richtext"
        case "epub": return "book"
        case "txt", "md": return "doc.text"
        case "csv", "tsv": return "tablecells"
        case "json", "jsonl": return "curlybraces"
        default: return "doc"
        }
    }

    private func loadFiles(_ manifest: EnterpriseDatasetManifest) async {
        let id = manifest.enterpriseDatasetID
        guard datasetFiles[id] == nil else { return }
        loadingFilesID = id
        defer { loadingFilesID = nil }
        datasetFiles[id] = (try? await manager.fetchDatasetFiles(manifest)) ?? []
    }

    private func previewFile(manifest: EnterpriseDatasetManifest, file: EnterpriseDatasetFile) async {
        previewErrorDatasetID = nil
        previewLoadingPath = file.relPath
        defer { previewLoadingPath = nil }
        do {
            previewURL = try await manager.previewURL(for: manifest, file: file)
        } catch {
            previewErrorDatasetID = manifest.enterpriseDatasetID
        }
    }

    private func workspaceHero(_ policy: EnterprisePolicy) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(heroTint.opacity(0.14))
                    .frame(width: 64, height: 64)
                Image(systemName: "building.2.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(heroTint)
            }
            Text(verbatim: policy.tenantName)
                .font(.title3.weight(.semibold))
            statusPill
            Text(verbatim: policy.userEmail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var heroTint: Color {
        switch manager.state {
        case .connected: return .green
        case .policyExpired: return .orange
        case .deviceRevoked, .policyInvalid: return .red
        default: return .accentColor
        }
    }

    private var statusPill: some View {
        let text: LocalizedStringKey
        switch manager.state {
        case .connected: text = "Active"
        case .policyExpired: text = "Expired"
        case .deviceRevoked: text = "Revoked"
        case .policyInvalid: text = "Invalid"
        default: text = "Active"
        }
        return Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(heroTint)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(heroTint.opacity(0.12), in: Capsule())
    }

    private func tapHaptic() {
#if os(iOS)
        // visionOS/macOS Haptics stubs take untyped args; only iOS has the typed impact API.
        Haptics.impact(.light)
#endif
    }

    private func runRefresh() {
        guard !isRefreshing else { return }
        tapHaptic()
        isRefreshing = true
        refreshDone = false
        Task {
            await manager.refreshPolicy(force: true)
            isRefreshing = false
            refreshDone = true
            Haptics.successLight()
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            refreshDone = false
        }
    }

    private func startApprovalPollingIfNeeded() {
        approvalPollTask?.cancel()
        guard case .pendingApproval = manager.state else { return }
        // @MainActor: the manager's published state must be read on the main actor.
        approvalPollTask = Task { @MainActor [weak manager] in
            while !Task.isCancelled {
                guard let manager else { return }
                await manager.pollPendingApproval()
                if case .pendingApproval = manager.state {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                } else {
                    return
                }
            }
        }
    }

#if os(macOS)
    // MARK: - macOS industrial layout

    private var macBody: some View {
        MacSettingsPage {
            switch manager.state {
            case .none, .disconnected:
                macConnectForm
            case .connecting:
                MacSettingsCard(LocalizedStringKey("Connect to company")) {
                    MacSettingsRowContainer(divider: false) {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            Text(LocalizedStringKey("Contacting your workspace…"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.6))
                            Spacer(minLength: 0)
                        }
                    }
                }
            case .awaitingEmailVerification:
                macVerificationForm
            case .pendingApproval:
                macPendingApproval
            case .connected, .policyExpired, .deviceRevoked, .policyInvalid:
                macConnectedSections
            }
        }
    }

    private var macConnectForm: some View {
        MacSettingsCard(LocalizedStringKey("Connect to company")) {
            MacSettingsControlRow(LocalizedStringKey("Company code"), divider: false) {
                TextField(LocalizedStringKey("Company code"), text: $companyCode)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .industrialField(width: 220)
            }
            MacSettingsControlRow(LocalizedStringKey("Work email")) {
                TextField(LocalizedStringKey("Work email"), text: $email)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .industrialField(width: 220)
            }
            MacSettingsNoteRow(LocalizedStringKey("Your administrator shares the company code. We'll email you a verification code."))
            MacSettingsActionRow {
                Button {
                    tapHaptic()
                    Task { await manager.connect(companyCode: companyCode, email: email) }
                } label: {
                    if manager.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(LocalizedStringKey("Connect"))
                    }
                }
                .buttonStyle(.industrial(.prominent))
                .disabled(manager.isBusy || companyCode.trimmingCharacters(in: .whitespaces).isEmpty || !email.contains("@"))
            }
            macErrorNote
        }
    }

    private var macVerificationForm: some View {
        MacSettingsCard(LocalizedStringKey("Check your email")) {
            MacSettingsControlRow(LocalizedStringKey("Verification code"), divider: false) {
                TextField(LocalizedStringKey("Verification code"), text: $verificationCode)
                    .labelsHidden()
                    .autocorrectionDisabled()
                    .industrialField(width: 160)
            }
            if let devCode = manager.devVerificationCode {
                MacEnterpriseNoteRow(text: "dev code: \(devCode)")
            }
            if let context = manager.storedContext {
                MacEnterpriseNoteRow(text: String(
                    format: String(localized: "We sent a 6-digit code to %@.", locale: LocalizationManager.preferredLocale()),
                    context.email
                ))
            }
            MacSettingsActionRow {
                Button {
                    tapHaptic()
                    Task {
                        await manager.submitVerificationCode(verificationCode.trimmingCharacters(in: .whitespaces))
                        verificationCode = ""
                        if case .connected = manager.state { Haptics.success() }
                    }
                } label: {
                    if manager.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(LocalizedStringKey("Verify"))
                    }
                }
                .buttonStyle(.industrial(.prominent))
                .disabled(manager.isBusy || verificationCode.trimmingCharacters(in: .whitespaces).count < 4)

                Button(role: .destructive) {
                    manager.cancelEnrollment()
                } label: {
                    Text(LocalizedStringKey("Cancel"))
                }
                .buttonStyle(.industrial(.destructive))
            }
            macErrorNote
        }
    }

    private var macPendingApproval: some View {
        MacSettingsCard(LocalizedStringKey("Waiting for admin approval")) {
            MacSettingsRowContainer(divider: false) {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey("Waiting for admin approval"))
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.7))
                        if let context = manager.storedContext, let name = context.tenantName {
                            Text(verbatim: name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.45))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            MacSettingsNoteRow(LocalizedStringKey("An administrator needs to approve your request. You can leave this screen — Noema connects automatically once approved."))
            MacSettingsActionRow {
                Button(role: .destructive) {
                    manager.cancelEnrollment()
                } label: {
                    Text(LocalizedStringKey("Cancel request"))
                }
                .buttonStyle(.industrial(.destructive))
            }
            macErrorNote
        }
    }

    @ViewBuilder
    private var macConnectedSections: some View {
        if let policy = manager.policy {
            macWorkspaceCard(policy)
            if let countdown = reconnectCountdown {
                macOfflineAccessCard(policy, countdown)
            }
            macPolicyCard(policy)
            macRolesCard(policy)
            macDatasetsCard()
        } else if manager.state != .connected {
            MacSettingsCard(LocalizedStringKey("Policy")) {
                macStatusBanner(divider: false)
            }
        }
        macActionsCard
    }

    private func macWorkspaceCard(_ policy: EnterprisePolicy) -> some View {
        MacSettingsCard(LocalizedStringKey("Workspace"), detail: policy.tenantName) {
            macStatusBanner(divider: false)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Work email"), value: policy.userEmail, divider: manager.state != .connected)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Company code"), value: policy.companyCode)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Roles"), value: policy.roleNames.joined(separator: ", "))
        }
    }

    private func macOfflineAccessCard(_ policy: EnterprisePolicy, _ countdown: (deadline: Date, days: Int)) -> some View {
        MacSettingsCard(LocalizedStringKey("Offline access")) {
            MacSettingsRowContainer(divider: false) {
                ReconnectCountdownView(deadline: countdown.deadline, intervalDays: countdown.days)
            }
            MacEnterpriseNoteRow(text: String(
                format: String(
                    localized: "This device must reconnect to %@ at least once every %lld days. If it stays offline past the deadline, all company data is removed from this device automatically. Going back online resets the countdown.",
                    locale: LocalizationManager.preferredLocale()
                ),
                policy.tenantName, Int64(countdown.days)
            ))
        }
    }

    private func macPolicyCard(_ policy: EnterprisePolicy) -> some View {
        MacSettingsCard(LocalizedStringKey("Policy")) {
            MacSettingsStatusRow(title: LocalizedStringKey("Policy"), value: macStatusValue, systemImage: macStatusIcon, tint: heroTint, divider: false)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Version"), value: "\(policy.policyVersion)")
            MacSettingsKeyValueRow(title: LocalizedStringKey("Expires"), value: policy.expiresAt.formatted(date: .abbreviated, time: .shortened))
            if let lastSync = manager.lastSyncAt {
                MacSettingsKeyValueRow(title: LocalizedStringKey("Last sync"), value: lastSync.formatted(date: .abbreviated, time: .shortened))
            }
            MacSettingsKeyValueRow(title: LocalizedStringKey("Device ID"), value: String(policy.deviceID.prefix(8)))
        }
    }

    @ViewBuilder
    private func macRolesCard(_ policy: EnterprisePolicy) -> some View {
        MacSettingsCard(LocalizedStringKey("What your roles allow")) {
            MacSettingsKeyValueRow(title: LocalizedStringKey("Tools"), value: allowSummary(policy.allowedToolNames), divider: false)
            MacSettingsKeyValueRow(title: LocalizedStringKey("Model formats"), value: allowSummary(policy.allowedModelFormats))
            MacSettingsKeyValueRow(title: LocalizedStringKey("Remote backends"), value: remoteSummary(policy))
            if policy.requiresOffGrid {
                MacSettingsRowContainer {
                    HStack(spacing: 10) {
                        Image(systemName: "wifi.slash")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        Text(LocalizedStringKey("Off-grid mode is required by your organization"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func macDatasetsCard() -> some View {
        MacSettingsCard(LocalizedStringKey("Company datasets")) {
            if manager.availableDatasets.isEmpty {
                MacSettingsNoteRow(LocalizedStringKey("No datasets are shared with your roles yet."), divider: false)
            } else {
                ForEach(Array(manager.availableDatasets.enumerated()), id: \.element.enterpriseDatasetID) { index, manifest in
                    MacSettingsRowContainer(divider: index != 0) {
                        datasetCard(manifest)
                    }
                }
            }
        }
    }

    private var macActionsCard: some View {
        MacSettingsCard(LocalizedStringKey("Disconnect")) {
            MacSettingsActionRow(divider: false) {
                Button {
                    runRefresh()
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(refreshDone ? LocalizedStringKey("Up to date") : LocalizedStringKey("Refresh policy"),
                              systemImage: refreshDone ? "checkmark.circle.fill" : "arrow.clockwise")
                    }
                }
                .buttonStyle(.industrial(.tinted, tint: refreshDone ? .green : .accentColor))
                .disabled(isRefreshing)

                Button {
                    tapHaptic()
                    confirmDisconnect = true
                } label: {
                    Label(LocalizedStringKey("Disconnect"), systemImage: "xmark.circle")
                }
                .buttonStyle(.industrial(.destructive))
            }
            macErrorNote
        }
    }

    @ViewBuilder
    private func macStatusBanner(divider: Bool) -> some View {
        if let info = statusBannerInfo() {
            MacSettingsRowContainer(divider: divider) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: info.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(info.tint)
                        .frame(width: 18)
                    Text(info.message)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(info.tint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statusBannerInfo() -> (icon: String, tint: Color, message: LocalizedStringKey)? {
        switch manager.state {
        case .policyExpired:
            return ("clock.badge.exclamationmark", .orange, "Policy expired — Noema keeps enforcing the last policy and will sync when the workspace is reachable.")
        case .deviceRevoked:
            return ("nosign", .red, "This device's access was revoked by your organization. Company datasets were removed.")
        case .policyInvalid:
            return ("exclamationmark.shield", .red, "The last policy from your workspace couldn't be trusted. Restrictions stay active; company datasets are unavailable.")
        default:
            return nil
        }
    }

    @ViewBuilder
    private var macErrorNote: some View {
        if let message = manager.lastErrorMessage {
            MacEnterpriseNoteRow(text: message, tint: .red)
        }
    }

    private var macStatusValue: String {
        switch manager.state {
        case .connected: return String(localized: "Active", locale: LocalizationManager.preferredLocale())
        case .policyExpired: return String(localized: "Expired", locale: LocalizationManager.preferredLocale())
        case .deviceRevoked: return String(localized: "Revoked", locale: LocalizationManager.preferredLocale())
        case .policyInvalid: return String(localized: "Invalid", locale: LocalizationManager.preferredLocale())
        default: return String(localized: "Active", locale: LocalizationManager.preferredLocale())
        }
    }

    private var macStatusIcon: String {
        switch manager.state {
        case .connected: return "checkmark.seal.fill"
        case .policyExpired: return "clock.badge.exclamationmark"
        case .deviceRevoked: return "nosign"
        case .policyInvalid: return "exclamationmark.shield"
        default: return "checkmark.seal.fill"
        }
    }
#endif
}


/// Form-row button style with unmistakable press feedback (scale + dim), used by the
/// Enterprise screen's row actions where the default Form button gives almost none.
private struct EnterprisePressableRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


/// Live, ticking countdown to the workspace reconnect deadline. When the device stays offline
/// past it, EnterprisePolicyManager wipes all company data — this surfaces the remaining time
/// and escalates colour (green → orange → red) as the deadline approaches.
private struct ReconnectCountdownView: View {
    let deadline: Date
    let intervalDays: Int

    var body: some View {
        // Re-renders once a second while the screen is visible, so the readout ticks live.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = deadline.timeIntervalSince(context.date)
            let window = max(1, TimeInterval(intervalDays) * 86_400)
            let fraction = max(0, min(1, remaining / window))
            let tint = urgencyTint(for: remaining)
            let overdue = remaining <= 0

            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.18), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: overdue ? 1 : CGFloat(fraction))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.5), value: fraction)
                    Image(systemName: overdue ? "wifi.exclamationmark" : "antenna.radiowaves.left.and.right")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 58, height: 58)

                VStack(alignment: .leading, spacing: 3) {
                    Text(overdue
                         ? LocalizedStringKey("Reconnect now")
                         : LocalizedStringKey("Reconnect required"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(overdue ? overdueText : remainingText(remaining))
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(tint)
                    Text(deadlineCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .combine)
        }
    }

    private var overdueText: String {
        String(localized: "Access ending…", locale: LocalizationManager.preferredLocale())
    }

    private var deadlineCaption: String {
        String(
            format: String(localized: "Reconnect by %@", locale: LocalizationManager.preferredLocale()),
            deadline.formatted(date: .abbreviated, time: .shortened)
        )
    }

    private func remainingText(_ remaining: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropTrailing
        if remaining >= 86_400 {
            formatter.allowedUnits = [.day, .hour]
        } else if remaining >= 3_600 {
            formatter.allowedUnits = [.hour, .minute]
        } else {
            formatter.allowedUnits = [.minute, .second]
        }
        let value = formatter.string(from: max(0, remaining)) ?? "—"
        return String(
            format: String(localized: "%@ left", locale: LocalizationManager.preferredLocale()),
            value
        )
    }

    private func urgencyTint(for remaining: TimeInterval) -> Color {
        if remaining < 86_400 { return .red }        // under a day (or overdue)
        if remaining < 7 * 86_400 { return .orange } // under a week
        return .green
    }
}


#if os(macOS)
/// Mono note row for runtime-interpolated copy on the Mac Enterprise screen —
/// `MacSettingsNoteRow` only takes a `LocalizedStringKey`, but these lines arrive
/// already formatted (verification email, reconnect deadline, error messages).
private struct MacEnterpriseNoteRow: View {
    let text: String
    var tint: Color = Color.primary.opacity(0.45)
    var divider: Bool = true

    var body: some View {
        MacSettingsRowContainer(divider: divider) {
            Text(verbatim: text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
#endif
