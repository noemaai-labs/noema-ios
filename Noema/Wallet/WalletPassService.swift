import Foundation

#if os(iOS)
import PassKit
import UIKit
#endif

@MainActor
final class WalletPassService: ObservableObject {
    static let shared = WalletPassService()

    @Published private(set) var isSigning = false

    private let signingClient: PassSigningClient

    init(signingClient: PassSigningClient = PassSigningClient()) {
        self.signingClient = signingClient
    }

    func signAndAdd(_ draft: BoardingPassDraft) async throws {
        guard !isSigning else { return }
        isSigning = true
        defer { isSigning = false }

        let baseURL = PassScannerSettings.signerBaseURL
        let token = try PassSigningCredentialStore.token()
        let data = try await signingClient.sign(draft, baseURLString: baseURL, token: token)
        try await addSignedPass(data)
    }

    func addSignedPass(_ pkpassData: Data) async throws {
#if os(iOS)
        guard PKAddPassesViewController.canAddPasses() else {
            throw PassSigningError.server(String(localized: "This device cannot add passes to Wallet."))
        }
        let pass = try PKPass(data: pkpassData)
        guard let controller = PKAddPassesViewController(pass: pass) else {
            throw PassSigningError.invalidResponse
        }
        guard let presenter = UIApplication.shared.noemaTopViewController() else {
            throw PassSigningError.server(String(localized: "No active window is available to present Wallet."))
        }
        presenter.present(controller, animated: true)
#else
        throw PassSigningError.server(String(localized: "Wallet passes are available on iOS."))
#endif
    }
}

#if os(iOS)
private extension UIApplication {
    func noemaTopViewController() -> UIViewController? {
        let root = connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: { $0.isKeyWindow })?
            .rootViewController
        return root?.topMostPresentedController()
    }
}

private extension UIViewController {
    func topMostPresentedController() -> UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostPresentedController()
        }
        if let navigation = self as? UINavigationController, let visible = navigation.visibleViewController {
            return visible.topMostPresentedController()
        }
        if let tab = self as? UITabBarController, let selected = tab.selectedViewController {
            return selected.topMostPresentedController()
        }
        return self
    }
}
#endif
