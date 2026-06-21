#if os(iOS)
import Foundation
import UIKit

struct PassVisionExtractionResult: Sendable {
    var draft: BoardingPassDraft
    var rawJSON: String
    var rawModelOutput: String
}

struct PassVisionExtractionOutputError: LocalizedError {
    var rawOutput: String

    var errorDescription: String? {
        BoardingPassExtractionError.structuredOutputInvalid.errorDescription
    }
}

private enum PassVisionStructuredOutputFailureStage: String {
    case noJSONObjectFound = "no_json_object_found"
    case invalidJSONObject = "invalid_json_object"
    case schemaDecodeFailed = "schema_decode_failed"
}

private struct PassVisionStructuredOutputFailure: Error {
    var stage: PassVisionStructuredOutputFailureStage
    var rawResponse: String
    var scrubbedResponse: String
    var jsonCandidate: String?
    var underlyingDescription: String?
}

private struct PassVisionParsedOutput {
    var decoded: PassVisionStructuredOutput
    var rawJSON: String
    var scrubbedResponse: String
}

private struct PassVisionStructuredOutput: Decodable {
    struct Issuer: Decodable {
        var name: String?
        var shortCode: String?
        var iataCode: String?
        var railOperatorCode: String?
    }

    struct Traveler: Decodable {
        var fullName: String?
        var familyName: String?
        var givenName: String?
        var loyaltyNumber: String?
    }

    struct Endpoint: Decodable {
        var code: String?
        var iataCode: String?
        var name: String?
        var city: String?
        var country: String?
        var kind: String?
    }

    struct Journey: Decodable {
        var origin: Endpoint?
        var destination: Endpoint?
        var serviceNumber: String?
        var confirmationNumber: String?
        var seat: String?
        var coachOrCar: String?
        var gate: String?
        var terminal: String?
        var platform: String?
        var boardingGroup: String?
        var boardingZone: String?
        var sequenceNumber: String?
        var fareClass: String?
        var date: String?
        var boardingTime: String?
        var departureTime: String?
        var arrivalTime: String?
    }

    struct Confidence: Decodable {
        var overall: Double?
        var fields: [String: Double]?
    }

    struct Visual: Decodable {
        var hasPrevalentSolidColorBackground: Bool?
    }

    var documentType: String?
    var transportMode: String?
    var issuer: Issuer?
    var traveler: Traveler?
    var journey: Journey?
    var confidence: Confidence?
    var visual: Visual?
    var warnings: [String]?
}

final class PassVisionExtractionService {
    private static let extractionContextTokens = 12_000
    private static let extractionOutputTokens = 9_216
    private static let extractionThinkingBudgetTokens = 8_000
    private static let noValueSentinel = "__NO_VALUE__"

    func extract(
        imagePath: String,
        evidence: BoardingPassExtractionInput,
        model: LocalModel,
        evidenceDraft: BoardingPassDraft?
    ) async throws -> PassVisionExtractionResult {
        guard PassExtractionModelCatalog.isCompatibleVisionModel(model) else {
            throw BoardingPassExtractionError.selectedModelCannotReadImages
        }

        let runner = try await RunnerFactory.load(
            url: model.url,
            format: model.format,
            isVision: true,
            contextLength: Self.extractionContextTokens,
            preferContextOverEnvironment: true,
            forceFreshLoopback: model.format == .gguf
        )
        guard case .llm(let client) = runner else {
            throw BoardingPassExtractionError.selectedModelCannotReadImages
        }
        let extractionResult: PassVisionExtractionResult
        do {
            let response = try await client.text(
                from: .multimodal(
                    messages: [
                        ChatMessage(role: "system", content: Self.systemPrompt),
                        ChatMessage(role: "user", content: Self.userPrompt(evidence: evidence))
                    ],
                    imagePaths: [imagePath],
                    generationOptions: Self.generationOptions(
                        reasoningEnabled: PassExtractionModelCatalog.supportsExtractionThinking(model)
                            && PassExtractionModelCatalog.extractionThinkingEnabled
                    )
                )
            )
            let parsed: PassVisionParsedOutput
            do {
                parsed = try Self.parseStructuredOutput(from: response)
            } catch let failure as PassVisionStructuredOutputFailure {
                await Self.logStructuredOutputFailure(failure, model: model)
                throw PassVisionExtractionOutputError(rawOutput: failure.scrubbedResponse)
            }
            let draft = Self.makeDraft(
                from: parsed.decoded,
                rawJSON: parsed.rawJSON,
                evidence: evidence,
                evidenceDraft: evidenceDraft,
                model: model,
                imagePath: imagePath
            )
            extractionResult = PassVisionExtractionResult(draft: draft, rawJSON: parsed.rawJSON, rawModelOutput: parsed.scrubbedResponse)
        } catch let error as PassVisionExtractionOutputError {
            await client.unloadAndWait()
            throw error
        } catch {
            await client.unloadAndWait()
            throw error
        }
        await client.unloadAndWait()
        return extractionResult
    }

