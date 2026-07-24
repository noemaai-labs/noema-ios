#if canImport(UIKit)
import UIKit

#if canImport(FBSDKCoreKit) && os(iOS)
import FBSDKCoreKit
#endif

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
#if canImport(FBSDKCoreKit) && os(iOS)
        // Avoid SKAdNetwork reporter cache writes from FBSDK background queues
        // that can trigger SwiftUI/AppStorage background publish warnings.
        Settings.shared.isSKAdNetworkReportEnabled = false
        let handled = ApplicationDelegate.shared.application(
            application,
            didFinishLaunchingWithOptions: launchOptions
        )
#else
        let handled = true
#endif
        BackgroundDownloadManager.shared.scheduleMaintenance()
        return handled
    }

#if canImport(FBSDKCoreKit) && os(iOS)
    func applicationDidBecomeActive(_ application: UIApplication) {
        AppEvents.shared.activateApp()
    }
#endif

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        BackgroundDownloadManager.shared.handleEvents(for: identifier, completionHandler: completionHandler)
    }

    func applicationWillTerminate(_ application: UIApplication) {
        // Background-session transfers outlive the process via nsurlsessiond, so the
        // flush leaves them running and only captures foreground-session tasks.
        BackgroundDownloadManager.shared.flushForTermination()
    }

#if canImport(FBSDKCoreKit) && os(iOS)
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        let handled = ApplicationDelegate.shared.application(app, open: url, options: options)
        return handled
    }
#endif
}
#endif
