// SettingsHuggingFaceSection.swift
import SwiftUI

struct SettingsHuggingFaceSection: View {
    var body: some View {
        Section(header: Text("Model Sources")) {
            SettingsHuggingFaceContent()
        }
    }
}

struct SettingsHuggingFaceContent: View {
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var customURLFocused: Bool

    private var mode: HFEndpoint.Mode {
        HFEndpoint.Mode(rawValue: settings.hfEndpointMode) ?? .official
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(selection: $settings.hfEndpointMode) {
                Text("Official (huggingface.co)").tag(HFEndpoint.Mode.official.rawValue)
                Text("HF-Mirror (hf-mirror.com)").tag(HFEndpoint.Mode.mirror.rawValue)
                Text("Custom Endpoint").tag(HFEndpoint.Mode.custom.rawValue)
            } label: {
                Text("Hugging Face Endpoint")
            }
            .pickerStyle(.menu)
            .onChangeCompat(of: settings.hfEndpointMode) { _, raw in
                if raw != HFEndpoint.Mode.custom.rawValue { customURLFocused = false }
            }

            if mode == .custom {
                TextField("https://hf-mirror.com", text: $settings.hfCustomEndpointURL)
                    .platformKeyboardType(.url)
                    .autocorrectionDisabled(true)
                    .platformAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                    .focused($customURLFocused)
#if canImport(UIKit)
                    .submitLabel(.done)
#endif
                    .onSubmit { customURLFocused = false }
                if let base = HFEndpoint.validatedCustomBase(settings.hfCustomEndpointURL) {
                    Text("Using custom endpoint: \(base.absoluteString)")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Enter an https:// URL with no path. Until then, huggingface.co is used.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Model search and downloads use this endpoint. Choose HF-Mirror if huggingface.co is blocked or slow in your region. Applies to new downloads.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}
