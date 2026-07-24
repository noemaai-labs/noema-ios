#if os(macOS)
import AppKit
import SwiftUI

struct MCPSettingsView: View {
    @ObservedObject private var manager = MCPServerManager.shared
    @ObservedObject private var store = MCPConfigurationStore.shared
    @State private var selection: String?
    @State private var showEditor = false
    @State private var importPreview: MCPImportPreview?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if manager.servers.isEmpty {
                welcome
                    .transition(.opacity.combined(with: .scale(scale: 0.99)))
            } else {
                workspace
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.24), value: manager.servers.count)
        .sheet(isPresented: $showEditor) { MCPRawEditorView(isPresented: $showEditor) }
        .alert(LocalizedStringKey("MCP Configuration"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(LocalizedStringKey("OK"), role: .cancel) { errorMessage = nil }
        } message: { Text(verbatim: errorMessage ?? "") }
        .alert(LocalizedStringKey("Import Configuration"), isPresented: Binding(get: { importPreview != nil }, set: { if !$0 { importPreview = nil } })) {
            Button(LocalizedStringKey("Cancel"), role: .cancel) { importPreview = nil }
            Button(LocalizedStringKey("Import Without Moving Secrets")) {
                if let importPreview { do { try store.applyImport(importPreview, migrateSecrets: false) } catch { errorMessage = error.localizedDescription } }
                importPreview = nil
            }
            if importPreview?.secrets.isEmpty == false {
                Button(LocalizedStringKey("Import and Move Secrets to Keychain")) {
                    if let importPreview { do { try store.applyImport(importPreview, migrateSecrets: true) } catch { errorMessage = error.localizedDescription } }
                    importPreview = nil
                }
            }
        } message: {
            Text(verbatim: importPreview.map { "\($0.added.count) added · \($0.replaced.count) replaced · \($0.unchanged.count) unchanged · \($0.secrets.count) possible secrets" } ?? "")
        }
    }

    private var workspace: some View {
        HSplitView {
            serverList
                .frame(minWidth: 210, idealWidth: 240, maxWidth: 280)

            Group {
                if let selection, let server = manager.servers.first(where: { $0.id == selection }) {
                    MCPServerDetailView(server: server)
                        .id(server.id)
                        .transition(.opacity)
                } else {
                    ContentUnavailableView(
                        String(localized: "Model Context Protocol"), systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(LocalizedStringKey("Select a server to review its capabilities and permissions."))
                    )
                }
            }
            .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.16), value: selection)
        }
    }

    private var serverList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { showEditor = true } label: { Label(LocalizedStringKey("Edit mcp.json"), systemImage: "curlybraces") }
                    .buttonStyle(.industrial(.prominent))
                Spacer()
                configurationMenu
            }
            .padding(12)

            Divider()
            List(manager.servers, selection: $selection) { server in
                MCPServerRow(server: server).tag(server.id)
            }
            .listStyle(.sidebar)
        }
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { showEditor = true } label: { Label(LocalizedStringKey("Edit mcp.json"), systemImage: "curlybraces") }
                    .buttonStyle(.industrial(.prominent))
                Spacer()
                configurationMenu
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.blue)
                        Text(LocalizedStringKey("Configure MCP with mcp.json"))
                            .font(.title2.weight(.semibold))
                        Text(LocalizedStringKey("Add each server under the top-level mcpServers object. Noema validates the file before applying changes."))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ScrollView(.horizontal) {
                        Text(verbatim: exampleConfiguration)
                            .font(.system(size: 12.5, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(16)
                    }
                    .scrollIndicators(.hidden)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    }

                    VStack(spacing: 18) {
                        MCPWelcomeCapabilityRow(
                            icon: MCPDirectEdition.isAvailable ? "terminal" : "lock",
                            title: "Run local servers",
                            description: MCPDirectEdition.isAvailable
                                ? "Use command and args for npx, uvx, Python, Docker, Bun, Deno, or another executable."
                                : "App Store apps cannot launch arbitrary local MCP server commands. Remote MCP servers over HTTPS are supported.",
                            available: MCPDirectEdition.isAvailable
                        )
                        MCPWelcomeCapabilityRow(
                            icon: "network",
                            title: "Connect remote servers",
                            description: "Use an HTTPS MCP endpoint with OAuth or custom headers."
                        )
                        MCPWelcomeCapabilityRow(
                            icon: "bubble.left.and.bubble.right",
                            title: "Use MCP tools in chat",
                            description: "Choose configured servers per conversation. Noema asks before sensitive or destructive tool calls."
                        )
                    }

                    Divider()

                    Label {
                        Text(LocalizedStringKey("Local servers run as separate processes and may access files or the network. Only add servers you trust."))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "checkmark.shield")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var exampleConfiguration: String {
        if MCPDirectEdition.isAvailable {
            return """
            {
              "mcpServers": {
                "remote-server": {
                  "url": "https://example.com/mcp",
                  "headers": {
                    "Authorization": "${keychain:remote-server-token}"
                  }
                },
                "local-server": {
                  "command": "npx",
                  "args": [
                    "-y",
                    "@example/mcp-server"
                  ]
                }
              }
            }
            """
        }
        return """
        {
          "mcpServers": {
            "remote-server": {
              "url": "https://example.com/mcp",
              "headers": {
                "Authorization": "${keychain:remote-server-token}"
              }
            }
          }
        }
        """
    }

    private var configurationMenu: some View {
        Menu {
            Button(LocalizedStringKey("Edit mcp.json")) { showEditor = true }
            Button(LocalizedStringKey("Import Configuration…")) { importConfiguration() }
            Button(LocalizedStringKey("Export Configuration…")) { exportConfiguration() }
            Divider()
            Button(LocalizedStringKey("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([MCPConfigurationStore.fileURL]) }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .frame(width: 28)
        .accessibilityLabel(LocalizedStringKey("Configuration Options"))
    }

    private func importConfiguration() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importPreview = try store.previewImport(data: Data(contentsOf: url)) }
        catch { errorMessage = error.localizedDescription }
    }

    private func exportConfiguration() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "mcp.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(store.rawText.utf8).write(to: url, options: .atomic) } catch { errorMessage = error.localizedDescription }
    }
}

