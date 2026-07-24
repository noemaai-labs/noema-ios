import SwiftUI

// MARK: - Single source of truth for the Tools catalog

/// The canonical list of tools shown on the "Tools" tab. Adding, removing, or
/// relabeling an entry is a one-line change here that updates every platform.
enum ToolsFeature: String, CaseIterable, Identifiable {
    case boardingPasses
    case benchmarking
    case flashcards

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .boardingPasses: return "airplane"
        case .benchmarking: return "speedometer"
        case .flashcards: return "rectangle.stack"
        }
    }

    var tint: Color {
        switch self {
        case .boardingPasses: return .indigo
        case .benchmarking: return .orange
        case .flashcards: return .purple
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .boardingPasses: return "Boarding Passes"
        case .benchmarking: return "Benchmarking Center"
        case .flashcards: return "Flashcards"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .boardingPasses: return "Scan a boarding pass"
        case .benchmarking: return "Measure and compare model speed on this device"
        case .flashcards: return "Generate and study flashcards with a local model"
        }
    }

    /// The screen this entry opens. Single definition consumed by both the list
    /// rows and the macOS cards.
    @MainActor @ViewBuilder
    var destination: some View {
        switch self {
        case .boardingPasses: BoardingPassesToolView()
        case .benchmarking: BenchmarkingCenterView()
        case .flashcards: FlashcardsHomeView()
        }
    }

    struct Group: Identifiable {
        let id: String
        let header: LocalizedStringKey
        let icon: String
        let features: [ToolsFeature]
    }

    static var groups: [Group] {
        [
            Group(id: "boardingPass", header: "Boarding Pass", icon: "airplane",
                  features: [.boardingPasses]),
            Group(id: "performance", header: "Performance", icon: "speedometer",
                  features: [.benchmarking]),
            Group(id: "study", header: "Study", icon: "graduationcap",
                  features: [.flashcards])
        ]
    }
}

// MARK: - Hub

struct ToolsHubView: View {
    var body: some View {
        NavigationStack {
            hubContent
        }
    }

    @ViewBuilder
    private var hubContent: some View {
#if os(macOS)
        ToolsHubMacContent()
#else
        ToolsHubListContent()
#endif
    }
}

// MARK: - iOS / visionOS list

private struct ToolsHubListContent: View {
    var body: some View {
        List {
            ForEach(ToolsFeature.groups) { group in
                Section {
                    ForEach(group.features) { feature in
                        NavigationLink {
                            feature.destination
                        } label: {
                            ToolsFeatureRow(icon: feature.icon,
                                            tint: feature.tint,
                                            title: feature.title,
                                            subtitle: feature.subtitle)
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
        .navigationTitle(LocalizedStringKey("Tools"))
    }
}

private struct ToolsFeatureRow: View {
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

// MARK: - macOS industrial cards

#if os(macOS)
private struct ToolsHubMacContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(ToolsFeature.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        IndustrialSectionHeader(group.header)

                        VStack(spacing: 0) {
                            ForEach(Array(group.features.enumerated()), id: \.element.id) { idx, feature in
                                NavigationLink {
                                    feature.destination
                                } label: {
                                    ToolsFeatureMacRow(icon: feature.icon,
                                                       tint: feature.tint,
                                                       title: feature.title,
                                                       subtitle: feature.subtitle)
                                }
                                .buttonStyle(.plain)

                                if idx < group.features.count - 1 {
                                    IndustrialHairline().padding(.leading, 46)
                                }
                            }
                        }
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.035))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .navigationTitle(LocalizedStringKey("Tools"))
    }
}

private struct ToolsFeatureMacRow: View {
    let icon: String
    let tint: Color
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.opacity(0.16))
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.4))
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.25))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
#endif

// MARK: - Boarding Passes entry (Scan | Create)

/// One hub entry hosting both boarding-pass tools. The scanner + Wallet creator
/// (`PassScanner/` + `Wallet/`) are iOS-only, so this surfaces the existing
/// `PassScannerFlowView` on iOS and a "made on your iPhone" note elsewhere.
struct BoardingPassesToolView: View {
    var body: some View {
#if os(iOS)
        BoardingPassesContent()
#else
        BoardingPassesUnavailableView()
#endif
    }
}

#if os(iOS)
private struct BoardingPassesContent: View {
    @EnvironmentObject private var modelManager: AppModelManager
    @State private var showFlow = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Image(systemName: "airplane")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.indigo)
                        .padding(.top, 6)
                    Text(LocalizedStringKey("Scan a boarding pass"))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(LocalizedStringKey("Point the camera at a pass or pick a photo. Everything is read on-device."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    showFlow = true
                } label: {
                    Label(LocalizedStringKey("Scan a Pass"), systemImage: "doc.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                HStack(spacing: 8) {
                    infoChip("On-device", systemImage: "lock.shield")
                    infoChip("Vision + VLM", systemImage: "eye")
                }
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LocalizedStringKey("Boarding Passes"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFlow) {
            PassScannerFlowView()
                .environmentObject(modelManager)
        }
    }

    private func infoChip(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }
}
#endif

#if !os(iOS)
private struct BoardingPassesUnavailableView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.indigo)
            Text(LocalizedStringKey("Boarding Passes on iPhone & iPad"))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(LocalizedStringKey("Scanning and creating Apple Wallet passes uses the camera and PassKit, which are available on iPhone and iPad."))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
        .navigationTitle(LocalizedStringKey("Boarding Passes"))
    }
}
#endif
