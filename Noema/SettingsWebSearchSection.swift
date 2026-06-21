// SettingsWebSearchSection.swift
import SwiftUI

struct SettingsWebSearchSection: View {
    var body: some View {
        Section(header: Text("Search")) {
            SettingsWebSearchContent()
        }
    }
}

struct SettingsWebSearchContent: View {
    @ObservedObject private var settings = SettingsStore.shared
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @State private var showInfo = false
    @FocusState private var customURLFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $settings.webSearchEnabled) {
                HStack(spacing: 8) {
                    Text("Web Search button")
                    Button { showInfo = true } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("What is Web Search button?"))
                }
            }
            .onChangeCompat(of: settings.webSearchEnabled) { _, on in
                if !on {
                    settings.webSearchArmed = false
                    customURLFocused = false
                }
            }
        .onChange(of: isAdvancedMode) { _, isAdvanced in
            if !isAdvanced { customURLFocused = false }
        }
            .tint(.blue)

            if settings.webSearchEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    if isAdvancedMode {
                        Text("Custom SearXNG URL")
                            .foregroundStyle(.primary)
                        TextField("https://search.noemaai.com", text: $settings.customSearXNGURL)
                            .platformKeyboardType(.url)
                            .autocorrectionDisabled(true)
                            .platformAutocapitalization(.never)
                            .textFieldStyle(.roundedBorder)
                            .focused($customURLFocused)
#if canImport(UIKit)
                            .submitLabel(.done)
#endif
                            .onSubmit { customURLFocused = false }
                        if settings.customSearXNGURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Using default: https://search.noemaai.com. Search requests are available without quotas.")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Using custom instance: \(settings.customSearXNGURL)")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Using default: https://search.noemaai.com. Search requests are available without quotas.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
#if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { customURLFocused = false }
            }
        }
#endif
        .alert("Web Search button", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Allows models to use a privacy-preserving web search API when you tap the globe in chat. Default is ON. In Offline Only mode, the button is disabled.")
        }
    }
}