    static var generationOptions: LLMGenerationOptions {
        generationOptions(reasoningEnabled: false)
    }

    static func generationOptions(reasoningEnabled: Bool) -> LLMGenerationOptions {
        LLMGenerationOptions(
            reasoningEnabled: reasoningEnabled,
            maxOutputTokens: extractionOutputTokens,
            thinkingBudgetTokens: reasoningEnabled ? extractionThinkingBudgetTokens : nil,
            responseFormat: .jsonSchema(name: "pass_extraction", schema: responseSchema)
        )
    }

    private static var responseSchema: [String: AnyCodable] {
        [
            "type": AnyCodable("object"),
            "required": AnyCodable(["documentType", "transportMode", "issuer", "traveler", "journey", "confidence", "visual", "warnings"]),
            "additionalProperties": AnyCodable(false),
            "properties": AnyCodable([
                "documentType": ["type": "string"],
                "transportMode": ["type": "string", "enum": ["air", "train", "bus", "boat", "generic"]],
                "issuer": [
                    "type": "object",
                    "required": ["name", "shortCode", "iataCode", "railOperatorCode"],
                    "additionalProperties": false,
                    "properties": stringProperties(["name", "shortCode", "iataCode", "railOperatorCode"])
                ],
                "traveler": [
                    "type": "object",
                    "required": ["fullName", "familyName", "givenName", "loyaltyNumber"],
                    "additionalProperties": false,
                    "properties": stringProperties(["fullName", "familyName", "givenName", "loyaltyNumber"])
                ],
                "journey": [
                    "type": "object",
                    "required": [
                        "origin", "destination", "serviceNumber", "confirmationNumber", "seat", "coachOrCar",
                        "gate", "terminal", "platform", "boardingGroup", "boardingZone", "sequenceNumber",
                        "fareClass", "date", "boardingTime", "departureTime", "arrivalTime"
                    ],
                    "additionalProperties": false,
                    "properties": [
                        "origin": endpointSchema,
                        "destination": endpointSchema,
                        "serviceNumber": ["type": "string"],
                        "confirmationNumber": ["type": "string"],
                        "seat": ["type": "string"],
                        "coachOrCar": ["type": "string"],
                        "gate": ["type": "string"],
                        "terminal": ["type": "string"],
                        "platform": ["type": "string"],
                        "boardingGroup": ["type": "string"],
                        "boardingZone": ["type": "string"],
                        "sequenceNumber": ["type": "string"],
                        "fareClass": ["type": "string"],
                        "date": ["type": "string"],
                        "boardingTime": ["type": "string"],
                        "departureTime": ["type": "string"],
                        "arrivalTime": ["type": "string"]
                    ]
                ],
                "confidence": [
                    "type": "object",
                    "required": ["overall", "fields"],
                    "additionalProperties": false,
                    "properties": [
                        "overall": ["type": "number"],
                        "fields": [
                            "type": "object",
                            "additionalProperties": ["type": "number"]
                        ]
                    ]
                ],
                "visual": [
                    "type": "object",
                    "required": ["hasPrevalentSolidColorBackground"],
                    "additionalProperties": false,
                    "properties": [
                        "hasPrevalentSolidColorBackground": ["type": "boolean"]
                    ]
                ],
                "warnings": [
                    "type": "array",
                    "items": ["type": "string"]
                ]
            ])
        ]
    }

    private static var endpointSchema: [String: Any] {
        [
            "type": "object",
            "required": ["code", "iataCode", "name", "city", "country", "kind"],
            "additionalProperties": false,
            "properties": stringProperties(["code", "iataCode", "name", "city", "country", "kind"])
        ]
    }

    private static func stringProperties(_ names: [String]) -> [String: [String: String]] {
        Dictionary(uniqueKeysWithValues: names.map { ($0, ["type": "string"]) })
    }