private struct MCPWelcomeCapabilityRow: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey
    var available = true

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(available ? Color.blue : Color.secondary)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServerStatus
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(stateColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.configuration.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(verbatim: "\(server.state.label) · \(server.configuration.transport.displayName)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if server.capabilities.tools + server.capabilities.resources + server.capabilities.prompts > 0 {
                Text(verbatim: "\(server.capabilities.tools + server.capabilities.resources + server.capabilities.prompts)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
    private var stateColor: Color {
        switch server.state { case .ready: .blue; case .failed: .orange; case .stopped: .secondary.opacity(0.5); default: .blue.opacity(0.55) }
    }
}

private struct MCPServerDetailView: View {
    enum Tab: String, CaseIterable, Identifiable { case overview = "Overview", capabilities = "Capabilities", permissions = "Permissions", environment = "Environment", roots = "Roots", activity = "Activity"; var id: String { rawValue } }
    let server: MCPServerStatus
    @ObservedObject private var manager = MCPServerManager.shared
    @ObservedObject private var store = MCPConfigurationStore.shared
    @State private var tab: Tab = .overview
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: server.configuration.displayName).font(.title2.weight(.semibold))
                    Text(verbatim: server.state.label).font(.caption).foregroundStyle(stateColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Menu {
                    Button(LocalizedStringKey("Refresh Capabilities")) { Task { await manager.refresh(serverID: server.id) } }
                    Button(LocalizedStringKey("Remove Server"), role: .destructive) { try? store.remove(serverID: server.id) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 12)
            HStack(spacing: 12) {
                Picker(LocalizedStringKey("Section"), selection: $tab) {
                    ForEach(Tab.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
                }
                .pickerStyle(.menu)
                .frame(minWidth: 220, maxWidth: 240, alignment: .leading)
                Spacer()
                Button {
                    Task { await manager.refreshConnection(serverID: server.id) }
                } label: {
                    Label(LocalizedStringKey("Refresh Connection"), systemImage: "arrow.clockwise")
                }
                .disabled(!canRefreshConnection)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
            Divider()
            ScrollView {
                detail.padding(20).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert(LocalizedStringKey("MCP Server"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(LocalizedStringKey("OK"), role: .cancel) { errorMessage = nil }
        } message: { Text(verbatim: errorMessage ?? "") }
    }

    @ViewBuilder private var detail: some View {
        switch tab {
        case .overview:
            MCPKeyValueList(rows: [
                (String(localized: "Status"), server.state.label),
                (String(localized: "Transport"), server.configuration.transport.displayName),
                (String(localized: "Runtime"), server.runtimeSummary ?? String(localized: "Managed by Noema")),
                (String(localized: "Protocol"), server.capabilities.protocolVersion),
                (String(localized: "Server"), [server.capabilities.serverName, server.capabilities.serverVersion].compactMap { $0 }.joined(separator: " "))
            ])
        case .capabilities:
            MCPKeyValueList(rows: [
                (String(localized: "Tools"), "\(server.tools.count)"),
                (String(localized: "Resources"), "\(server.resources.filter { !$0.isTemplate }.count)"),
                (String(localized: "Resource Templates"), "\(server.resources.filter(\.isTemplate).count)"),
                (String(localized: "Prompts"), "\(server.prompts.count)"),
                (String(localized: "Completions"), yesNo(server.capabilities.supportsCompletions)),
                (String(localized: "Subscriptions"), yesNo(server.capabilities.supportsResourceSubscriptions)),
                (String(localized: "Experimental Tasks"), yesNo(server.capabilities.supportsTasks))
            ])
        case .permissions: permissions
        case .environment: environment
        case .roots: roots
        case .activity:
            LazyVStack(spacing: 0) {
                ForEach(server.log.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(entry.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(verbatim: entry.message).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.vertical, 7)
                    Divider()
                }
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 0) {
                permissionToggle("Trusted Server", value: server.configuration.policy.trusted) { value in update { $0.trusted = value } }
                permissionToggle("Allow Cloud Models", value: server.configuration.policy.allowCloudModels) { value in update { $0.allowCloudModels = value } }
                permissionToggle("Allow Sampling", value: server.configuration.policy.allowSampling) { value in update { $0.allowSampling = value } }
                permissionToggle("Allow Elicitation", value: server.configuration.policy.allowElicitation) { value in update { $0.allowElicitation = value } }
                permissionToggle("Experimental Tasks", value: server.configuration.policy.experimentalTasks) { value in update { $0.experimentalTasks = value } }
            }

            if !server.tools.isEmpty {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Label(LocalizedStringKey("Tools"), systemImage: "hammer")
                            .font(.headline)
                        Spacer()
                        Picker(LocalizedStringKey("Tool Access"), selection: Binding(
                            get: { server.configuration.policy.allowAllTools },
                            set: { value in update { $0.allowAllTools = value } }
                        )) {
                            Text(LocalizedStringKey("Per-Tool Permissions")).tag(false)
                            Text(LocalizedStringKey("Always Allow All Tools")).tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(server.tools.sorted { $0.originalName.localizedStandardCompare($1.originalName) == .orderedAscending }) { tool in
                        toolPermissionRow(tool)
                        Divider()
                    }
                }
            }
        }
    }

    private func toolPermissionRow(_ tool: MCPToolDescriptor) -> some View {
        let enabled = server.configuration.policy.isToolEnabled(tool.originalName)
        let alwaysAllowed = server.configuration.policy.alwaysAllowedTools.contains(tool.originalName)
        return HStack(spacing: 12) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { value in
                    update { policy in
                        if value { policy.disabledTools.remove(tool.originalName) }
                        else { policy.disabledTools.insert(tool.originalName) }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: tool.title ?? tool.originalName)
                        .lineLimit(1)
                    if let title = tool.title, title != tool.originalName {
                        Text(verbatim: tool.originalName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 12)

            Picker(LocalizedStringKey("Tool Permission"), selection: Binding(
                get: { alwaysAllowed },
                set: { value in
                    update { policy in
                        if value { policy.alwaysAllowedTools.insert(tool.originalName) }
                        else { policy.alwaysAllowedTools.remove(tool.originalName) }
                    }
                }
            )) {
                Text(LocalizedStringKey("Ask")).tag(false)
                Text(LocalizedStringKey("Always Allow")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 140, alignment: .trailing)
            .disabled(!enabled || server.configuration.policy.allowAllTools)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var environment: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch server.configuration.transport {
            case .stdio(let command, let arguments, let cwd, let environment):
                MCPKeyValueList(rows: [
                    (String(localized: "Executable"), command),
                    (String(localized: "Arguments"), arguments.joined(separator: " ")),
                    (String(localized: "Working Directory"), cwd ?? String(localized: "Default"))
                ] + environment.sorted { $0.key < $1.key }.map { ($0.key, MCPRedaction.redact($0.value)) })
                if let package = manager.requestedPackageSpecification(serverID: server.id), package != server.configuration.policy.approvedPackageSpecification {
                    Button { do { try manager.approveCurrentPackage(serverID: server.id) } catch { errorMessage = error.localizedDescription } } label: {
                        Label(LocalizedStringKey("Approve Package Change"), systemImage: "shippingbox")
                    }.buttonStyle(.industrial(.prominent))
                }
                Button { chooseExecutable() } label: { Label(LocalizedStringKey("Choose Executable…"), systemImage: "terminal") }
            case .streamableHTTP(let url, let headers), .legacySSE(let url, let headers):
                MCPKeyValueList(rows: [(String(localized: "URL"), url.absoluteString)] + headers.sorted { $0.key < $1.key }.map { ($0.key, MCPRedaction.redact($0.value)) })
            }
        }
    }

    private var roots: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(server.configuration.policy.roots, id: \.self) { path in
                HStack { Image(systemName: "folder"); Text(verbatim: path).textSelection(.enabled); Spacer(); Button { update { $0.roots.removeAll { $0 == path } } } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                Divider()
            }
            Button { chooseRoot() } label: { Label(LocalizedStringKey("Add Folder…"), systemImage: "plus") }
        }
    }

    private func permissionToggle(_ title: LocalizedStringKey, value: Bool, action: @escaping (Bool) -> Void) -> some View {
        VStack(spacing: 0) { Toggle(title, isOn: Binding(get: { value }, set: action)).toggleStyle(.switch).padding(.vertical, 9); Divider() }
    }
    private func update(_ mutation: @escaping (inout MCPServerPolicy) -> Void) { do { try store.updatePolicy(serverID: server.id, mutate: mutation) } catch { errorMessage = error.localizedDescription } }
    private func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let path = panel.url?.path { update { if !$0.roots.contains(path) { $0.roots.append(path) } } } }
    private func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let path = panel.url?.path {
            do { try store.updateExecutable(serverID: server.id, path: path) } catch { errorMessage = error.localizedDescription }
        }
    }
    private func yesNo(_ value: Bool) -> String { value ? String(localized: "Yes") : String(localized: "No") }
    private var canRefreshConnection: Bool {
        guard server.configuration.policy.enabled else { return false }
        return switch server.state {
        case .ready, .stopped, .failed: true
        case .resolving, .starting, .authenticating, .connecting, .reconnecting, .stopping: false
        }
    }
    private var stateColor: Color { if case .failed = server.state { .orange } else { server.state == .ready ? .blue : .secondary } }
}

private struct MCPKeyValueList: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .firstTextBaseline) { Text(verbatim: row.0).foregroundStyle(.secondary); Spacer(); Text(verbatim: row.1.isEmpty ? "—" : row.1).textSelection(.enabled).multilineTextAlignment(.trailing) }
                    .font(.system(size: 13)).padding(.vertical, 9)
                if index < rows.count - 1 { Divider() }
            }
        }
    }
}

