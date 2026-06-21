import Foundation
import CryptoKit

#if os(iOS)
import UIKit
import Vision
import ImageIO
#endif

enum BoardingPassExtractionError: LocalizedError {
    case imageUnavailable
    case noReadableContent
    case visionModelRequired
    case selectedVisionModelMissing
    case selectedModelCannotReadImages
    case structuredOutputInvalid

    var errorDescription: String? {
        switch self {
        case .imageUnavailable:
            return String(localized: "No readable image was available.")
        case .noReadableContent:
            return String(localized: "No barcode or text could be read from this pass.")
        case .visionModelRequired:
            return String(localized: "Select a pass extraction model in Settings before scanning passes.")
        case .selectedVisionModelMissing:
            return String(localized: "The selected pass extraction model is missing. Choose another vision model in Settings.")
        case .selectedModelCannotReadImages:
            return String(localized: "The selected pass extraction model cannot read images. Choose a local vision model.")
        case .structuredOutputInvalid:
            return String(localized: "The pass extraction model did not return readable structured data.")
        }
    }
}

struct BoardingPassExtractionInput: Sendable {
    var barcodes: [BarcodeObservation]
    var recognizedText: [FieldObservation]
    var imageHash: String
    var capturedAt: Date
    var thumbnailJPEGData: Data?
    var rawImagePath: String?

    init(
        barcodes: [BarcodeObservation],
        recognizedText: [FieldObservation],
        imageHash: String = UUID().uuidString,
        capturedAt: Date = Date(),
        thumbnailJPEGData: Data? = nil,
        rawImagePath: String? = nil
    ) {
        self.barcodes = barcodes
        self.recognizedText = recognizedText
        self.imageHash = imageHash
        self.capturedAt = capturedAt
        self.thumbnailJPEGData = thumbnailJPEGData
        self.rawImagePath = rawImagePath
    }
}

struct BoardingPassExtractionResult: Sendable {
    var draft: BoardingPassDraft
    var rawModelOutput: String
}

enum BoardingPassParser {
    static func parse(_ input: BoardingPassExtractionInput) throws -> BoardingPassDraft {
        guard !input.barcodes.isEmpty || !input.recognizedText.isEmpty else {
            throw BoardingPassExtractionError.noReadableContent
        }

        let barcodePayload = input.barcodes.first?.rawValue ?? ""
        let ocrLines = input.recognizedText.map(\.value)
        let allText = ([barcodePayload] + ocrLines)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        let normalizedText = normalize(allText)
        let mode = detectMode(text: normalizedText, barcode: barcodePayload)
        let barcodeFields = parseBarcodePayload(barcodePayload, mode: mode)
        let ocrFields = parseTextFields(normalizedText, mode: mode)
        let merged = ConfidenceFusion.merge(
            barcodeFields: barcodeFields,
            ocrFields: ocrFields,
            observations: input.recognizedText
        )

        let route = routeOverride(
            mode: mode,
            routeText: allText,
            barcodeFields: barcodeFields,
            merged: merged
        )
        let issuer = PassIssuer(
            name: merged["issuer.name"] ?? inferredIssuerName(from: barcodePayload, text: normalizedText, mode: mode),
            shortCode: merged["issuer.shortCode"] ?? "",
            iataCode: merged["issuer.iataCode"],
            railOperatorCode: merged["issuer.railOperatorCode"]
        )
        let traveler = PassTraveler(
            fullName: merged["traveler.fullName"] ?? "",
            familyName: merged["traveler.familyName"],
            givenName: merged["traveler.givenName"],
            loyaltyNumber: merged["traveler.loyaltyNumber"]
        )
        let journey = PassJourney(
            originCode: route.originCode,
            originName: route.originName,
            destinationCode: route.destinationCode,
            destinationName: route.destinationName,
            serviceNumber: merged["journey.serviceNumber"] ?? "",
            confirmationNumber: merged["journey.confirmationNumber"],
            seat: merged["journey.seat"],
            coachOrCar: merged["journey.coachOrCar"],
            gate: merged["journey.gate"],
            terminal: merged["journey.terminal"],
            platform: merged["journey.platform"],
            boardingGroup: merged["journey.boardingGroup"],
            boardingZone: merged["journey.boardingZone"],
            sequenceNumber: merged["journey.sequenceNumber"],
            fareClass: merged["journey.fareClass"],
            boardingTime: merged["journey.boardingTime"],
            departureTime: merged["journey.departureTime"] ?? "",
            arrivalTime: merged["journey.arrivalTime"],
            timeZoneOrigin: nil,
            timeZoneDestination: nil
        )
        let barcode = PassBarcode(
            symbology: input.barcodes.first?.symbology,
            rawValue: input.barcodes.first?.rawValue,
            decodedFormat: input.barcodes.isEmpty ? nil : "vision",
            payloadFields: barcodeFields.mapValues(\.value)
        )
        let confidence = PassConfidence(
            overall: ConfidenceFusion.overallConfidence(
                fieldScores: merged.mapValues { _ in 0.74 },
                hasBarcode: !input.barcodes.isEmpty,
                issueCount: 0
            ),
            perField: ConfidenceFusion.perFieldConfidence(
                barcodeFields: barcodeFields,
                ocrFields: ocrFields,
                merged: merged
            )
        )
        let provenance = PassProvenance(
            observations: input.recognizedText + barcodeFields.map { FieldObservation(key: $0.key, value: $0.value.value, confidence: $0.value.confidence, source: .barcode) },
            userEditedFields: [],
            imageHash: input.imageHash,
            capturedAt: input.capturedAt,
            extractionMode: "onDevice"
        )
        var draft = BoardingPassDraft(
            transportMode: mode,
            issuer: issuer,
            traveler: traveler,
            journey: journey,
            barcode: barcode,
            confidence: confidence,
            provenance: provenance,
            validation: PassValidation(status: .needsReview, issues: []),
            thumbnailJPEGData: input.thumbnailJPEGData,
            rawImagePath: input.rawImagePath
        )
        draft.validation = BoardingPassValidator.validate(draft)
        let conflictIssues = merged
            .filter { $0.key.hasPrefix("validation.conflict.") }
            .map { key, _ in
                ValidationIssue(
                    field: String(key.dropFirst("validation.conflict.".count)),
                    message: String(localized: "Barcode and printed text disagree. Confirm the correct value before adding this pass."),
                    severity: .warning
                )
            }
        if !conflictIssues.isEmpty {
            draft.validation.issues.append(contentsOf: conflictIssues)
            if draft.validation.status == .valid {
                draft.validation.status = .needsReview
            }
        }
        draft.confidence.overall = ConfidenceFusion.overallConfidence(
            fieldScores: draft.confidence.perField,
            hasBarcode: !input.barcodes.isEmpty,
            issueCount: draft.validation.issues.count
        )
        return draft
    }