    private static var systemPrompt: String {
        """
        You are Noema Pass Scanner. Read one image of a transportation pass or ticket and extract only facts visibly printed on the pass or strongly confirmed by barcode/OCR evidence.

        Look specifically for: document type, transport mode, issuer/operator, passenger/traveler name, origin, destination, flight/train/bus/ferry/service number, confirmation/booking code, date, boarding/departure/arrival times, seat, coach/car, gate, terminal, platform, boarding group/zone, sequence number, fare class, barcode payload, whether the pass has a prevalent solid color background other than white or black, and warnings.

        Do not guess. Do not infer a field from general world knowledge when it is not visible or supported by barcode/OCR evidence. If a field is missing, unreadable, ambiguous, unrelated to a transportation pass, or you are not sure, output "\(noValueSentinel)" for that string field so Noema can exclude it. Use confidence 0.0 for excluded or uncertain fields.

        Route direction is safety-critical. Never set journey.origin and journey.destination to the same endpoint unless the pass visibly and explicitly says the trip starts and ends at the same place, which is very rare.

        You must identify separate evidence for origin and destination. Separate evidence means one of: explicit labels such as FROM/TO, ORIGIN/DESTINATION, DEPART/ARRIVE, DEP/ARR, EMBARK/DISEMBARK; a directional route pattern such as "AAA -> BBB", "AAA to BBB", "AAA - BBB", or "AAA/BBB" when the pass clearly uses it as a route; or barcode evidence that encodes distinct origin and destination fields.

        If only one location is visible, do not copy it into both fields. Put "\(noValueSentinel)" for the missing endpoint and add "missing_origin" or "missing_destination" to warnings. If the same text could be either origin or destination, but direction is unclear, exclude the uncertain endpoint or both endpoints and add "ambiguous_route_direction" to warnings. If origin and destination would be identical after normalization, set the lower-confidence endpoint to "\(noValueSentinel)" and add "same_origin_destination_rejected" to warnings.

        Endpoint confidence rules: use confidence >= 0.85 only when the endpoint is directly labeled or encoded in barcode evidence; use confidence 0.60 to 0.84 when the endpoint is visible in a clear route pattern but not explicitly labeled; use confidence below 0.50 when direction is uncertain; use confidence 0.0 for any endpoint field set to "\(noValueSentinel)".

        If the image is not a transportation pass or ticket, return documentType "\(noValueSentinel)", transportMode "generic", put "\(noValueSentinel)" in every string field, confidence.overall 0.0, and add "not_transportation_pass" to warnings.

        After any private reasoning, return exactly one valid JSON object matching the requested schema. Do not return markdown, prose, code fences, or explanations in the final answer.
        """
    }

    private static func userPrompt(evidence: BoardingPassExtractionInput) -> String {
        let barcodeSummary = evidence.barcodes.map { "\($0.symbology.rawValue): \($0.rawValue)" }.joined(separator: "\n")
        let ocrSummary = evidence.recognizedText.map(\.value).joined(separator: "\n")
        return """
        Classify the image as one of: air, train, bus, boat, generic.
        Read visible text carefully. Preserve route direction with special care. Do not mirror or duplicate the same city, airport, station, port, or stop into both origin and destination.
        For route extraction, first look for explicit directional labels such as FROM, TO, ORIGIN, DESTINATION, DEP, ARR, DEPARTURE, ARRIVAL, BOARDING AT, or ARRIVING AT. If those labels exist, use them over layout guesses.
        Then look for directional symbols or text such as "A -> B", "A to B", "A - B", or route pairs printed near the service number. Treat the left/start side as origin only when the ticket layout clearly indicates travel direction.
        For air travel, use IATA airport codes only when visible or confidently implied by the printed airport/city name. For trains, ferries, and buses, keep station, terminal, or port names when no standard code is printed.
        If only one endpoint is visible, fill only the endpoint supported by evidence and set the other endpoint to "\(noValueSentinel)". If you cannot tell whether the visible place is origin or destination, set both endpoint fields to "\(noValueSentinel)" and add "ambiguous_route_direction" to warnings.
        Route warning rules: add "missing_origin" when destination is supported but origin is absent or unreadable; add "missing_destination" when origin is supported but destination is absent or unreadable; add "ambiguous_route_direction" when route locations are visible but direction is unclear; add "same_origin_destination_rejected" when origin and destination appear identical or nearly identical after normalization; add "weak_endpoint_evidence" when either endpoint is inferred from layout rather than explicit labels, directional route text, or barcode evidence.
        Set visual.hasPrevalentSolidColorBackground to true only when the pass/ticket itself has a large, clearly dominant solid background color that is not white, near-white, black, or near-black. Do not name the color; Noema will compute it locally.
        Use "\(noValueSentinel)" for every uncertain, absent, unreadable, or non-pass field.

        JSON shape:
        {
          "documentType": "boarding_pass|train_ticket|ferry_ticket|bus_ticket|ticket",
          "transportMode": "air|train|bus|boat|generic",
          "issuer": {"name": "", "shortCode": "", "iataCode": "", "railOperatorCode": ""},
          "traveler": {"fullName": "", "familyName": "", "givenName": "", "loyaltyNumber": ""},
          "journey": {
            "origin": {"code": "", "iataCode": "", "name": "", "city": "", "country": "", "kind": "airport|station|port|stop|unknown"},
            "destination": {"code": "", "iataCode": "", "name": "", "city": "", "country": "", "kind": "airport|station|port|stop|unknown"},
            "serviceNumber": "", "confirmationNumber": "", "seat": "", "coachOrCar": "",
            "gate": "", "terminal": "", "platform": "", "boardingGroup": "", "boardingZone": "",
            "sequenceNumber": "", "fareClass": "", "date": "", "boardingTime": "",
            "departureTime": "", "arrivalTime": ""
          },
          "confidence": {"overall": 0.0, "fields": {}},
          "visual": {"hasPrevalentSolidColorBackground": false},
          "warnings": []
        }

        Barcode evidence:
        \(barcodeSummary.isEmpty ? "None" : barcodeSummary)

        OCR evidence:
        \(ocrSummary.isEmpty ? "None" : ocrSummary)
        """
    }