struct MCPRawEditorView: View {
    @Binding var isPresented: Bool
    @ObservedObject private var store = MCPConfigurationStore.shared
    @State private var text = ""
    @State private var line = 1
    @State private var column = 1
    @State private var diagnostic: String?
    @State private var showConflict = false

    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(LocalizedStringKey("mcp.json")).font(.title2.weight(.semibold)); Spacer(); Button(LocalizedStringKey("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([MCPConfigurationStore.fileURL]) }; Button { isPresented = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }.padding(16)
            Divider()
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.primary)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(8)
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Text(verbatim: "\(String(localized: "Line")) \(line), \(String(localized: "Column")) \(column)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let diagnostic {
                        Text(verbatim: diagnostic).font(.caption).foregroundStyle(.orange).lineLimit(1)
                    }
                    Spacer()
                }
                HStack {
                    Spacer()
                    Button(LocalizedStringKey("Restore Last Working")) { do { try store.restoreLastKnownGood(); text = store.rawText; diagnostic = nil } catch { diagnostic = error.localizedDescription } }
                    Button(LocalizedStringKey("Format")) { if case .success = store.validate(raw: text), let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) { text = value.prettyPrinted } }
                    Button(LocalizedStringKey("Save")) { save() }
                        .keyboardShortcut("s")
                        .buttonStyle(.industrial(.prominent))
                }
            }
            .padding(12)
        }
        .frame(minWidth: 500, idealWidth: 760, minHeight: 500, idealHeight: 600)
        .onAppear { text = store.rawText; store.beginRawEditing() }
        .onChange(of: text) { _, newValue in
            updatePosition(at: newValue.endIndex, in: newValue)
            if case .failure(let error) = store.validate(raw: newValue) { diagnostic = error.localizedDescription } else { diagnostic = nil }
        }
        .onChange(of: store.externalConflict) { _, value in showConflict = value }
        .onDisappear { if text == store.rawText { store.cancelRawEditing() } }
        .alert(LocalizedStringKey("mcp.json Changed"), isPresented: $showConflict) {
            Button(LocalizedStringKey("Reload")) { store.cancelRawEditing(); text = store.rawText }
                    Button(LocalizedStringKey("Keep My Version"), role: .destructive) { save(overwriteExternalChange: true) }
            Button(LocalizedStringKey("Cancel"), role: .cancel) { }
        } message: { Text(LocalizedStringKey("The file changed outside Noema. Reload it or explicitly keep your version.")) }
    }
    private func save(overwriteExternalChange: Bool = false) {
        do {
            try store.save(raw: text, overwriteExternalChange: overwriteExternalChange)
            text = store.rawText
            diagnostic = nil
            isPresented = false
        } catch MCPConfigurationError.externalConflict {
            showConflict = true
        } catch {
            diagnostic = error.localizedDescription
        }
    }
    private func updatePosition(at index: String.Index, in value: String) {
        let prefix = value[..<index]
        let pieces = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        line = pieces.count
        column = (pieces.last?.count ?? 0) + 1
    }
}

