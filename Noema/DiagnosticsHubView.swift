// DiagnosticsHubView.swift
//
// A single destination that consolidates the previously sprawling list of
// runtime/model diagnostic tools. Instead of rendering ~17 always-on summary
// cards inline in Settings (each firing its own background `.task` on every
// Settings open), these tools now live one tap away as lightweight grouped
// navigation rows. The heavy tool views — and their background work — only
// load when the user actually opens a specific tool.
//
// Tightly-overlapping tools are merged behind a segmented control so they read
// as a single capability:
//   • Loopback Server      = Loopback Health  +  Runtime Fixes
//   • Model Internals      = Model Metadata   +  Model Dependencies
//   • Speculative Decoding = Speculative Wizard + MTP Acceptance Dashboard
//
// The underlying tool views are reused verbatim; nothing about their internals
// changes here.

import SwiftUI

struct DiagnosticsHubView: View {
    var body: some View {
        List {
            Section {
                row(icon: "waveform.path.ecg", tint: .blue,
                    title: "Runtime Diagnostics",
                    subtitle: "Engine status & live session health") { RuntimeDiagnosticsView() }
                row(icon: "chart.bar.xaxis", tint: .indigo,
                    title: "Runtime Timeline",
                    subtitle: "Recent load & inference events") { RuntimeTimelineView() }
                row(icon: "network", tint: .teal,
                    title: "Loopback Server",
                    subtitle: "Local server health & fixes") { LoopbackServerHubView() }
                row(icon: "doc.text.magnifyingglass", tint: .orange,
                    title: "Load Receipt",
                    subtitle: "What happened on the last model load") { ModelLoadReceiptView() }
                row(icon: "arrow.down.circle", tint: .pink,
                    title: "Unload Verifier",
                    subtitle: "Confirm memory is reclaimed on unload") { ModelUnloadVerificationView() }
            } header: {
                Text(LocalizedStringKey("Runtime & Server"))
            }

            Section {
                row(icon: "cross.case", tint: .red,
                    title: "Model Doctor",
                    subtitle: "Readiness checks for installed models") { ModelDoctorView() }
                row(icon: "cube", tint: .purple,
                    title: "Model Internals",
                    subtitle: "Metadata & dependency graph") { ModelInternalsHubView() }
                row(icon: "internaldrive", tint: .brown,
                    title: "Storage Advisor",
                    subtitle: "Disk usage & cleanup suggestions") { ModelStorageAdvisorView() }
                row(icon: "sparkles", tint: .yellow,
                    title: "Model Recommendations",
                    subtitle: "Benchmarked picks for your device") { ModelBenchmarkRecommendationsView() }
            } header: {
                Text(LocalizedStringKey("Model Inspection"))
            }

            Section {
                row(icon: "slider.horizontal.3", tint: .green,
                    title: "Auto-Tuner",
                    subtitle: "Tune runtime parameters automatically") { ModelAutoTunerView() }
                row(icon: "hare", tint: .mint,
                    title: "Speculative Decoding",
                    subtitle: "Set up drafting & monitor acceptance") { SpeculativeDecodingHubView() }
            } header: {
                Text(LocalizedStringKey("Performance"))
            }

            Section {
                row(icon: "checkmark.seal", tint: .cyan,
                    title: "Dataset Health",
                    subtitle: "Index status of your datasets") { DatasetHealthDashboardView() }
                row(icon: "text.magnifyingglass", tint: .blue,
                    title: "RAG Inspector",
                    subtitle: "Inspect retrieval for the last answer") { RAGInspectorView() }
                row(icon: "wrench.and.screwdriver", tint: .gray,
                    title: "Tool Store",
                    subtitle: "Enable model tools & integrations") { ToolStoreView() }
            } header: {
                Text(LocalizedStringKey("Data & Tools"))
            }
        }
#if os(iOS)
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .navigationTitle(LocalizedStringKey("Diagnostics & Tools"))
    }

    @ViewBuilder
    private func row<Destination: View>(icon: String,
                                        tint: Color,
                                        title: LocalizedStringKey,
                                        subtitle: LocalizedStringKey,
                                        @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            DiagnosticsToolRow(icon: icon, tint: tint, title: title, subtitle: subtitle)
        }
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

struct LoopbackServerHubView: View {
    var body: some View {
        SegmentedToolPair(firstLabel: "Health", secondLabel: "Fixes") {
            LoopbackServerHealthView()
        } second: {
            LoopbackRemediationView()
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
