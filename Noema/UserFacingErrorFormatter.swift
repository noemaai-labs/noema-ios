import Foundation

enum UserFacingModelErrorContext: Equatable, Sendable {
    case localModel
    case remoteModel
}

/// Keeps transport implementation details out of model-facing error copy.
///
/// GGUF inference uses an internal HTTP loopback, so Foundation can describe a
/// local runtime failure as a server connection failure. That description is
/// technically true at the transport layer but misleading to the user.
enum UserFacingErrorFormatter {
    static func message(
        for error: Error,
        context: UserFacingModelErrorContext,
        locale: Locale = LocalizationManager.preferredLocale()
    ) -> String {
        if let transportMessage = transportMessage(for: error, context: context, locale: locale) {
            return transportMessage
        }

        let raw = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? String(localized: "Unknown error", locale: locale) : raw
    }

    /// Replaces only transport-generated descriptions while retaining the
    /// original error for diagnostics. Cancellation and domain-specific model
    /// errors pass through unchanged.
    static func normalizedTransportError(
        _ error: Error,
        context: UserFacingModelErrorContext,
        locale: Locale = LocalizationManager.preferredLocale()
    ) -> Error {
        guard let message = transportMessage(for: error, context: context, locale: locale) else {
            return error
        }
        let original = error as NSError
        return NSError(
            domain: "Noema.UserFacingTransport",
            code: original.code,
            userInfo: [
                NSLocalizedDescriptionKey: message,
                NSUnderlyingErrorKey: error
            ]
        )
    }

    private static func transportMessage(
        for error: Error,
        context: UserFacingModelErrorContext,
        locale: Locale = LocalizationManager.preferredLocale()
    ) -> String? {
        let raw = (error as NSError).localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = raw.lowercased()
        let code = urlErrorCode(from: error)

        if code == .timedOut || containsTimeoutLanguage(lower) {
            switch context {
            case .localModel:
                return String(
                    localized: "The on-device model took too long to respond. Please try again.",
                    locale: locale
                )
            case .remoteModel:
                return String(
                    localized: "The selected model took too long to respond. Please try again.",
                    locale: locale
                )
            }
        }

        if code == .notConnectedToInternet, context == .remoteModel {
            return String(localized: "No internet connection.", locale: locale)
        }

        let unavailableCodes: Set<URLError.Code> = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .resourceUnavailable,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed
        ]
        guard code.map(unavailableCodes.contains) == true || containsGenericConnectionLanguage(lower) else {
            return nil
        }

        switch context {
        case .localModel:
            return String(
                localized: "The on-device model runtime did not respond. Reload the model and try again.",
                locale: locale
            )
        case .remoteModel:
            return String(
                localized: "The selected model is unavailable right now. Please try again.",
                locale: locale
            )
        }
    }

    private static func urlErrorCode(from error: Error) -> URLError.Code? {
        if let urlError = error as? URLError {
            return urlError.code
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: nsError.code)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return urlErrorCode(from: underlying)
        }
        return nil
    }

    private static func containsTimeoutLanguage(_ message: String) -> Bool {
        message.contains("timed out")
            || message.contains("timeout")
            || message.contains("time out")
            || message.contains("took too long")
    }

    private static func containsGenericConnectionLanguage(_ message: String) -> Bool {
        let phrases = [
            "could not connect to the server",
            "cannot connect to the server",
            "couldn't connect to the server",
            "a server with the specified hostname could not be found",
            "the network connection was lost",
            "connection refused",
            "connection reset",
            "host is down",
            "host is unreachable"
        ]
        return phrases.contains(where: message.contains)
    }
}