private struct MCPInteractionPresenter: ViewModifier {
    @ObservedObject var chatVM: ChatVM
    @ObservedObject private var approvals = MCPApprovalCenter.shared
    @ObservedObject private var interactions = MCPHumanInteractionCenter.shared
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { fallbackApprovalRequest }, set: { if $0 == nil { approvals.cancel() } })) { request in
                MCPApprovalSheet(request: request)
            }
            .sheet(item: Binding(get: { interactions.samplingRequest }, set: { if $0 == nil { interactions.denySampling() } })) { request in
                MCPSamplingSheet(request: request)
            }
            .sheet(item: Binding(get: { interactions.elicitationRequest }, set: { if $0 == nil { interactions.answerElicitation(.cancel) } })) { request in
                MCPElicitationSheet(request: request)
            }
    }

    private var fallbackApprovalRequest: MCPApprovalRequest? {
        guard let request = approvals.request else { return nil }
        let hasInlineRow = chatVM.streamMsgs.contains { message in
            message.toolCalls?.contains {
                ($0.toolName == request.tool.alias || $0.toolName == MCPCallTool.toolName)
                    && $0.phase == .awaitingApproval
            } == true
        }
        return hasInlineRow ? nil : request
    }
}

extension View {
    func mcpInteractionPresenter(chatVM: ChatVM) -> some View {
        modifier(MCPInteractionPresenter(chatVM: chatVM))
    }
}