    static func extractJSONObject(from response: String) throws -> String {
        do {
            return try extractJSONObjectDetailed(from: response).json
        } catch {
            throw BoardingPassExtractionError.structuredOutputInvalid
        }
    }

    private static func parseStructuredOutput(from rawResponse: String) throws -> PassVisionParsedOutput {
        let extracted: (json: String, scrubbed: String)
        do {
            extracted = try extractJSONObjectDetailed(from: rawResponse)
        } catch let failure as PassVisionStructuredOutputFailure {
            throw failure
        } catch {
            let scrubbed = scrubReasoning(from: rawResponse)
            throw PassVisionStructuredOutputFailure(
                stage: .noJSONObjectFound,
                rawResponse: rawResponse,
                scrubbedResponse: scrubbed,
                jsonCandidate: nil,
                underlyingDescription: error.localizedDescription
            )
        }

        do {
            let decoded = try JSONDecoder().decode(PassVisionStructuredOutput.self, from: Data(extracted.json.utf8))
            return PassVisionParsedOutput(decoded: decoded, rawJSON: extracted.json, scrubbedResponse: extracted.scrubbed)
        } catch {
            throw PassVisionStructuredOutputFailure(
                stage: .schemaDecodeFailed,
                rawResponse: rawResponse,
                scrubbedResponse: extracted.scrubbed,
                jsonCandidate: extracted.json,
                underlyingDescription: String(describing: error)
            )
        }
    }

    private static func extractJSONObjectDetailed(from response: String) throws -> (json: String, scrubbed: String) {
        let scrubbed = scrubReasoning(from: response)
        let trimmed = scrubbed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            guard isJSONObject(trimmed) else {
                throw PassVisionStructuredOutputFailure(
                    stage: .invalidJSONObject,
                    rawResponse: response,
                    scrubbedResponse: scrubbed,
                    jsonCandidate: trimmed,
                    underlyingDescription: nil
                )
            }
            return (trimmed, scrubbed)
        }

        var lastValidObject: String?
        var lastCandidate: String?
        var searchIndex = trimmed.startIndex
        while let start = trimmed[searchIndex...].firstIndex(of: "{") {
            if let candidate = balancedJSONObject(in: trimmed, startingAt: start) {
                lastCandidate = candidate
                if isJSONObject(candidate) {
                    lastValidObject = candidate
                }
                searchIndex = trimmed.index(start, offsetBy: candidate.count, limitedBy: trimmed.endIndex) ?? trimmed.index(after: start)
            } else {
                searchIndex = trimmed.index(after: start)
            }
        }

