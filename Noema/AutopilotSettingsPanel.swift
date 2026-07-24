import SwiftUI

#if !os(macOS)
/// The Autopilot settings form content (status, router/cloud picks, escalation
/// mode, privacy toggles, ledger stats, turn-off) shared by the Settings tab's
/// Autopilot page and the Stored-list row sheet. Emits Form sections — embed
/// inside a Form/List. The picker sheet is host-owned via `setupMode` because
/// a sheet modifier attached to Form sections would re-apply per row.
struct AutopilotSettingsPanel: View {
    @EnvironmentObject var modelManager: AppModelManager
    @ObservedObject private var autopilotLedger = AutopilotLedger.shared
    @Binding var setupMode: AutopilotSetupMode?
    @State private var config = AutopilotConfigStore.load()

    var body: some View {
        statusSection
        systemSection
        if config.system == .router {
            escalationSection
        }
        privacySection
        statsSection
        if modelManager.autoRoutingArmed {
            Section {
                Button(role: .destructive) {
                    modelManager.autoRoutingArmed = false
                    config = AutopilotConfigStore.load()
                } label: {
                    Text(LocalizedStringKey("Turn Off Autopilot"))
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack {
                Text(LocalizedStringKey("Autopilot"))
                Spacer()
                Text(verbatim: statusText)
                    .foregroundStyle(Color.secondary)
            }
            if config.system == .router {
                selectionRow(title: LocalizedStringKey("Router"), detail: routerDetailText, mode: .router)
            }
            selectionRow(title: LocalizedStringKey("Stronger Model"), detail: cloudDetailText, mode: .strongerModel)
        }
        .onAppear { config = AutopilotConfigStore.load() }
        .onChangeCompat(of: setupMode) { _, newMode in
            if newMode == nil { config = AutopilotConfigStore.load() }
        }
        .onChangeCompat(of: modelManager.autoRoutingArmed) { _, _ in
            config = AutopilotConfigStore.load()
        }
    }

    private var systemSection: some View {
        Section {
            Picker(LocalizedStringKey("System"), selection: systemBinding) {
                Text(LocalizedStringKey("Smart Router")).tag(AutopilotSystem.router)
                Text(LocalizedStringKey("Phone a Friend")).tag(AutopilotSystem.phoneAFriend)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text(LocalizedStringKey("System"))
        } footer: {
            if config.system == .router, config.routerKind == .appleFoundationModel {
                Text(LocalizedStringKey("Routes on-device. Nothing is sent anywhere to decide."))
            } else if config.system == .router, config.routerKind == .privateCloudCompute {
                Text(LocalizedStringKey("Apple Private Cloud Compute privately decides where each message runs."))
            } else {
                Text(config.system == .router
                     ? LocalizedStringKey("A small cloud router reads each message and decides where it runs.")
                     : LocalizedStringKey("Your on-device model answers everything and calls for the stronger model only when a request is beyond it. Needs a tool-capable local model."))
            }
        }
    }

    private var escalationSection: some View {
        Section {
            Picker(LocalizedStringKey("Escalation"), selection: aggressivenessBinding) {
                Text(LocalizedStringKey("Conserve")).tag(RouterAggressiveness.conserve)
                Text(LocalizedStringKey("Balanced")).tag(RouterAggressiveness.balanced)
                Text(LocalizedStringKey("Frontier")).tag(RouterAggressiveness.frontier)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        } header: {
            Text(LocalizedStringKey("Escalation"))
        } footer: {
            Text(LocalizedStringKey("Conserve keeps almost everything on-device. Frontier escalates whenever quality would clearly benefit."))
        }
    }

    private var privacySection: some View {
        Section {
            Toggle(isOn: pauseBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("Pause cloud escalation"))
                    Text(config.system == .router
                         ? LocalizedStringKey("The router still runs; every answer stays on-device.")
                         : LocalizedStringKey("The hand-off tool is withheld; every answer stays on-device."))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            }
            Toggle(isOn: ragBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey("Allow escalation for knowledge-base chats"))
                    Text(LocalizedStringKey("Escalated answers include retrieved document excerpts."))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private var statsSection: some View {
        Section {
            statRow(LocalizedStringKey("answers routed"), "\(autopilotLedger.totals.totalTurns)")
            statRow(LocalizedStringKey("on-device answers"), "\(autopilotLedger.totals.localTurns)")
            statRow(LocalizedStringKey("cloud answers"), "\(autopilotLedger.totals.cloudTurns)")
            statRow(LocalizedStringKey("overrides"), "\(autopilotLedger.totals.overrides)")
            statRow(LocalizedStringKey("≈ energy saved"), String(format: "%.1f Wh", autopilotLedger.totals.whSaved))
            if autopilotLedger.totals.usdSaved > 0 {
                statRow(LocalizedStringKey("≈ saved"), String(format: "$%.2f", autopilotLedger.totals.usdSaved))
            }
        } footer: {
            Text(LocalizedStringKey("Energy savings are an estimate (≈) based on typical per-token energy for your cloud model versus this device. Not a measurement."))
        }
    }

    private var statusText: String {
        guard config.isReadyToArm else {
            return String(localized: "Not Set Up")
        }
        return modelManager.autoRoutingArmed ? String(localized: "On") : String(localized: "Off")
    }

    private var routerDetailText: String {
        if config.routerKind == .appleFoundationModel {
            return String(localized: "Apple Intelligence (on-device)")
        }
        if config.routerKind == .privateCloudCompute {
            return AppleFoundationModelKind.privateCloudCompute.modelName
        }
        guard let selection = config.routerSelection else { return String(localized: "Not Set Up") }
        return "\(selection.backendName) · \(selection.modelName)"
    }

    private var cloudDetailText: String {
        if config.escalationTarget == .localModel {
            guard let local = config.localEscalation else { return String(localized: "Not Set Up") }
            return String(localized: "On this Mac · \(local.name)")
        }
        if config.escalationTarget == .privateCloudCompute {
            return AppleFoundationModelKind.privateCloudCompute.modelName
        }
        guard let selection = config.escalationSelection else { return String(localized: "Not Set Up") }
        return "\(selection.backendName) · \(selection.modelName)"
    }

    private func updateConfig(_ mutate: (inout AutopilotConfig) -> Void) {
        var updated = AutopilotConfigStore.load()
        mutate(&updated)
        AutopilotConfigStore.save(updated)
        config = updated
        AutopilotAFMBrain.syncWarmState(armed: modelManager.autoRoutingArmed)
    }

    private var systemBinding: Binding<AutopilotSystem> {
        Binding(
            get: { config.system },
            set: { newValue in
                updateConfig { $0.system = newValue }
                // The two systems have different readiness requirements; a
                // half-configured switch must not leave Autopilot armed.
                if modelManager.autoRoutingArmed && !config.isReadyToArm {
                    modelManager.autoRoutingArmed = false
                }
            }
        )
    }

    private var aggressivenessBinding: Binding<RouterAggressiveness> {
        Binding(
            get: { config.aggressiveness },
            set: { newValue in updateConfig { $0.aggressiveness = newValue } }
        )
    }

    private var pauseBinding: Binding<Bool> {
        Binding(
            get: { config.pauseCloudEscalation },
            set: { newValue in updateConfig { $0.pauseCloudEscalation = newValue } }
        )
    }

    private var ragBinding: Binding<Bool> {
        Binding(
            get: { config.allowCloudForRAGTurns },
            set: { newValue in updateConfig { $0.allowCloudForRAGTurns = newValue } }
        )
    }

    private func selectionRow(
        title: LocalizedStringKey,
        detail: String,
        mode: AutopilotSetupMode
    ) -> some View {
        Button {
            setupMode = mode
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(Color.primary)
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }
                Spacer()
                Text(LocalizedStringKey("Change…"))
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(verbatim: value)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
        }
    }
}

/// Standalone sheet wrapper for surfaces outside the Settings tab (the Stored
/// list's Autopilot row). Owns the nested focused-picker presentation.
struct AutopilotSettingsSheet: View {
    @EnvironmentObject var modelManager: AppModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var setupMode: AutopilotSetupMode?

    var body: some View {
        NavigationStack {
            Form {
                AutopilotSettingsPanel(setupMode: $setupMode)
            }
            .navigationTitle(LocalizedStringKey("Autopilot"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringKey("Done")) { dismiss() }
                }
            }
            .sheet(item: $setupMode) { mode in
                AutopilotSetupView(mode: mode)
                    .environmentObject(modelManager)
            }
        }
    }
}
#endif