private struct MCPApprovalSheet: View {
    let request: MCPApprovalRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(LocalizedStringKey("Tool Approval"), systemImage: "checkmark.shield").font(.title2.weight(.semibold))
            Text(verbatim: request.tool.title ?? request.tool.originalName).font(.headline)
            Text(verbatim: request.serverName).foregroundStyle(.secondary)
            ScrollView { Text(verbatim: request.arguments.prettyPrinted).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(maxHeight: 220).padding(10).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack { Button(LocalizedStringKey("Deny"), role: .destructive) { MCPApprovalCenter.shared.answer(.deny) }; Spacer(); Button(LocalizedStringKey("Allow Once")) { MCPApprovalCenter.shared.answer(.allowOnce) }; Button(LocalizedStringKey("Always Allow This Tool")) { MCPApprovalCenter.shared.answer(.alwaysAllow) }.buttonStyle(.industrial(.prominent)) }
        }.padding(24).frame(width: 560)
    }
}

private struct MCPSamplingSheet: View {
    let request: MCPSamplingRequest
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(LocalizedStringKey("MCP Sampling Request"), systemImage: "brain").font(.title2.weight(.semibold))
            Text(LocalizedStringKey("This server wants Noema to ask your on-device model. Tools are disabled for this request."))
                .foregroundStyle(.secondary)
            ScrollView { Text(verbatim: request.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
            Text(verbatim: "\(request.maxTokens) max tokens").font(.caption).foregroundStyle(.secondary)
            HStack { Button(LocalizedStringKey("Deny"), role: .destructive) { MCPHumanInteractionCenter.shared.denySampling() }; Spacer(); Button(LocalizedStringKey("Allow")) { MCPHumanInteractionCenter.shared.approveSampling() }.buttonStyle(.industrial(.prominent)) }
        }.padding(24).frame(width: 580)
    }
}

