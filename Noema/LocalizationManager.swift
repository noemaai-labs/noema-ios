import Foundation
import SwiftUI

@MainActor
final class LocalizationManager: ObservableObject {
    nonisolated static let supportedLanguages: [String] = [
        "en",
        "ar",
        "zh-Hans",
        "es",
        "fr",
        "de",
        "hi",
        "ja",
        "ko",
        "ro",
        "tr"
    ]

    @AppStorage("appLanguageCode") private var storedLanguageCode: String = LocalizationManager.detectSystemLanguage()

    @Published var locale: Locale

    init() {
        let initialCode = LocalizationManager.normalize(
            code: UserDefaults.standard.string(forKey: "appLanguageCode") ?? LocalizationManager.detectSystemLanguage()
        )
        _locale = Published(initialValue: Locale(identifier: initialCode))
        storedLanguageCode = initialCode
    }

    func updateLanguage(code: String) {
        let normalized = LocalizationManager.normalize(code: code)
        storedLanguageCode = normalized
        locale = Locale(identifier: normalized)
    }

    /// Returns the current app locale taking the persisted override into account.
    nonisolated static func preferredLocale() -> Locale {
        let stored = UserDefaults.standard.string(forKey: "appLanguageCode") ?? detectSystemLanguage()
        let normalized = normalize(code: stored)
        return Locale(identifier: normalized)
    }

    nonisolated static func detectSystemLanguage() -> String {
        let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
        return normalize(code: preferred)
    }

    nonisolated private static func normalize(code: String) -> String {
        let trimmed = code.replacingOccurrences(of: "_", with: "-").lowercased()
        let match = supportedLanguages.first {
            let lowered = $0.lowercased()
            return trimmed.hasPrefix(lowered)
        }
        return match ?? "en"
    }
}

extension String {
    /// Returns the localized variant for the current bundle.
    var localized: String {
        NSLocalizedString(self, comment: "")
    }
}

extension LocalizationManager {
    /// Exposes the currently selected language code for views that need to read it at init time.
    var currentCode: String { storedLanguageCode }
}
