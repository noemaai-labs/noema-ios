import SwiftUI

// MARK: - Single source of truth for the diagnostics catalog

/// The canonical list of tools shown on the "Diagnostics & Tools" page. Adding,
/// removing, or relabeling a tool is a one-line change here that updates iOS,
/// macOS, and visionOS at once.
enum DiagnosticsTool: String, CaseIterable, Identifiable {
    case modelDoctor
    case modelInternals
    case storageAdvisor
    case speculativeDecoding
    case datasetHealth
    case toolStore

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .modelDoctor: return "cross.case"
        case .modelInternals: return "cube"
        case .storageAdvisor: return "internaldrive"
        case .speculativeDecoding: return "hare"
        case .datasetHealth: return "checkmark.seal"
        case .toolStore: return "wrench.and.screwdriver"
        }
    }

    var tint: Color {
        switch self {
        case .modelDoctor: return .red
        case .modelInternals: return .purple
        case .storageAdvisor: return .brown
        case .speculativeDecoding: return .mint
        case .datasetHealth: return .cyan
        case .toolStore: return .gray
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .modelDoctor: return "Model Doctor"
        case .modelInternals: return "Model Internals"
        case .storageAdvisor: return "Storage Advisor"
        case .speculativeDecoding: return "Speculative Decoding"
        case .datasetHealth: return "Dataset Health"
        case .toolStore: return "Tool Store"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .modelDoctor: return "Readiness checks for installed models"
        case .modelInternals: return "Metadata & dependency graph"
        case .storageAdvisor: return "Disk usage & cleanup suggestions"
        case .speculativeDecoding: return "Set up drafting & monitor acceptance"
        case .datasetHealth: return "Index status of your datasets"
        case .toolStore: return "Enable model tools & integrations"
        }
    }

    /// The screen this tool opens. This is the single definition consumed by the
    /// iOS hub's `NavigationLink` and by `SettingsView.settingsDestinationView`.
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .modelDoctor: ModelDoctorView()
        case .modelInternals: ModelInternalsHubView()
        case .storageAdvisor: ModelStorageAdvisorView()
        case .speculativeDecoding: SpeculativeDecodingHubView()
        case .datasetHealth: DatasetHealthDashboardView()
        case .toolStore: ToolStoreView()
        }
    }

    /// A section of related tools, used to lay out both the iOS list and the
    /// macOS cards.
    struct Group: Identifiable {
        let id: String
        let header: LocalizedStringKey
        /// SF Symbol shown next to the section title on macOS.
        let icon: String
        let tools: [DiagnosticsTool]
    }

    static var groups: [Group] {
        [
            Group(id: "inspection", header: "Model Inspection", icon: "cube",
                  tools: [.modelDoctor, .modelInternals, .storageAdvisor]),
            Group(id: "performance", header: "Performance", icon: "hare",
                  tools: [.speculativeDecoding]),
            Group(id: "data", header: "Data & Tools", icon: "wrench.and.screwdriver",
                  tools: [.datasetHealth, .toolStore]),
        ]
    }
}

// MARK: - iOS / visionOS hub

struct DiagnosticsHubView: View {
    var body: some View {
        List {
            ForEach(DiagnosticsTool.groups) { group in
                Section {
                    ForEach(group.tools) { tool in
                        NavigationLink {
                            tool.destination
                        } label: {
                            DiagnosticsToolRow(icon: tool.icon,
                                               tint: tool.tint,
                                               title: tool.title,
                                               subtitle: tool.subtitle)
                        }
                    }
                } header: {
                    Text(group.header)
                }
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationTitle(LocalizedStringKey("Diagnostics & Tools"))
    }
}

private struct DiagnosticsToolRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Merged tool wrappers

/// Hosts two existing tool views behind a segmented control so a pair of
/// tightly-related tools reads as a single capability. The child views are
/// reused unchanged; whichever is selected supplies the navigation title.
private struct SegmentedToolPair<First: View, Second: View>: View {
    let firstLabel: LocalizedStringKey
    let secondLabel: LocalizedStringKey
    @ViewBuilder let first: () -> First
    @ViewBuilder let second: () -> Second

    @State private var showingSecond = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showingSecond) {
                Text(firstLabel).tag(false)
                Text(secondLabel).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            if showingSecond {
                second()
            } else {
                first()
            }
        }
    }
}

struct ModelInternalsHubView: View {
    var body: some View {
        SegmentedToolPair(firstLabel: "Metadata", secondLabel: "Dependencies") {
            ModelMetadataInspectorView()
        } second: {
            ModelDependencyGraphView()
        }
    }
}

struct SpeculativeDecodingHubView: View {
    var body: some View {
        SegmentedToolPair(firstLabel: "Setup", secondLabel: "Acceptance") {
            SpeculativeDecodingWizardView()
        } second: {
            MTPAcceptanceDashboardView()
        }
    }
}