    private static func routeOverride(
        mode: BoardingPassTransportMode,
        routeText: String,
        barcodeFields: [String: ParsedField],
        merged: [String: String]
    ) -> ResolvedPassRoute {
        let resolved = mode == .air
            ? PassRouteResolver.airRoute(in: routeText)
            : PassRouteResolver.namedRoute(in: routeText)
        let originCode = barcodeFields["journey.originCode"]?.value
            ?? resolved?.originCode
            ?? merged["journey.originCode"]
            ?? ""
        let destinationCode = barcodeFields["journey.destinationCode"]?.value
            ?? resolved?.destinationCode
            ?? merged["journey.destinationCode"]
            ?? ""
        return ResolvedPassRoute(
            originCode: originCode,
            originName: resolved?.originName ?? PassRouteResolver.airportName(for: originCode),
            destinationCode: destinationCode,
            destinationName: resolved?.destinationName ?? PassRouteResolver.airportName(for: destinationCode)
        )
    }

    static func parseBarcodePayload(_ raw: String, mode: BoardingPassTransportMode? = nil) -> [String: ParsedField] {
        let text = normalize(raw)
        guard !text.isEmpty else { return [:] }
        let resolvedMode = mode ?? detectMode(text: text, barcode: raw)
        var fields: [String: ParsedField] = [:]

        if raw.hasPrefix("M") || text.contains("M1") {
            // IATA BCBP commonly starts with M and carries name, PNR, route, carrier, flight, date, cabin, seat.
            let compact = raw.replacingOccurrences(of: "\n", with: " ")
            fields["traveler.fullName"] = ParsedField(value: parseBCBPName(compact), confidence: 0.95, source: .barcode)
            if let pnr = compact.slice(start: 23, length: 7)?.trimmedNonEmpty {
                fields["journey.confirmationNumber"] = ParsedField(value: pnr, confidence: 0.90, source: .barcode)
            }
            if let from = compact.slice(start: 30, length: 3)?.trimmedNonEmpty {
                fields["journey.originCode"] = ParsedField(value: from.uppercased(), confidence: 0.94, source: .barcode)
            }
            if let to = compact.slice(start: 33, length: 3)?.trimmedNonEmpty {
                fields["journey.destinationCode"] = ParsedField(value: to.uppercased(), confidence: 0.94, source: .barcode)
            }
            if let carrier = compact.slice(start: 36, length: 3)?.trimmedNonEmpty {
                fields["issuer.iataCode"] = ParsedField(value: carrier.trimmingCharacters(in: .whitespaces).uppercased(), confidence: 0.88, source: .barcode)
            }
            if let flight = compact.slice(start: 39, length: 5)?.trimmedNonEmpty {
                fields["journey.serviceNumber"] = ParsedField(value: flight.trimmingCharacters(in: .whitespaces), confidence: 0.92, source: .barcode)
            }
            if let seat = compact.slice(start: 48, length: 4)?.trimmedNonEmpty {
                fields["journey.seat"] = ParsedField(value: seat.trimmingCharacters(in: .whitespaces), confidence: 0.88, source: .barcode)
            }
        }

        for (key, label) in [
            ("traveler.fullName", "PASSENGER"),
            ("journey.serviceNumber", "FLIGHT"),
            ("journey.originCode", "FROM"),
            ("journey.destinationCode", "TO"),
            ("journey.seat", "SEAT"),
            ("journey.gate", "GATE"),
            ("journey.platform", "PLATFORM"),
            ("journey.departureTime", "DEPARTURE"),
            ("journey.boardingTime", "BOARDING")
        ] where fields[key] == nil {
            if let value = valueAfter(label: label, in: text) {
                fields[key] = ParsedField(value: normalizeValue(value, for: key, mode: resolvedMode), confidence: 0.86, source: .barcode)
            }
        }

        return fields
    }