        if let lastValidObject {
            return (lastValidObject, scrubbed)
        }
        if let lastCandidate {
            throw PassVisionStructuredOutputFailure(
                stage: .invalidJSONObject,
                rawResponse: response,
                scrubbedResponse: scrubbed,
                jsonCandidate: lastCandidate,
                underlyingDescription: nil
            )
        }
        throw PassVisionStructuredOutputFailure(
            stage: .noJSONObjectFound,
            rawResponse: response,
            scrubbedResponse: scrubbed,
            jsonCandidate: nil,
            underlyingDescription: nil
        )
    }

    static func scrubReasoning(from response: String) -> String {
        var text = response
        while let open = text.range(of: "<think>", options: [.caseInsensitive]) {
            if let close = text.range(of: "</think>", options: [.caseInsensitive], range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else if let jsonStart = text[open.upperBound...].firstIndex(of: "{"),
                      let json = balancedJSONObject(in: text, startingAt: jsonStart) {
                text = String(text[..<open.lowerBound]) + json
                break
            } else {
                text.replaceSubrange(open.lowerBound..<text.endIndex, with: "[reasoning omitted]")
                break
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func logStructuredOutputFailure(_ failure: PassVisionStructuredOutputFailure, model: LocalModel) async {
        let candidate = failure.jsonCandidate ?? "<none>"
        let underlying = failure.underlyingDescription ?? "<none>"
        await logger.logFull(
            """
            [PassScanner][VisionExtraction][StructuredOutputInvalid] model_id=\(model.modelID) model_name=\(model.name) stage=\(failure.stage.rawValue) raw_chars=\(failure.rawResponse.count) scrubbed_chars=\(failure.scrubbedResponse.count) candidate_chars=\(failure.jsonCandidate?.count ?? 0)
            decoder_error:
            \(underlying)
            json_candidate:
            \(candidate)
            raw_response:
            \(failure.rawResponse)
            scrubbed_response:
            \(failure.scrubbedResponse)
            """
        )
    }

    #if DEBUG
    static func logStructuredOutputFailureForTesting(rawResponse: String, model: LocalModel) async -> String {
        do {
            return try parseStructuredOutput(from: rawResponse).scrubbedResponse
        } catch let failure as PassVisionStructuredOutputFailure {
            await logStructuredOutputFailure(failure, model: model)
            return failure.scrubbedResponse
        } catch {
            let scrubbed = scrubReasoning(from: rawResponse)
            let failure = PassVisionStructuredOutputFailure(
                stage: .noJSONObjectFound,
                rawResponse: rawResponse,
                scrubbedResponse: scrubbed,
                jsonCandidate: nil,
                underlyingDescription: error.localizedDescription
            )
            await logStructuredOutputFailure(failure, model: model)
            return scrubbed
        }
    }
    #endif

    private static func balancedJSONObject(in text: String, startingAt start: String.Index) -> String? {
        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = start

        while index < text.endIndex {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...index])
                }
            }

            index = text.index(after: index)
        }
        return nil
    }

    private static func isJSONObject(_ candidate: String) -> Bool {
        guard let data = candidate.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            return false
        }
        return true
    }

    private static func makeDraft(
        from output: PassVisionStructuredOutput,
        rawJSON: String,
        evidence: BoardingPassExtractionInput,
        evidenceDraft: BoardingPassDraft?,
        model: LocalModel,
        imagePath: String
    ) -> BoardingPassDraft {
        let mode = BoardingPassTransportMode(rawValue: output.transportMode?.lowercased() ?? "") ?? evidenceDraft?.transportMode ?? .generic
        let route = routeOverride(for: mode, output: output, evidence: evidence)
        let issuer = PassIssuer(
            name: clean(output.issuer?.name) ?? evidenceDraft?.issuer.name ?? "",
            shortCode: clean(output.issuer?.shortCode) ?? evidenceDraft?.issuer.shortCode ?? "",
            iataCode: clean(output.issuer?.iataCode) ?? evidenceDraft?.issuer.iataCode,
            railOperatorCode: clean(output.issuer?.railOperatorCode) ?? evidenceDraft?.issuer.railOperatorCode
        )
        let traveler = PassTraveler(
            fullName: clean(output.traveler?.fullName) ?? evidenceDraft?.traveler.fullName ?? "",
            familyName: clean(output.traveler?.familyName) ?? evidenceDraft?.traveler.familyName,
            givenName: clean(output.traveler?.givenName) ?? evidenceDraft?.traveler.givenName,
            loyaltyNumber: clean(output.traveler?.loyaltyNumber) ?? evidenceDraft?.traveler.loyaltyNumber
        )
        let journey = PassJourney(
            originCode: route.originCode,
            originName: route.originName,
            destinationCode: route.destinationCode,
            destinationName: route.destinationName,
            serviceNumber: clean(output.journey?.serviceNumber) ?? evidenceDraft?.journey.serviceNumber ?? "",
            confirmationNumber: clean(output.journey?.confirmationNumber) ?? evidenceDraft?.journey.confirmationNumber,
            seat: clean(output.journey?.seat) ?? evidenceDraft?.journey.seat,
            coachOrCar: clean(output.journey?.coachOrCar) ?? evidenceDraft?.journey.coachOrCar,
            gate: clean(output.journey?.gate) ?? evidenceDraft?.journey.gate,
            terminal: clean(output.journey?.terminal) ?? evidenceDraft?.journey.terminal,
            platform: clean(output.journey?.platform) ?? evidenceDraft?.journey.platform,
            boardingGroup: clean(output.journey?.boardingGroup) ?? evidenceDraft?.journey.boardingGroup,
            boardingZone: clean(output.journey?.boardingZone) ?? evidenceDraft?.journey.boardingZone,
            sequenceNumber: clean(output.journey?.sequenceNumber) ?? evidenceDraft?.journey.sequenceNumber,
            fareClass: clean(output.journey?.fareClass) ?? evidenceDraft?.journey.fareClass,
            boardingTime: clean(output.journey?.boardingTime) ?? evidenceDraft?.journey.boardingTime,
            departureTime: clean(output.journey?.departureTime) ?? clean(output.journey?.date) ?? evidenceDraft?.journey.departureTime ?? "",
            arrivalTime: clean(output.journey?.arrivalTime) ?? evidenceDraft?.journey.arrivalTime,
            timeZoneOrigin: nil,
            timeZoneDestination: nil
        )
        let barcode = PassBarcode(
            symbology: evidence.barcodes.first?.symbology ?? evidenceDraft?.barcode.symbology,
            rawValue: evidence.barcodes.first?.rawValue ?? evidenceDraft?.barcode.rawValue,
            decodedFormat: evidence.barcodes.isEmpty ? evidenceDraft?.barcode.decodedFormat : "vision",
            payloadFields: evidenceDraft?.barcode.payloadFields ?? [:]
        )
        let observations = evidence.recognizedText + visionObservations(from: output, confidence: output.confidence?.fields)
        let provenance = PassProvenance(
            observations: observations,
            userEditedFields: [],
            imageHash: evidence.imageHash,
            capturedAt: evidence.capturedAt,
            extractionMode: "vision:\(model.modelID)"
        )
        var draft = BoardingPassDraft(
            transportMode: mode,
            issuer: issuer,
            traveler: traveler,
            journey: journey,
            barcode: barcode,
            confidence: PassConfidence(overall: min(1, max(0, output.confidence?.overall ?? 0.78)), perField: output.confidence?.fields ?? [:]),
            provenance: provenance,
            validation: PassValidation(status: .needsReview, issues: []),
            thumbnailJPEGData: evidence.thumbnailJPEGData,
            rawImagePath: evidence.rawImagePath
        )
        if let background = dominantSolidBackgroundColor(in: imagePath, shouldDetect: output.visual?.hasPrevalentSolidColorBackground) {
            draft.walletPresentation = .solidBackground(background, for: mode)
        }
        let routeWarnings = sanitizeResolvedRoute(&draft)
        draft.validation = BoardingPassValidator.validate(draft)
        appendVisionWarnings(routeWarnings, to: &draft)
        appendVisionWarnings(output.warnings ?? [], to: &draft)
        appendEvidenceConflicts(evidenceDraft, to: &draft)
        return draft
    }

    @discardableResult
    private static func sanitizeResolvedRoute(_ draft: inout BoardingPassDraft) -> [String] {
        let originKeys = endpointComparisonKeys(code: draft.journey.originCode, name: draft.journey.originName)
        let destinationKeys = endpointComparisonKeys(code: draft.journey.destinationCode, name: draft.journey.destinationName)

        if originKeys.isEmpty, !destinationKeys.isEmpty {
            setEndpointConfidence(.originCode, in: &draft, to: 0)
            draft.confidence.overall = min(draft.confidence.overall, 0.70)
            return ["missing_origin"]
        }

        if destinationKeys.isEmpty, !originKeys.isEmpty {
            setEndpointConfidence(.destinationCode, in: &draft, to: 0)
            draft.confidence.overall = min(draft.confidence.overall, 0.70)
            return ["missing_destination"]
        }

        guard !originKeys.isEmpty, !destinationKeys.isEmpty else { return [] }
        guard !originKeys.isDisjoint(with: destinationKeys) else { return [] }

        let originConfidence = endpointConfidence(.originCode, in: draft)
        let destinationConfidence = endpointConfidence(.destinationCode, in: draft)
        if originConfidence < destinationConfidence {
            clearOrigin(in: &draft)
        } else {
            clearDestination(in: &draft)
        }
        draft.confidence.overall = min(draft.confidence.overall, 0.55)
        return ["same_origin_destination_rejected"]
    }

    private static func endpointComparisonKeys(code: String, name: String?) -> Set<String> {
        let rawValues = [code, name ?? "", PassRouteResolver.airportName(for: code) ?? ""]
        return Set(
            rawValues
                .map(normalizeEndpointForComparison)
                .filter { !$0.isEmpty }
        )
    }

    private static func normalizeEndpointForComparison(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == noValueSentinel.lowercased() {
            return ""
        }
        return normalized
    }

    private static func endpointConfidence(_ field: BoardingPassEditableField, in draft: BoardingPassDraft) -> Double {
        switch field {
        case .originCode:
            return maxConfidence(in: draft.confidence.perField, keys: [
                "journey.originCode",
                "journey.origin.code",
                "journey.origin.iataCode",
                "journey.origin.name",
                "journey.origin.city"
            ])
        case .destinationCode:
            return maxConfidence(in: draft.confidence.perField, keys: [
                "journey.destinationCode",
                "journey.destination.code",
                "journey.destination.iataCode",
                "journey.destination.name",
                "journey.destination.city"
            ])
        default:
            return 0
        }
    }

    private static func maxConfidence(in fields: [String: Double], keys: [String]) -> Double {
        keys.compactMap { fields[$0] }.max() ?? 0
    }

    private static func clearOrigin(in draft: inout BoardingPassDraft) {
        draft.journey.originCode = ""
        draft.journey.originName = nil
        setEndpointConfidence(.originCode, in: &draft, to: 0)
    }

    private static func clearDestination(in draft: inout BoardingPassDraft) {
        draft.journey.destinationCode = ""
        draft.journey.destinationName = nil
        setEndpointConfidence(.destinationCode, in: &draft, to: 0)
    }

    private static func setEndpointConfidence(_ field: BoardingPassEditableField, in draft: inout BoardingPassDraft, to value: Double) {
        let keys: [String]
        switch field {
        case .originCode:
            keys = [
                "journey.originCode",
                "journey.origin.code",
                "journey.origin.iataCode",
                "journey.origin.name",
                "journey.origin.city"
            ]
        case .destinationCode:
            keys = [
                "journey.destinationCode",
                "journey.destination.code",
                "journey.destination.iataCode",
                "journey.destination.name",
                "journey.destination.city"
            ]
        default:
            keys = []
        }
        for key in keys {
            draft.confidence.perField[key] = value
        }
    }

    #if DEBUG
    static func sanitizeResolvedRouteForTesting(_ draft: inout BoardingPassDraft) -> [String] {
        sanitizeResolvedRoute(&draft)
    }
    #endif

    private static func routeOverride(
        for mode: BoardingPassTransportMode,
        output: PassVisionStructuredOutput,
        evidence: BoardingPassExtractionInput
    ) -> ResolvedPassRoute {
        let evidenceText = evidence.recognizedText.map(\.value).joined(separator: "\n")
        let resolved = mode == .air ? PassRouteResolver.airRoute(in: evidenceText) : PassRouteResolver.namedRoute(in: evidenceText)
        let origin = output.journey?.origin
        let destination = output.journey?.destination

        let originCode = clean(origin?.iataCode)
            ?? clean(origin?.code)
            ?? resolved?.originCode
            ?? clean(origin?.name)
            ?? ""
        let destinationCode = clean(destination?.iataCode)
            ?? clean(destination?.code)
            ?? resolved?.destinationCode
            ?? clean(destination?.name)
            ?? ""
        return ResolvedPassRoute(
            originCode: originCode.uppercasedIfCodeLike(mode: mode),
            originName: clean(origin?.name) ?? clean(origin?.city) ?? resolved?.originName ?? PassRouteResolver.airportName(for: originCode),
            destinationCode: destinationCode.uppercasedIfCodeLike(mode: mode),
            destinationName: clean(destination?.name) ?? clean(destination?.city) ?? resolved?.destinationName ?? PassRouteResolver.airportName(for: destinationCode)
        )
    }

    private static func appendVisionWarnings(_ warnings: [String], to draft: inout BoardingPassDraft) {
        for warning in warnings.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !warning.isEmpty {
            guard !draft.validation.issues.contains(where: { $0.message == warning }) else { continue }
            draft.validation.issues.append(ValidationIssue(field: nil, message: warning, severity: .warning))
        }
        if !warnings.isEmpty, draft.validation.status == .valid {
            draft.validation.status = .needsReview
        }
    }

    private static func appendEvidenceConflicts(_ evidenceDraft: BoardingPassDraft?, to draft: inout BoardingPassDraft) {
        guard let evidenceDraft else { return }
        let checks: [(BoardingPassEditableField, String, String)] = [
            (.originCode, draft.journey.originCode, evidenceDraft.journey.originCode),
            (.destinationCode, draft.journey.destinationCode, evidenceDraft.journey.destinationCode),
            (.serviceNumber, draft.journey.serviceNumber, evidenceDraft.journey.serviceNumber),
            (.departureTime, draft.journey.departureTime, evidenceDraft.journey.departureTime),
            (.seat, draft.journey.seat ?? "", evidenceDraft.journey.seat ?? ""),
            (.gate, draft.journey.gate ?? "", evidenceDraft.journey.gate ?? "")
        ]

        for (field, visionValue, evidenceValue) in checks {
            let lhs = visionValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let rhs = evidenceValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lhs.isEmpty, !rhs.isEmpty, lhs.caseInsensitiveCompare(rhs) != .orderedSame else { continue }
            draft.validation.issues.append(
                ValidationIssue(
                    field: field.rawValue,
                    message: String(localized: "Vision extraction and barcode/OCR evidence disagree. Confirm this field before adding the pass."),
                    severity: .warning
                )
            )
        }
        if draft.validation.issues.contains(where: { $0.severity == .warning }), draft.validation.status == .valid {
            draft.validation.status = .needsReview
        }
    }

    private static func visionObservations(from output: PassVisionStructuredOutput, confidence: [String: Double]?) -> [FieldObservation] {
        var observations: [FieldObservation] = []
        func add(_ key: String, _ value: String?) {
            guard let value = clean(value) else { return }
            observations.append(FieldObservation(key: key, value: value, confidence: confidence?[key] ?? 0.78, source: .vision))
        }
        add("traveler.fullName", output.traveler?.fullName)
        add("issuer.name", output.issuer?.name)
        add("journey.originCode", output.journey?.origin?.iataCode ?? output.journey?.origin?.code)
        add("journey.destinationCode", output.journey?.destination?.iataCode ?? output.journey?.destination?.code)
        add("journey.serviceNumber", output.journey?.serviceNumber)
        add("journey.departureTime", output.journey?.departureTime)
        add("journey.boardingTime", output.journey?.boardingTime)
        add("journey.seat", output.journey?.seat)
        add("journey.gate", output.journey?.gate)
        add("journey.platform", output.journey?.platform)
        return observations
    }

    private static func dominantSolidBackgroundColor(in imagePath: String, shouldDetect: Bool?) -> String? {
        guard shouldDetect == true,
              let image = UIImage(contentsOfFile: imagePath)?.cgImage else {
            return nil
        }

        let width = 96
        let height = 96
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else {
            return nil
        }

        var bins: [Int: Int] = [:]
        var sampleCount = 0
        let border = 18
        for y in 0..<height {
            for x in 0..<width where x < border || x >= width - border || y < border || y >= height - border {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let alpha = Int(pixels[offset + 3])
                guard alpha > 220, isUsefulBackgroundCandidate(red: red, green: green, blue: blue) else { continue }

                let key = (red / 24) << 16 | (green / 24) << 8 | (blue / 24)
                bins[key, default: 0] += 1
                sampleCount += 1
            }
        }

        guard let best = bins.max(by: { $0.value < $1.value }),
              sampleCount > 0,
              Double(best.value) / Double(sampleCount) >= 0.12 else {
            return nil
        }

        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        var matched = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = Int(pixels[offset])
                let green = Int(pixels[offset + 1])
                let blue = Int(pixels[offset + 2])
                let alpha = Int(pixels[offset + 3])
                let key = (red / 24) << 16 | (green / 24) << 8 | (blue / 24)
                guard alpha > 220, key == best.key else { continue }
                redTotal += red
                greenTotal += green
                blueTotal += blue
                matched += 1
            }
        }
        guard matched > 0 else { return nil }
        return String(
            format: "#%02X%02X%02X",
            redTotal / matched,
            greenTotal / matched,
            blueTotal / matched
        )
    }

    private static func isUsefulBackgroundCandidate(red: Int, green: Int, blue: Int) -> Bool {
        let r = Double(red) / 255.0
        let g = Double(green) / 255.0
        let b = Double(blue) / 255.0
        let maxChannel = max(r, g, b)
        let minChannel = min(r, g, b)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
        return luminance > 0.12 && luminance < 0.90 && saturation > 0.12
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "--" || trimmed == "-" || trimmed == noValueSentinel { return nil }
        return trimmed
    }
}

private extension String {
    func uppercasedIfCodeLike(mode: BoardingPassTransportMode) -> String {
        if mode == .air || range(of: #"^[A-Za-z]{3}$"#, options: .regularExpression) != nil {
            return uppercased()
        }
        return self
    }
}
#endif
