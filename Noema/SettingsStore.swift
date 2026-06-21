// SettingsStore.swift
import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var webSearchEnabled: Bool { // master toggle (default ON)
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: "webSearchEnabled") }
    }
    @Published var offlineOnly: Bool { // grays out button and disables tool
        didSet { UserDefaults.standard.set(offlineOnly, forKey: "offlineOnly") }
    }
    @Published var webSearchArmed: Bool { // globe ON/OFF; persists until tapped again
        didSet { UserDefaults.standard.set(webSearchArmed, forKey: "webSearchArmed") }
    }
    @Published var customSearXNGURL: String { // custom SearXNG instance URL; empty = use default
        didSet { UserDefaults.standard.set(customSearXNGURL, forKey: "customSearXNGURL") }
    }
    @Published var pythonEnabled: Bool { // master toggle (default ON)
        didSet { UserDefaults.standard.set(pythonEnabled, forKey: "pythonEnabled") }
    }
    @Published var pythonArmed: Bool { // python ON/OFF; persists until tapped again
        didSet { UserDefaults.standard.set(pythonArmed, forKey: "pythonArmed") }
    }
    @Published var memoryEnabled: Bool { // master toggle (default ON)
        didSet {
            UserDefaults.standard.set(memoryEnabled, forKey: "memoryEnabled")
            NotificationCenter.default.post(name: .memoryStoreDidChange, object: nil)
        }
    }
    @Published var memoryReviewRequired: Bool {
        didSet { UserDefaults.standard.set(memoryReviewRequired, forKey: "memoryReviewRequired") }
    }
    @Published var toolDryRunEnabled: Bool {
        didSet { UserDefaults.standard.set(toolDryRunEnabled, forKey: "toolDryRunEnabled") }
    }
    @Published var hfEndpointMode: String { // "official" | "mirror" | "custom"
        didSet {
            UserDefaults.standard.set(hfEndpointMode, forKey: HFEndpoint.modeKey)
            HFEndpoint.applyEnvironment()
        }
    }
    @Published var hfCustomEndpointURL: String { // custom HF endpoint origin; empty/invalid = official
        didSet {
            UserDefaults.standard.set(hfCustomEndpointURL, forKey: HFEndpoint.customURLKey)
            HFEndpoint.applyEnvironment()
        }
    }
    private init() {
        let d = UserDefaults.standard
        self.webSearchEnabled  = d.object(forKey: "webSearchEnabled") as? Bool ?? true  // default ON
        self.offlineOnly       = d.object(forKey: "offlineOnly") as? Bool ?? false
        self.webSearchArmed    = d.object(forKey: "webSearchArmed") as? Bool ?? false
        self.customSearXNGURL  = d.string(forKey: "customSearXNGURL") ?? ""
        self.pythonEnabled     = d.object(forKey: "pythonEnabled") as? Bool ?? true  // default ON
        self.pythonArmed       = d.object(forKey: "pythonArmed") as? Bool ?? false
        self.memoryEnabled     = d.object(forKey: "memoryEnabled") as? Bool ?? true  // default ON
        self.memoryReviewRequired = d.object(forKey: "memoryReviewRequired") as? Bool ?? true
        self.toolDryRunEnabled = d.object(forKey: "toolDryRunEnabled") as? Bool ?? false
        self.hfEndpointMode    = d.string(forKey: HFEndpoint.modeKey) ?? HFEndpoint.Mode.official.rawValue
        self.hfCustomEndpointURL = d.string(forKey: HFEndpoint.customURLKey) ?? ""
    }
}
