import XCTest
@testable import Noema
#if canImport(UIKit)
import UIKit
#endif

private final class LockedBoardingPassLogStore: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        let snapshot = messages
        lock.unlock()
        return snapshot
    }
}

final class BoardingPassTests: XCTestCase {
    func testBarcodeFieldsOutrankOCRFields() throws {
        let input = BoardingPassExtractionInput(
            barcodes: [
                BarcodeObservation(
                    symbology: .pdf417,
                    rawValue: "PASSENGER: JANE TRAVELER\nFROM: JFK\nTO: LAX\nFLIGHT: NE123\nDEPARTURE: 14:30",
                    confidence: 0.96
                )
            ],
            recognizedText: [
                FieldObservation(key: "rawText", value: "PASSENGER: JANE TRAVELER\nFROM: BOS\nTO: LAX\nFLIGHT: NE123\nDEPARTURE: 14:30", confidence: 0.70, source: .ocr)
            ]
        )

        let draft = try BoardingPassParser.parse(input)

        XCTAssertEqual(draft.journey.originCode, "JFK")
        let merged = ConfidenceFusion.merge(
            barcodeFields: ["journey.originCode": ParsedField(value: "JFK", confidence: 0.95, source: .barcode)],
            ocrFields: ["journey.originCode": ParsedField(value: "BOS", confidence: 0.70, source: .ocr)],
            observations: []
        )
        XCTAssertEqual(merged["journey.originCode"], "JFK")
        XCTAssertEqual(merged["validation.conflict.journey.originCode"], "BOS")
    }

    func testTransportDetectionCoversNonAirModes() {
        XCTAssertEqual(BoardingPassParser.detectMode(text: "TRAIN PLATFORM 4 FROM NYP TO BOS", barcode: ""), .train)
        XCTAssertEqual(BoardingPassParser.detectMode(text: "BUS COACH SERVICE 42", barcode: ""), .bus)
        XCTAssertEqual(BoardingPassParser.detectMode(text: "FERRY PIER 9", barcode: ""), .boat)
    }

    func testRectangularPDF417FixtureBarcodeIsDetected() async throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("PassFixtures", isDirectory: true)
            .appendingPathComponent("Boarding_pass.png")
        let image = try XCTUnwrap(UIImage(contentsOfFile: fixtureURL.path))
        let cgImage = try XCTUnwrap(image.cgImage)

        let barcodes = try await BoardingPassExtractor.detectBarcodesForTesting(in: cgImage)