    static func parseTextFields(_ text: String, mode: BoardingPassTransportMode? = nil) -> [String: ParsedField] {
        let resolvedMode = mode ?? detectMode(text: text, barcode: "")
        var fields: [String: ParsedField] = [:]
        let patterns: [(String, String)] = [
            ("traveler.fullName", #"(?i)(?:passenger|name|traveler)\s*[:#]?\s*([A-Z][A-Z ,.'/-]{2,})"#),
            ("issuer.name", #"(?i)(?:carrier|airline|operator|issuer)\s*[:#]?\s*([A-Z][A-Z0-9 &.'/-]{2,})"#),
            ("journey.serviceNumber", #"(?i)(?:flight|service|train|bus|ferry|trip)\s*(?:no\.?|number|#)?\s*[:#]?\s*([A-Z]{0,3}\s?\d{1,5}[A-Z]?)"#),
            ("journey.originCode", #"(?i)(?:from|origin|departure)\s*[:#]?\s*([A-Z0-9]{3,6})"#),
            ("journey.destinationCode", #"(?i)(?:to|destination|arrival)\s*[:#]?\s*([A-Z0-9]{3,6})"#),
            ("journey.seat", #"(?i)(?:seat)\s*[:#]?\s*([A-Z0-9-]{1,5})"#),
            ("journey.gate", #"(?i)(?:gate)\s*[:#]?\s*([A-Z0-9-]{1,6})"#),
            ("journey.terminal", #"(?i)(?:terminal)\s*[:#]?\s*([A-Z0-9-]{1,6})"#),
            ("journey.platform", #"(?i)(?:platform|track|pier)\s*[:#]?\s*([A-Z0-9-]{1,6})"#),
            ("journey.confirmationNumber", #"(?i)(?:booking|confirmation|pnr|record locator)\s*[:#]?\s*([A-Z0-9]{5,8})"#),
            ("journey.boardingTime", #"(?i)(?:boarding|board)\s*(?:time)?\s*[:#]?\s*([0-2]?\d[:.][0-5]\d(?:\s?[AP]M)?)"#),
            ("journey.departureTime", #"(?i)(?:departure|depart|departs)\s*(?:time)?\s*[:#]?\s*([0-2]?\d[:.][0-5]\d(?:\s?[AP]M)?)"#)
        ]

        for (key, pattern) in patterns {
            if let value = firstCapture(pattern: pattern, in: text) {
                fields[key] = ParsedField(value: normalizeValue(value, for: key, mode: resolvedMode), confidence: 0.72, source: .ocr)
            }
        }

        if fields["journey.originCode"] == nil || fields["journey.destinationCode"] == nil {
            let codeMatches = allMatches(pattern: #"(?<![A-Z0-9])([A-Z]{3})(?![A-Z0-9])"#, in: text)
            if codeMatches.count >= 2 {
                fields["journey.originCode"] = fields["journey.originCode"] ?? ParsedField(value: codeMatches[0], confidence: 0.56, source: .ocr)
                fields["journey.destinationCode"] = fields["journey.destinationCode"] ?? ParsedField(value: codeMatches[1], confidence: 0.56, source: .ocr)
            }
        }

        if fields["journey.serviceNumber"] == nil,
           let service = firstCapture(pattern: #"(?<![A-Z0-9])([A-Z]{1,3}\s?\d{2,5})(?![A-Z0-9])"#, in: text) {
            fields["journey.serviceNumber"] = ParsedField(value: service.replacingOccurrences(of: " ", with: ""), confidence: 0.54, source: .ocr)
        }

        return fields
    }

    static func detectMode(text: String, barcode: String) -> BoardingPassTransportMode {
        let corpus = "\(text)\n\(barcode)".uppercased()
        if barcode.hasPrefix("M")
            || corpus.contains("FLIGHT")
            || corpus.contains("BOARDING PASS")
            || corpus.contains("BESZALL")
            || corpus.contains("RYANAIR")
            || corpus.contains("DELTA")
            || corpus.contains("AMERICAN AIRLINES")
            || corpus.contains("MALAYSIA")
            || corpus.contains("GATE") {
            return .air
        }
        if corpus.contains("TRAIN") || corpus.contains("RAIL") || corpus.contains("PLATFORM") || corpus.contains("TRACK") {
            return .train
        }
        if corpus.contains("BUS") || corpus.contains("COACH") {
            return .bus
        }
        if corpus.contains("FERRY") || corpus.contains("FERRIES") || corpus.contains("BOAT") || corpus.contains("PIER") || corpus.contains("CHANNEL") || corpus.contains("HARBOUR") {
            return .boat
        }
        if corpus.contains("OFF-PEAK") || corpus.contains("RAILCARD") || corpus.contains("NATIONAL RAIL") {
            return .train
        }
        return .generic
    }

    static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func inferredIssuerName(from barcode: String, text: String, mode: BoardingPassTransportMode) -> String {
        if let carrier = parseBarcodePayload(barcode, mode: mode)["issuer.iataCode"]?.value {
            return carrier
        }
        return ""
    }

    private static func parseBCBPName(_ raw: String) -> String {
        guard let slice = raw.slice(start: 2, length: 20)?.trimmedNonEmpty else { return "" }
        let normalized = slice
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized
    }

    private static func normalizeValue(_ value: String, for key: String, mode: BoardingPassTransportMode) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "journey.originCode", "journey.destinationCode":
            return trimmed.uppercased()
        case "journey.serviceNumber":
            return trimmed.replacingOccurrences(of: " ", with: "").uppercased()
        case "journey.departureTime", "journey.boardingTime":
            return trimmed.replacingOccurrences(of: ".", with: ":")
        default:
            return trimmed
        }
    }

    private static func valueAfter(label: String, in text: String) -> String? {
        firstCapture(pattern: #"(?i)\#(label)\s*[:#]?\s*([A-Z0-9 /:.-]{1,40})"#, in: text, captureIndex: 1)
    }

    private static func firstCapture(pattern: String, in text: String, captureIndex: Int = 0) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        let index = min(match.numberOfRanges - 1, captureIndex + 1)
        guard index > 0, let captureRange = Range(match.range(at: index), in: text) else { return nil }
        return String(text[captureRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func allMatches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }
}

struct ParsedField: Equatable, Sendable {
    var value: String
    var confidence: Double
    var source: FieldObservationSource
}

enum ConfidenceFusion {
    static func merge(
        barcodeFields: [String: ParsedField],
        ocrFields: [String: ParsedField],
        observations: [FieldObservation]
    ) -> [String: String] {
        var merged: [String: String] = [:]
        for (key, field) in ocrFields {
            merged[key] = field.value
        }
        for (key, field) in barcodeFields {
            if let existing = merged[key],
               existing.caseInsensitiveCompare(field.value) != .orderedSame {
                merged["validation.conflict.\(key)"] = existing
            }
            merged[key] = field.value
        }
        return merged
    }

    static func perFieldConfidence(
        barcodeFields: [String: ParsedField],
        ocrFields: [String: ParsedField],
        merged: [String: String]
    ) -> [String: Double] {
        var scores: [String: Double] = [:]
        for (key, field) in ocrFields {
            scores[key] = field.confidence
        }
        for (key, field) in barcodeFields {
            scores[key] = max(scores[key] ?? 0, field.confidence)
        }
        for key in merged.keys where scores[key] == nil {
            scores[key] = 0.5
        }
        return scores
    }

    static func overallConfidence(fieldScores: [String: Double], hasBarcode: Bool, issueCount: Int) -> Double {
        guard !fieldScores.isEmpty else { return 0 }
        let average = fieldScores.values.reduce(0, +) / Double(fieldScores.count)
        let barcodeBoost = hasBarcode ? 0.12 : 0
        let issuePenalty = min(0.24, Double(issueCount) * 0.04)
        return max(0, min(1, average + barcodeBoost - issuePenalty))
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func slice(start: Int, length: Int) -> String? {
        guard start >= 0, length > 0, count > start else { return nil }
        let from = index(startIndex, offsetBy: start)
        let to = index(from, offsetBy: min(length, distance(from: from, to: endIndex)))
        return String(self[from..<to])
    }
}

#if os(iOS)
final class BoardingPassExtractor {
    func extract(from image: UIImage, models: [LocalModel], rawImagePath: String? = nil) async throws -> BoardingPassDraft {
        try await extractResult(from: image, models: models, rawImagePath: rawImagePath).draft
    }

    func extractResult(from image: UIImage, models: [LocalModel], rawImagePath: String? = nil) async throws -> BoardingPassExtractionResult {
        guard let cgImage = image.normalizedCGImage else {
            throw BoardingPassExtractionError.imageUnavailable
        }
        let hasSelectedModel = !PassExtractionModelCatalog.activeModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !PassExtractionModelCatalog.activeModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasSelectedModel else {
            throw BoardingPassExtractionError.visionModelRequired
        }
        guard let model = PassExtractionModelCatalog.activeModel(from: models) else {
            throw BoardingPassExtractionError.selectedVisionModelMissing
        }
        guard PassExtractionModelCatalog.isCompatibleVisionModel(model) else {
            throw BoardingPassExtractionError.selectedModelCannotReadImages
        }

        async let barcodeObservations = Self.detectBarcodes(in: cgImage)
        async let textObservations = Self.recognizeText(in: cgImage)
        let barcodes = try await barcodeObservations
        let text = try await textObservations
        let thumbnail = image.resizedForPassThumbnail()?.jpegData(compressionQuality: 0.78)
        let input = BoardingPassExtractionInput(
            barcodes: barcodes,
            recognizedText: text,
            imageHash: image.sha256Digest(),
            capturedAt: Date(),
            thumbnailJPEGData: thumbnail,
            rawImagePath: rawImagePath
        )
        let evidenceDraft = try? BoardingPassParser.parse(input)
        let imageURL = try image.writeTemporaryPassExtractionImage()
        defer { try? FileManager.default.removeItem(at: imageURL) }
        let result = try await PassVisionExtractionService().extract(
            imagePath: imageURL.path,
            evidence: input,
            model: model,
            evidenceDraft: evidenceDraft
        )
        return BoardingPassExtractionResult(draft: result.draft, rawModelOutput: result.rawModelOutput)
    }

    #if DEBUG
    static func detectBarcodesForTesting(in image: CGImage) async throws -> [BarcodeObservation] {
        try await detectBarcodes(in: image)
    }
    #endif

    private static func detectBarcodes(in image: CGImage) async throws -> [BarcodeObservation] {
        try await Task.detached(priority: .userInitiated) {
            var observations: [BarcodeObservation] = []
            var seen = Set<String>()
            for candidate in barcodeDetectionCandidates(for: image) {
                for observation in try detectBarcodesOnce(in: candidate) where seen.insert(observation.rawValue).inserted {
                    observations.append(observation)
                }
                if !observations.isEmpty {
                    break
                }
            }
            return observations
        }.value
    }

    private static func detectBarcodesOnce(in image: CGImage) throws -> [BarcodeObservation] {
            let request = VNDetectBarcodesRequest()
            request.symbologies = supportedBarcodeSymbologies(for: request)
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { result in
                guard let value = result.payloadStringValue, !value.isEmpty else { return nil }
                return BarcodeObservation(
                    symbology: BoardingPassExtractor.mapSymbology(result.symbology),
                    rawValue: value,
                    confidence: Double(result.confidence),
                    boundingBox: NormalizedRect(
                        x: result.boundingBox.origin.x,
                        y: result.boundingBox.origin.y,
                        width: result.boundingBox.width,
                        height: result.boundingBox.height
                    )
                )
            }
    }

    private static func supportedBarcodeSymbologies(for request: VNDetectBarcodesRequest) -> [VNBarcodeSymbology] {
        let requested: [VNBarcodeSymbology] = [.pdf417, .aztec, .dataMatrix, .qr, .code128]
        guard let runtimeSupported = try? request.supportedSymbologies() else {
            return requested
        }
        let filtered = requested.filter(runtimeSupported.contains)
        return filtered.isEmpty ? requested : filtered
    }

    private static func barcodeDetectionCandidates(for image: CGImage) -> [CGImage] {
        var candidates: [CGImage] = [image]
        if let scaled = renderBarcodeCandidate(image, scale: 2.4) {
            candidates.append(scaled)
        }

        let width = image.width
        let height = image.height
        let cropRects = [
            CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(max(1, height / 2))),
            CGRect(x: CGFloat(width / 2), y: 0, width: CGFloat(max(1, width / 2)), height: CGFloat(height)),
            CGRect(x: CGFloat(width / 2), y: 0, width: CGFloat(max(1, width / 2)), height: CGFloat(max(1, height / 2))),
            CGRect(x: CGFloat(width) * 0.62, y: 0, width: CGFloat(width) * 0.38, height: CGFloat(height)),
            CGRect(x: CGFloat(width) * 0.72, y: 0, width: CGFloat(width) * 0.28, height: CGFloat(height) * 0.82),
            CGRect(x: 0, y: CGFloat(height) * 0.45, width: CGFloat(width), height: CGFloat(height) * 0.55),
            CGRect(x: CGFloat(width) * 0.55, y: CGFloat(height) * 0.15, width: CGFloat(width) * 0.45, height: CGFloat(height) * 0.65)
        ]
        for rect in cropRects {
            guard let crop = image.cropping(to: rect.integral) else { continue }
            candidates.append(crop)
            if let scaledCrop = renderBarcodeCandidate(crop, scale: 3.0) {
                candidates.append(scaledCrop)
            }
            if let largeCrop = renderBarcodeCandidate(crop, scale: barcodeUpscaleFactor(for: crop)) {
                candidates.append(largeCrop)
            }
        }
        return candidates
    }

    private static func barcodeUpscaleFactor(for image: CGImage) -> CGFloat {
        let longestSide = max(image.width, image.height)
        guard longestSide > 0 else { return 1 }
        return max(1, min(12, 1600 / CGFloat(longestSide)))
    }

    private static func renderBarcodeCandidate(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let width = max(1, min(4096, Int(CGFloat(image.width) * scale)))
        let height = max(1, min(4096, Int(CGFloat(image.height) * scale)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func recognizeText(in image: CGImage) async throws -> [FieldObservation] {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(iOS 16.0, *) {
                request.automaticallyDetectsLanguage = true
            }
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return FieldObservation(
                    key: "rawText",
                    value: candidate.string,
                    confidence: Double(candidate.confidence),
                    source: .ocr,
                    boundingBox: NormalizedRect(
                        x: observation.boundingBox.origin.x,
                        y: observation.boundingBox.origin.y,
                        width: observation.boundingBox.width,
                        height: observation.boundingBox.height
                    ),
                    language: nil
                )
            }
        }.value
    }

    private static func mapSymbology(_ symbology: VNBarcodeSymbology) -> BoardingPassBarcodeSymbology {
        switch symbology {
        case .pdf417: return .pdf417
        case .aztec: return .aztec
        case .dataMatrix: return .dataMatrix
        case .qr: return .qr
        case .code128: return .code128
        default: return .unknown
        }
    }
}

private extension UIImage {
    var normalizedCGImage: CGImage? {
        if imageOrientation == .up, let cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    func resizedForPassThumbnail(maxDimension: CGFloat = 900) -> UIImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(size.width, size.height))
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }

    func sha256Digest() -> String {
        let data = jpegData(compressionQuality: 0.82) ?? pngData() ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func writeTemporaryPassExtractionImage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoemaPassExtraction", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        let data = jpegData(compressionQuality: 0.92) ?? pngData() ?? Data()
        try data.write(to: url, options: [.atomic])
        return url
    }
}
#endif