private struct MCPElicitationSheet: View {
    let request: MCPElicitationRequest
    @State private var values: [String: String] = [:]
    @State private var validationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(LocalizedStringKey("MCP Request"), systemImage: "person.text.rectangle").font(.title2.weight(.semibold))
            Text(verbatim: request.message)
            switch request.mode {
            case .form(let schema):
                ForEach((schema["properties"]?.objectValue ?? [:]).keys.sorted(), id: \.self) { key in
                    let field = schema["properties"]?.objectValue?[key]
                    if let choices = field?["enum"]?.arrayValue?.compactMap(\.stringValue), !choices.isEmpty {
                        Picker(field?["title"]?.stringValue ?? key, selection: Binding(get: { values[key, default: choices[0]] }, set: { values[key] = $0 })) {
                            ForEach(choices, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                    } else if field?["type"]?.stringValue == "boolean" {
                        Toggle(field?["title"]?.stringValue ?? key, isOn: Binding(get: { values[key] == "true" }, set: { values[key] = $0 ? "true" : "false" }))
                    } else {
                        TextField(field?["title"]?.stringValue ?? key, text: Binding(get: { values[key, default: ""] }, set: { values[key] = $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            case .url(let url):
                if let host = url.host { Text(verbatim: host).font(.headline) }
                Text(verbatim: url.absoluteString).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if url.host?.localizedCaseInsensitiveContains("xn--") == true {
                    Label(LocalizedStringKey("This address uses an internationalized domain. Verify it carefully."), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            if let validationError { Text(verbatim: validationError).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button(LocalizedStringKey("Decline"), role: .destructive) { MCPHumanInteractionCenter.shared.answerElicitation(.decline) }
                Spacer()
                Button(actionTitle) { submit() }.buttonStyle(.industrial(.prominent))
            }
        }.padding(24).frame(width: 560)
    }

    private var actionTitle: LocalizedStringKey {
        if case .url = request.mode { "Open in Browser" } else { "Continue" }
    }

    private func submit() {
        switch request.mode {
        case .url:
            MCPHumanInteractionCenter.shared.answerElicitation(.accept([:]))
        case .form(let schema):
            let properties = schema["properties"]?.objectValue ?? [:]
            let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
            var result: [String: JSONValue] = [:]
            for (key, field) in properties {
                let raw = values[key, default: ""]
                if required.contains(key), raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    validationError = String(localized: "Complete all required fields."); return
                }
                guard !raw.isEmpty else { continue }
                switch field["type"]?.stringValue {
                case "integer": guard let value = Int64(raw) else { validationError = String(localized: "Enter a valid whole number."); return }; result[key] = .integer(value)
                case "number": guard let value = Double(raw) else { validationError = String(localized: "Enter a valid number."); return }; result[key] = .number(value)
                case "boolean": result[key] = .bool(raw == "true")
                default:
                    if let minimum = field["minLength"]?.integerValue, raw.count < minimum { validationError = String(localized: "One or more fields are too short."); return }
                    result[key] = .string(raw)
                }
            }
            validationError = nil
            MCPHumanInteractionCenter.shared.answerElicitation(.accept(result))
        }
    }
}

private struct SecureAwareField: View {
    let label: String; let sensitive: Bool; @Binding var text: String
    var body: some View { if sensitive { SecureField(label, text: $text).textFieldStyle(.roundedBorder) } else { TextField(label, text: $text).textFieldStyle(.roundedBorder) } }
}
#endif