        XCTAssertTrue(barcodes.contains { $0.symbology == .pdf417 && !$0.rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    func testAirportCityNamesResolveToCorrectIATACodes() throws {
        let input = BoardingPassExtractionInput(
            barcodes: [],
            recognizedText: [
                FieldObservation(key: "rawText", value: "US AIRWAYS\nUS FLIGHT: 32 20FEB\nPHOENIX\nLOS ANGELES\nGate A22\nBoarding Time 534P\nDeparts 604P", confidence: 0.85, source: .ocr)
            ]
        )

        let draft = try BoardingPassParser.parse(input)

        XCTAssertEqual(draft.transportMode, .air)
        XCTAssertEqual(draft.journey.originCode, "PHX")
        XCTAssertEqual(draft.journey.originName, "Phoenix")
        XCTAssertEqual(draft.journey.destinationCode, "LAX")
        XCTAssertEqual(draft.journey.destinationName, "Los Angeles")
    }

    func testRyanairRouteKeepsPrintedDirection() throws {
        let input = BoardingPassExtractionInput(
            barcodes: [],
            recognizedText: [
                FieldObservation(key: "rawText", value: "RYANAIR BESZALLOKARTYA\nFR 8412 BUD\nMILAN (BERGAMO) - BUDAPEST T2B\nBESZALLAS BEFEJEZESE 13:50\nINDULAS IDEJE 14:20", confidence: 0.84, source: .ocr)
            ]
        )

        let draft = try BoardingPassParser.parse(input)

        XCTAssertEqual(draft.journey.originCode, "BGY")
        XCTAssertEqual(draft.journey.destinationCode, "BUD")
    }

    func testFerryRoutePreservesTerminalNames() throws {
        let input = BoardingPassExtractionInput(
            barcodes: [],
            recognizedText: [
                FieldObservation(key: "rawText", value: "BC Ferries\n2017/10/09\nTsawwassen\nTo\nSwartz Bay\nAdult\nTotal 16.70", confidence: 0.88, source: .ocr)
            ]
        )

        let draft = try BoardingPassParser.parse(input)

        XCTAssertEqual(draft.transportMode, .boat)
        XCTAssertEqual(draft.journey.originName, "Tsawwassen")
        XCTAssertEqual(draft.journey.destinationName, "Swartz Bay")
    }

    func testTrainRouteDoesNotInventAirportCodes() throws {
        let input = BoardingPassExtractionInput(
            barcodes: [],
            recognizedText: [
                FieldObservation(key: "rawText", value: "Off-Peak Day Return\nValid for one journey\nfrom Evesham\nto Oxford\nAdult Standard Class", confidence: 0.86, source: .ocr)
            ]
        )

        let draft = try BoardingPassParser.parse(input)

        XCTAssertEqual(draft.transportMode, .train)
        XCTAssertEqual(draft.journey.originCode, "Evesham")
        XCTAssertEqual(draft.journey.destinationCode, "Oxford")
    }

    func testPassImageFixturesAreCommitted() {
        let fixtureNames = [
            "517244651_10229945603679290_1906661255162572393_n.jpg",
            "Boarding_pass.png",
            "IMG_3889.JPG",
            "Gozo-Malta_ferry_ticket.jpg",
            "1_AxsceNOp7Mi1fIXFmhnGyA.png",
            "deltabp.png",
            "what-does-the-writing-on-my-ticket-mean-v0-fkuxfuidltyc1.webp",
            "BC_Ferries_Ferry_Ticket.png",
            "BoardingPass_SSSS.jpg",
            "v4-460px-Get-Your-Boarding-Pass-at-the-Airport-Step-15.jpg",
            "AA-Boarding-Pass-with-Infant-Jun-12-2021.jpg"
        ]
        let fixturesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("PassFixtures", isDirectory: true)

        for name in fixtureNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixturesURL.appendingPathComponent(name).path), name)
        }
    }

    func testValidatorRequiresWalletEssentials() {
        var draft = Self.sampleDraft()
        draft.journey.departureTime = ""
        draft.journey.boardingTime = nil

        let validation = BoardingPassValidator.validate(draft)

        XCTAssertEqual(validation.status, .invalid)
        XCTAssertTrue(validation.issues.contains { $0.field == BoardingPassEditableField.departureTime.rawValue })
    }

    func testValidatorAcceptsBoardingTimeWhenDepartureIsMissing() {
        var draft = Self.sampleDraft()
        draft.journey.departureTime = ""
        draft.journey.boardingTime = "13:50"

        let validation = BoardingPassValidator.validate(draft)
        draft.validation = validation

        XCTAssertNotEqual(validation.status, .invalid)
        XCTAssertFalse(validation.issues.contains { $0.field == BoardingPassEditableField.departureTime.rawValue })
        XCTAssertTrue(draft.isReadyForWallet)
    }

    func testUserEditWinsAndRecordsRevision() {
        var draft = Self.sampleDraft()

        draft.applyUserEdit(field: .seat, value: "12A")

        XCTAssertEqual(draft.journey.seat, "12A")
        XCTAssertEqual(draft.revisions.last?.field, BoardingPassEditableField.seat.rawValue)
        XCTAssertTrue(draft.provenance.userEditedFields.contains(BoardingPassEditableField.seat.rawValue))
    }

    func testTransportModeEditUpdatesWalletTransitTypeAndRecordsRevision() {
        var draft = Self.sampleDraft()

        draft.applyTransportMode(.train)

        XCTAssertEqual(draft.transportMode, .train)
        XCTAssertEqual(draft.documentType, "train_ticket")
        XCTAssertEqual(draft.walletPresentation.transitType, "PKTransitTypeTrain")
        XCTAssertEqual(draft.revisions.last?.field, "transportMode")
        XCTAssertEqual(draft.revisions.last?.oldValue, "air")
        XCTAssertEqual(draft.revisions.last?.newValue, "train")
        XCTAssertTrue(draft.provenance.userEditedFields.contains("transportMode"))
        XCTAssertTrue(draft.provenance.observations.contains { $0.key == "transportMode" && $0.source == .userEdit })
    }

    @MainActor
    func testDraftStoreDeleteAllRemovesDraftsAndStoredImages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoardingPassDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BoardingPassDraftStore(baseDirectory: root)
        var draft = Self.sampleDraft()
        let imageURL = store.protectedImageURL(for: draft.id)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF]).write(to: imageURL)
        draft.rawImagePath = imageURL.path

        store.save(draft)
        XCTAssertEqual(store.drafts.map(\.id), [draft.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: imageURL.path))

        store.deleteAll()

        XCTAssertTrue(store.drafts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: imageURL.path))
    }

    func testDuplicateSerialIsStableForEquivalentDrafts() {
        let draft = Self.sampleDraft()
        var changedID = draft
        changedID.id = UUID()

        XCTAssertEqual(WalletDuplicateResolver.serialNumber(for: draft), WalletDuplicateResolver.serialNumber(for: changedID))
    }

    func testSignerRequestUsesNoemaContract() throws {
        let client = PassSigningClient()
        let request = try client.makeRequest(
            Self.sampleDraft(),
            baseURLString: "https://signer.example.com"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://signer.example.com/v1/wallet/passes/sign")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.apple.pkpass")
        XCTAssertNotNil(request.httpBody)
    }

    func testSignerRequestBodyCarriesWalletHeaderText() throws {
        let client = PassSigningClient()
        let request = try client.makeRequest(
            Self.sampleDraft(),
            baseURLString: "https://signer.example.com"
        )
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let passJSON = try XCTUnwrap(payload["passJSON"] as? [String: Any])

        XCTAssertEqual(passJSON["logoText"] as? String, "Boarding Pass")
        XCTAssertEqual(passJSON["organizationName"] as? String, "Noema Travel Tools")
        XCTAssertEqual(passJSON["description"] as? String, "Trip pass generated from captured boarding pass")
    }

    func testSignerRequestSupportsAdvancedBearerOverride() throws {
        let client = PassSigningClient()
        let request = try client.makeRequest(
            Self.sampleDraft(),
            baseURLString: "https://signer.example.com",
            token: "secret"
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testDefaultSignerURLUsesHostedNoemaSigner() {
        XCTAssertEqual(PassScannerSettings.defaultSignerBaseURL, "https://search.noemaai.com")
    }

    func testPassExtractionSelectionPersistsByModelIdentityWhenPathChanges() {
        clearPassExtractionSelection()
        defer { clearPassExtractionSelection() }
        let selected = makeLocalVisionModel(path: "/tmp/old/Qwen3.5-0.8B-Q3_K_M.gguf")
        let restored = makeLocalVisionModel(path: "/tmp/new/Qwen3.5-0.8B-Q3_K_M.gguf")

        PassExtractionModelCatalog.setActiveModel(selected)

        XCTAssertEqual(PassExtractionModelCatalog.activeModelPath, selected.url.path)
        XCTAssertEqual(PassExtractionModelCatalog.activeModelID, selected.modelID)
        XCTAssertEqual(PassExtractionModelCatalog.activeModelQuant, selected.quant)
        XCTAssertEqual(PassExtractionModelCatalog.activeModel(from: [restored])?.url.path, restored.url.path)
        XCTAssertFalse(PassExtractionModelCatalog.isSelectedModelMissing(in: [restored]))
    }

    func testPassVisionSchemaRequiresCompleteRawExtractionShape() throws {
        let options = PassVisionExtractionService.generationOptions
        guard case .jsonSchema(_, let schema) = options.responseFormat else {
            return XCTFail("Expected JSON schema response format")
        }

        let properties = try XCTUnwrap(schema["properties"]?.value as? [String: Any])
        let required = try XCTUnwrap(schema["required"]?.value as? [String])
        let journey = try XCTUnwrap(properties["journey"] as? [String: Any])
        let journeyRequired = try XCTUnwrap(journey["required"] as? [String])
        let confidence = try XCTUnwrap(properties["confidence"] as? [String: Any])
        let confidenceRequired = try XCTUnwrap(confidence["required"] as? [String])
        let visual = try XCTUnwrap(properties["visual"] as? [String: Any])
        let visualRequired = try XCTUnwrap(visual["required"] as? [String])

        XCTAssertEqual(options.reasoningEnabled, false)
        XCTAssertNil(options.thinkingBudgetTokens)
        XCTAssertEqual(options.maxOutputTokens, 9216)
        XCTAssertEqual(required, ["documentType", "transportMode", "issuer", "traveler", "journey", "confidence", "visual", "warnings"])
        XCTAssertTrue(journeyRequired.contains("origin"))
        XCTAssertTrue(journeyRequired.contains("destination"))
        XCTAssertTrue(journeyRequired.contains("departureTime"))
        XCTAssertEqual(confidenceRequired, ["overall", "fields"])
        XCTAssertEqual(visualRequired, ["hasPrevalentSolidColorBackground"])
    }

    func testPassVisionGenerationOptionsCanDisableThinking() {
        let options = PassVisionExtractionService.generationOptions(reasoningEnabled: false)

        XCTAssertEqual(options.reasoningEnabled, false)
        XCTAssertNil(options.thinkingBudgetTokens)
        XCTAssertEqual(options.maxOutputTokens, 9216)
    }

    func testPassVisionGenerationOptionsCanEnableThinking() {
        let options = PassVisionExtractionService.generationOptions(reasoningEnabled: true)

        XCTAssertEqual(options.reasoningEnabled, true)
        XCTAssertEqual(options.thinkingBudgetTokens, 8000)
        XCTAssertEqual(options.maxOutputTokens, 9216)
    }

    func testVisionRouteSanitizerRejectsDuplicatedDestinationEndpoint() {
        var draft = Self.sampleDraft()
        draft.journey.destinationCode = "JFK"
        draft.journey.destinationName = "New York JFK"
        draft.confidence.overall = 0.92
        draft.confidence.perField["journey.originCode"] = 0.90
        draft.confidence.perField["journey.destinationCode"] = 0.48

        let warnings = PassVisionExtractionService.sanitizeResolvedRouteForTesting(&draft)
        draft.validation = BoardingPassValidator.validate(draft)

        XCTAssertEqual(warnings, ["same_origin_destination_rejected"])
        XCTAssertEqual(draft.journey.originCode, "JFK")
        XCTAssertEqual(draft.journey.destinationCode, "")
        XCTAssertNil(draft.journey.destinationName)
        XCTAssertEqual(draft.confidence.perField["journey.destinationCode"], 0.0)
        XCTAssertLessThanOrEqual(draft.confidence.overall, 0.55)
        XCTAssertEqual(draft.validation.status, .invalid)
        XCTAssertTrue(draft.validation.issues.contains { $0.field == BoardingPassEditableField.destinationCode.rawValue })
    }

    func testVisionRouteSanitizerClearsLowerConfidenceOriginWhenEndpointsMatch() {
        var draft = Self.sampleDraft()
        draft.journey.originCode = "LAX"
        draft.journey.originName = "Los Angeles"
        draft.journey.destinationCode = "LAX"
        draft.journey.destinationName = "Los Angeles"
        draft.confidence.overall = 0.88
        draft.confidence.perField["journey.originCode"] = 0.41
        draft.confidence.perField["journey.destinationCode"] = 0.91

        let warnings = PassVisionExtractionService.sanitizeResolvedRouteForTesting(&draft)

        XCTAssertEqual(warnings, ["same_origin_destination_rejected"])
        XCTAssertEqual(draft.journey.originCode, "")
        XCTAssertNil(draft.journey.originName)
        XCTAssertEqual(draft.journey.destinationCode, "LAX")
        XCTAssertEqual(draft.confidence.perField["journey.originCode"], 0.0)
        XCTAssertLessThanOrEqual(draft.confidence.overall, 0.55)
    }

    func testVisionRouteSanitizerFlagsMissingEndpointWithoutMirroring() {
        var draft = Self.sampleDraft()
        draft.journey.originCode = ""
        draft.journey.originName = nil
        draft.journey.destinationCode = "LAX"
        draft.journey.destinationName = "Los Angeles"
        draft.confidence.overall = 0.86
        draft.confidence.perField["journey.originCode"] = 0.62

        let warnings = PassVisionExtractionService.sanitizeResolvedRouteForTesting(&draft)

        XCTAssertEqual(warnings, ["missing_origin"])
        XCTAssertEqual(draft.journey.originCode, "")
        XCTAssertEqual(draft.journey.destinationCode, "LAX")
        XCTAssertEqual(draft.confidence.perField["journey.originCode"], 0.0)
        XCTAssertLessThanOrEqual(draft.confidence.overall, 0.70)
    }

    func testHostedAppAttestErrorDetectionUsesStableCodes() {
        XCTAssertTrue(PassSigningClient.isRecoverableHostedAppAttestError("app_attest_signature_invalid"))
        XCTAssertTrue(PassSigningClient.isRecoverableHostedAppAttestError("app_attest_signature_invalid request_id=ABC"))
        XCTAssertTrue(PassSigningClient.isRecoverableHostedAppAttestError(" app_attest_unknown_key\n"))
        XCTAssertFalse(PassSigningClient.isRecoverableHostedAppAttestError("Wallet signer failed with status 500."))
    }

    func testPassJSONUsesConfiguredAppleWalletIdentity() {
        let passJSON = PassJSONMapper.map(Self.sampleDraft())

        XCTAssertEqual(passJSON.passTypeIdentifier, "pass.com.noemaai.noema.transport")
        XCTAssertEqual(passJSON.teamIdentifier, "XX3Z6V9TU9")
        XCTAssertEqual(passJSON.logoText, "Boarding Pass")
        XCTAssertEqual(passJSON.organizationName, "Noema Travel Tools")
        XCTAssertEqual(passJSON.description, "Trip pass generated from captured boarding pass")
    }

    func testPassJSONOmitsWalletBarcodeWhenNoOriginalBarcodeWasDetected() {
        var draft = Self.sampleDraft()
        draft.barcode = PassBarcode(symbology: nil, rawValue: nil, decodedFormat: nil, payloadFields: [:])

        let passJSON = PassJSONMapper.map(draft)

        XCTAssertTrue(passJSON.barcodes.isEmpty)
    }

    func testPassJSONPreservesDetectedDataMatrixPayload() throws {
        var draft = Self.sampleDraft()
        draft.barcode = PassBarcode(symbology: .dataMatrix, rawValue: "DATAMATRIX-PAYLOAD", decodedFormat: "vision", payloadFields: [:])

        let barcode = try XCTUnwrap(PassJSONMapper.map(draft).barcodes.first)

        XCTAssertEqual(barcode.message, "DATAMATRIX-PAYLOAD")
        XCTAssertEqual(barcode.format, "PKBarcodeFormatQR")
    }

    func testOffGridBlocksSigner() async {
        NetworkKillSwitch.setEnabled(true)
        defer { NetworkKillSwitch.setEnabled(false) }
        let client = PassSigningClient()

        do {
            _ = try await client.sign(Self.sampleDraft(), baseURLString: "https://signer.example.com")
            XCTFail("Expected off-grid signer failure")
        } catch let error as PassSigningError {
            XCTAssertEqual(error, .offGrid)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVisionJSONExtractionToleratesReasoningAndFencedJSON() throws {
        let response = """
        <think>I should read the pass first.</think>
        ```json
        {"transportMode":"air","journey":{"serviceNumber":"AA995"}}
        ```
        """

        let json = try PassVisionExtractionService.extractJSONObject(from: response)
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let journey = try XCTUnwrap(object["journey"] as? [String: Any])

        XCTAssertEqual(object["transportMode"] as? String, "air")
        XCTAssertEqual(journey["serviceNumber"] as? String, "AA995")
    }

    func testVisionRawOutputScrubsReasoningBeforeDisplay() {
        let response = """
        <think>I should inspect every visible field first.</think>
        {"transportMode":"air","journey":{"serviceNumber":"AA995"}}
        """

        let scrubbed = PassVisionExtractionService.scrubReasoning(from: response)

        XCTAssertFalse(scrubbed.contains("<think>"))
        XCTAssertFalse(scrubbed.contains("inspect every visible field"))
        XCTAssertTrue(scrubbed.contains(#""serviceNumber":"AA995""#))
    }

    func testVisionRawOutputScrubsUnclosedReasoningBeforeDisplay() {
        let response = """
        <think>I should inspect every visible field first.
        {"transportMode":"air","journey":{"serviceNumber":"AA995"}}
        """

        let scrubbed = PassVisionExtractionService.scrubReasoning(from: response)

        XCTAssertFalse(scrubbed.contains("<think>"))
        XCTAssertFalse(scrubbed.contains("inspect every visible field"))
        XCTAssertTrue(scrubbed.contains(#""serviceNumber":"AA995""#))
    }

    func testVisionDecodeFailureLogsUnsanitizedResponseButReturnsScrubbedOutput() async {
        let response = """
        <think>private scanner reasoning</think>
        {"documentType": 42}
        """
        let model = makeLocalVisionModel(path: "/tmp/Qwen3.5-0.8B-Q3_K_M.gguf")

        let store = LockedBoardingPassLogStore()
        let token = await logger.addObserver { message in
            store.append(message)
        }
        let scrubbed = await PassVisionExtractionService.logStructuredOutputFailureForTesting(rawResponse: response, model: model)
        await logger.removeObserver(token)
        let logs = store.snapshot()

        XCTAssertFalse(scrubbed.contains("private scanner reasoning"))
        XCTAssertTrue(scrubbed.contains(#""documentType": 42"#))
        XCTAssertTrue(logs.contains { $0.contains("stage=schema_decode_failed") })
        XCTAssertTrue(logs.contains { $0.contains("private scanner reasoning") })
        XCTAssertTrue(logs.contains { $0.contains(#""documentType": 42"#) })
    }

    func testVisionJSONExtractionRejectsNonJSONOutput() {
        XCTAssertThrowsError(try PassVisionExtractionService.extractJSONObject(from: "I cannot read this pass.")) { error in
            guard case BoardingPassExtractionError.structuredOutputInvalid = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private static func sampleDraft() -> BoardingPassDraft {
        let provenance = PassProvenance(
            observations: [],
            userEditedFields: [],
            imageHash: "hash",
            capturedAt: Date(timeIntervalSince1970: 0),
            extractionMode: "onDevice"
        )
        var draft = BoardingPassDraft(
            transportMode: .air,
            issuer: PassIssuer(name: "Noema Air", shortCode: "NE", iataCode: "NE", railOperatorCode: nil),
            traveler: PassTraveler(fullName: "JANE TRAVELER", familyName: nil, givenName: nil, loyaltyNumber: nil),
            journey: PassJourney(
                originCode: "JFK",
                originName: nil,
                destinationCode: "LAX",
                destinationName: nil,
                serviceNumber: "NE123",
                confirmationNumber: "ABC123",
                seat: nil,
                coachOrCar: nil,
                gate: nil,
                terminal: nil,
                platform: nil,
                boardingGroup: nil,
                boardingZone: nil,
                sequenceNumber: nil,
                fareClass: nil,
                boardingTime: "14:00",
                departureTime: "14:30",
                arrivalTime: nil,
                timeZoneOrigin: nil,
                timeZoneDestination: nil
            ),
            barcode: PassBarcode(symbology: .pdf417, rawValue: "payload", decodedFormat: "vision", payloadFields: [:]),
            confidence: PassConfidence(overall: 0.9, perField: [:]),
            provenance: provenance,
            validation: PassValidation(status: .valid, issues: [])
        )
        draft.validation = BoardingPassValidator.validate(draft)
        return draft
    }

    private func clearPassExtractionSelection() {
        let defaults = UserDefaults.standard
        [
            PassExtractionModelCatalog.activeModelPathKey,
            PassExtractionModelCatalog.activeModelIDKey,
            PassExtractionModelCatalog.activeModelQuantKey,
            PassExtractionModelCatalog.activeModelFormatKey,
            PassExtractionModelCatalog.activeModelNameKey,
            PassExtractionModelCatalog.extractionThinkingEnabledKey
        ].forEach(defaults.removeObject(forKey:))
    }

    private func makeLocalVisionModel(path: String) -> LocalModel {
        LocalModel(
            modelID: "unsloth/Qwen3.5-0.8B-GGUF",
            name: "Qwen3.5 0.8B",
            url: URL(fileURLWithPath: path),
            quant: "Q3_K_M",
            parameterCountLabel: "0.8B",
            architecture: "Qwen",
            architectureFamily: "Qwen",
            format: .gguf,
            sizeGB: 1.0,
            isMultimodal: true,
            isToolCapable: true,
            isDownloaded: true,
            downloadDate: Date(timeIntervalSince1970: 0),
            lastUsedDate: nil,
            isFavourite: false,
            totalLayers: 24,
            moeInfo: nil
        )
    }
}
