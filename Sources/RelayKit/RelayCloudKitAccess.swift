import CloudKit
import Foundation

#if os(macOS)
import Security
#endif

private final class RelayCloudKitContainerCache: @unchecked Sendable {
    static let shared = RelayCloudKitContainerCache()

    private let lock = NSLock()
    private var containers: [String: CKContainer] = [:]

    private init() {}

    func container(for containerIdentifier: String) -> CKContainer? {
        let identifier = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let container = containers[identifier] {
            return container
        }

        guard RelayCloudKitAccess.canUseContainer(identifier) else { return nil }

        // CKContainer can trap instead of throwing when its entitlement is
        // invalid. Keep construction behind the signature preflight above and
        // serialize it so launch-time Relay services cannot initialize the
        // same container concurrently.
        let container = CKContainer(identifier: identifier)
        containers[identifier] = container
        return container
    }
}

/// Prevents CloudKit from being initialized when the running macOS process is
/// not signed for the requested container. On recent macOS releases,
/// `CKContainer(identifier:)` traps instead of returning an ordinary error in
/// that situation.
public enum RelayCloudKitAccess {
    /// Returns the process-wide CloudKit container for this identifier after
    /// validating the running app's entitlements and signature.
    public static func containerIfAvailable(_ containerIdentifier: String) -> CKContainer? {
        RelayCloudKitContainerCache.shared.container(for: containerIdentifier)
    }

    public static func canUseContainer(_ containerIdentifier: String) -> Bool {
        let identifier = containerIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identifier.isEmpty else { return false }

#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }

        let containerIdentifiers = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        ) as? [String]
        let services = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-services" as CFString,
            nil
        ) as? [String]
        let teamIdentifier = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.team-identifier" as CFString,
            nil
        ) as? String
        let signatureTeamIdentifier = currentSignatureTeamIdentifier()

        return isAuthorized(
            containerIdentifier: identifier,
            entitledContainerIdentifiers: containerIdentifiers,
            services: services,
            teamIdentifier: teamIdentifier,
            signatureTeamIdentifier: signatureTeamIdentifier
        )
#else
        return true
#endif
    }

    static func isAuthorized(
        containerIdentifier: String,
        entitledContainerIdentifiers: [String]?,
        services: [String]?,
        teamIdentifier: String?,
        signatureTeamIdentifier: String?
    ) -> Bool {
        guard let teamIdentifier,
              !teamIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              signatureTeamIdentifier == teamIdentifier,
              entitledContainerIdentifiers?.contains(containerIdentifier) == true,
              services?.contains("CloudKit") == true else {
            return false
        }
        return true
    }

#if os(macOS)
    private static func currentSignatureTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let values = signingInformation as? [CFString: Any] else {
            return nil
        }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }
#endif
}
