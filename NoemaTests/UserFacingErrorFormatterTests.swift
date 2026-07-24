import Foundation
import XCTest
@testable import Noema

final class UserFacingErrorFormatterTests: XCTestCase {
    private let english = Locale(identifier: "en")

    func testLocalTimeoutDescribesTheOnDeviceModel() {
        let message = UserFacingErrorFormatter.message(
            for: URLError(.timedOut),
            context: .localModel,
            locale: english
        )

        XCTAssertEqual(message, "The on-device model took too long to respond. Please try again.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("server"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("connect"))
    }

    func testLocalConnectionFailureDoesNotExposeLoopbackTransport() {
        let message = UserFacingErrorFormatter.message(
            for: URLError(.cannotConnectToHost),
            context: .localModel,
            locale: english
        )

        XCTAssertEqual(message, "The on-device model runtime did not respond. Reload the model and try again.")
        XCTAssertFalse(message.localizedCaseInsensitiveContains("server"))
        XCTAssertFalse(message.localizedCaseInsensitiveContains("connect"))
    }

    func testFoundationServerWordingIsNormalizedEvenOutsideURLDomain() {
        let error = NSError(
            domain: "SyntheticTransport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not connect to the server."]
        )

        XCTAssertEqual(
            UserFacingErrorFormatter.message(for: error, context: .localModel, locale: english),
            "The on-device model runtime did not respond. Reload the model and try again."
        )
    }

    func testNormalizedTransportErrorRetainsTheUnderlyingDiagnostic() {
        let original = URLError(.cannotConnectToHost)
        let normalized = UserFacingErrorFormatter.normalizedTransportError(
            original,
            context: .localModel,
            locale: english
        ) as NSError

        XCTAssertEqual(
            normalized.localizedDescription,
            "The on-device model runtime did not respond. Reload the model and try again."
        )
        XCTAssertNotNil(normalized.userInfo[NSUnderlyingErrorKey] as? Error)
    }

    func testCancellationPassesThroughWithoutUserFacingRewording() {
        let original = URLError(.cancelled)
        let normalized = UserFacingErrorFormatter.normalizedTransportError(
            original,
            context: .localModel,
            locale: english
        )

        XCTAssertEqual((normalized as? URLError)?.code, .cancelled)
    }

    func testRemoteErrorsNameTheSelectedModelInsteadOfAGenericServer() {
        XCTAssertEqual(
            UserFacingErrorFormatter.message(
                for: URLError(.timedOut),
                context: .remoteModel,
                locale: english
            ),
            "The selected model took too long to respond. Please try again."
        )
        XCTAssertEqual(
            UserFacingErrorFormatter.message(
                for: URLError(.cannotFindHost),
                context: .remoteModel,
                locale: english
            ),
            "The selected model is unavailable right now. Please try again."
        )
    }

    func testUnrelatedErrorsRemainSpecific() {
        let error = NSError(
            domain: "Noema",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "Model weights are missing."]
        )

        XCTAssertEqual(
            UserFacingErrorFormatter.message(for: error, context: .localModel, locale: english),
            "Model weights are missing."
        )
    }
}
