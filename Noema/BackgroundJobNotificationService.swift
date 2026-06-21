import Foundation
import UserNotifications

struct BackgroundJobNotificationSummary: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let threadIdentifier: String
    let userInfo: [String: String]
}

enum BackgroundJobNotificationService {
    static func downloadCompletedSummary(destinationURL: URL, locale: Locale = LocalizationManager.preferredLocale()) -> BackgroundJobNotificationSummary {
        let fileName = destinationURL.lastPathComponent.isEmpty
            ? String(localized: "Downloaded", locale: locale)
            : destinationURL.lastPathComponent
        let body = String.localizedStringWithFormat(
            String(localized: "%@ finished downloading in the background.", locale: locale),
            fileName
        )
        return BackgroundJobNotificationSummary(
            identifier: "noema.background.download.completed.\(stableID(for: destinationURL.path))",
            title: String(localized: "Download complete", locale: locale),
            body: body,
            threadIdentifier: "noema.background.downloads",
            userInfo: [
                "kind": "download_completed",
                "pathHash": stableID(for: destinationURL.path)
            ]
        )
    }

    static func scheduleDownloadCompleted(destinationURL: URL) async {
        await schedule(downloadCompletedSummary(destinationURL: destinationURL))
    }

    static func schedule(_ summary: BackgroundJobNotificationSummary) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
            } catch {
                Task { await logger.log("[BackgroundJobNotification][Error] authorization=\(error.localizedDescription)") }
                return
            }
        case .authorized, .provisional, .ephemeral:
            break
        case .denied:
            return
        @unknown default:
            return
        }

        let content = UNMutableNotificationContent()
        content.title = summary.title
        content.body = summary.body
        content.threadIdentifier = summary.threadIdentifier
        content.userInfo = summary.userInfo
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: summary.identifier,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
        } catch {
            Task { await logger.log("[BackgroundJobNotification][Error] schedule=\(error.localizedDescription)") }
        }
    }

    private static func stableID(for value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
