// SettingsPythonSection.swift
import SwiftUI

struct SettingsPythonSection: View {
    var body: some View {
        Section(header: Text("Code Execution")) {
            SettingsPythonContent()
        }
    }
}

struct SettingsPythonContent: View {
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showInfo = false

    private var runtimeStatus: PythonRuntimeStatus {
        PythonRuntime.status()
    }

    private var backendLabel: LocalizedStringKey {
        switch runtimeStatus.backend {
        case "embedded":
            return "Using embedded Python runtime."
        case "process":
            return "Using system Python 3."
        default:
            return "Python runtime unavailable."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $settings.pythonEnabled) {
                HStack(spacing: 8) {
                    Text("Python Code Execution")
                    Button { showInfo = true } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("What is Python Code Execution?"))
                }
            }
            .onChange(of: settings.pythonEnabled) { _, on in
                if !on {
                    settings.pythonArmed = false
                }
            }
            .tint(.blue)

            if settings.pythonEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Allows models to write and execute Python code for calculations, data processing, and analysis. Execution is sandboxed with a 30-second timeout.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(backendLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let reason = runtimeStatus.reason, !reason.isEmpty {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(runtimeStatus.isAvailable ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .alert("Python Code Execution", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("When enabled and armed via the + menu in chat, the model can write and run Python code to help answer your questions. Code runs in a sandboxed environment: no network access, no file access outside a temporary directory, and a 30-second timeout.")
        }
    }
}
