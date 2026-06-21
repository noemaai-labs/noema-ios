import Foundation

enum BoardingPassTransportMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case air
    case train
    case bus
    case boat
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .air: return String(localized: "Air")
        case .train: return String(localized: "Train")
        case .bus: return String(localized: "Bus")
        case .boat: return String(localized: "Boat")
        case .generic: return String(localized: "Generic")
        }
    }

    var walletTransitType: String {
        switch self {
        case .air: return "PKTransitTypeAir"
        case .train: return "PKTransitTypeTrain"
        case .bus: return "PKTransitTypeBus"
        case .boat: return "PKTransitTypeBoat"
        case .generic: return "PKTransitTypeGeneric"
        }
    }

    var documentType: String {
        switch self {
        case .air: return "boarding_pass"
        case .train: return "train_ticket"
        case .bus: return "bus_ticket"
        case .boat: return "ferry_ticket"
        case .generic: return "ticket"
        }
    }
}

enum BoardingPassBarcodeSymbology: String, Codable, Sendable {
    case pdf417 = "PDF417"
    case aztec = "Aztec"
    case dataMatrix = "DataMatrix"
    case qr = "QR"
    case code128 = "Code128"
    case unknown = "Unknown"

    var walletFormat: String {
        switch self {
        case .pdf417: return "PKBarcodeFormatPDF417"
        case .aztec: return "PKBarcodeFormatAztec"
        case .dataMatrix: return "PKBarcodeFormatQR"
        case .qr: return "PKBarcodeFormatQR"
        case .code128: return "PKBarcodeFormatCode128"
        case .unknown: return "PKBarcodeFormatQR"
        }
    }
}

enum FieldObservationSource: String, Codable, Sendable {
    case barcode
    case ocr
    case vision
    case userEdit
    case inferred
}

struct FieldObservation: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var key: String
    var value: String
    var confidence: Double
    var source: FieldObservationSource
    var boundingBox: NormalizedRect?
    var language: String?

    init(
        id: UUID = UUID(),
        key: String,
        value: String,
        confidence: Double,
        source: FieldObservationSource,
        boundingBox: NormalizedRect? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.key = key
        self.value = value
        self.confidence = max(0, min(1, confidence))
        self.source = source
        self.boundingBox = boundingBox
        self.language = language
    }
}

struct NormalizedRect: Equatable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct BarcodeObservation: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var symbology: BoardingPassBarcodeSymbology
    var rawValue: String
    var confidence: Double
    var boundingBox: NormalizedRect?

    init(
        id: UUID = UUID(),
        symbology: BoardingPassBarcodeSymbology,
        rawValue: String,
        confidence: Double,
        boundingBox: NormalizedRect? = nil
    ) {
        self.id = id
        self.symbology = symbology
        self.rawValue = rawValue
        self.confidence = max(0, min(1, confidence))
        self.boundingBox = boundingBox
    }
}

struct PassIssuer: Equatable, Codable, Sendable {
    var name: String
    var shortCode: String
    var iataCode: String?
    var railOperatorCode: String?
}

struct PassTraveler: Equatable, Codable, Sendable {
    var fullName: String
    var familyName: String?
    var givenName: String?
    var loyaltyNumber: String?
}

struct PassJourney: Equatable, Codable, Sendable {
    var originCode: String
    var originName: String?
    var destinationCode: String
    var destinationName: String?
    var serviceNumber: String
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
    var boardingTime: String?
    var departureTime: String
    var arrivalTime: String?
    var timeZoneOrigin: String?
    var timeZoneDestination: String?
}

struct PassBarcode: Equatable, Codable, Sendable {
    var symbology: BoardingPassBarcodeSymbology?
    var rawValue: String?
    var decodedFormat: String?
    var payloadFields: [String: String]
}

struct PassWalletPresentation: Equatable, Codable, Sendable {
    var style: String
    var transitType: String
    var backgroundColor: String
    var foregroundColor: String
    var labelColor: String

    static func defaultValue(for mode: BoardingPassTransportMode) -> PassWalletPresentation {
        solidBackground("#0F3D5E", for: mode)
    }

    static func solidBackground(_ hex: String, for mode: BoardingPassTransportMode) -> PassWalletPresentation {
        let normalized = normalizedHex(hex) ?? "#0F3D5E"
        let text = readableTextColor(for: normalized)
        return PassWalletPresentation(
            style: "boardingPass",
            transitType: mode.walletTransitType,
            backgroundColor: normalized,
            foregroundColor: text.foreground,
            labelColor: text.label
        )
    }

    private static func normalizedHex(_ hex: String) -> String? {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#").union(.whitespacesAndNewlines))
        guard trimmed.count == 6, Int(trimmed, radix: 16) != nil else { return nil }
        return "#\(trimmed.uppercased())"
    }

    private static func readableTextColor(for hex: String) -> (foreground: String, label: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard trimmed.count == 6, let value = Int(trimmed, radix: 16) else {
            return ("#FFFFFF", "#DDEBFF")
        }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.62 ? ("#111111", "#3F3F46") : ("#FFFFFF", "#E6ECFF")
    }
}

struct PassConfidence: Equatable, Codable, Sendable {
    var overall: Double
    var perField: [String: Double]
}

struct PassProvenance: Equatable, Codable, Sendable {
    var observations: [FieldObservation]
    var userEditedFields: [String]
    var imageHash: String
    var capturedAt: Date
    var extractionMode: String
}

enum PassValidationStatus: String, Codable, Sendable {
    case valid
    case needsReview
    case invalid
}

enum PassValidationSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct ValidationIssue: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var field: String?
    var message: String
    var severity: PassValidationSeverity
    var createdAt: Date

    init(
        id: UUID = UUID(),
        field: String? = nil,
        message: String,
        severity: PassValidationSeverity,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.field = field
        self.message = message
        self.severity = severity
        self.createdAt = createdAt
    }
}

struct PassValidation: Equatable, Codable, Sendable {
    var status: PassValidationStatus
    var issues: [ValidationIssue]
}

struct PassRevision: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var field: String
    var oldValue: String
    var newValue: String
    var createdAt: Date

    init(id: UUID = UUID(), field: String, oldValue: String, newValue: String, createdAt: Date = Date()) {
        self.id = id
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.createdAt = createdAt
    }
}

struct BoardingPassDraft: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var documentType: String
    var transportMode: BoardingPassTransportMode
    var issuer: PassIssuer
    var traveler: PassTraveler
    var journey: PassJourney
    var barcode: PassBarcode
    var walletPresentation: PassWalletPresentation
    var confidence: PassConfidence
    var provenance: PassProvenance
    var validation: PassValidation
    var revisions: [PassRevision]
    var thumbnailJPEGData: Data?
    var rawImagePath: String?

    init(
        id: UUID = UUID(),
        transportMode: BoardingPassTransportMode,
        issuer: PassIssuer,
        traveler: PassTraveler,
        journey: PassJourney,
        barcode: PassBarcode,
        walletPresentation: PassWalletPresentation? = nil,
        confidence: PassConfidence,
        provenance: PassProvenance,
        validation: PassValidation,
        revisions: [PassRevision] = [],
        thumbnailJPEGData: Data? = nil,
        rawImagePath: String? = nil
    ) {
        self.id = id
        self.documentType = transportMode.documentType
        self.transportMode = transportMode
        self.issuer = issuer
        self.traveler = traveler
        self.journey = journey
        self.barcode = barcode
        self.walletPresentation = walletPresentation ?? .defaultValue(for: transportMode)
        self.confidence = confidence
        self.provenance = provenance
        self.validation = validation
        self.revisions = revisions
        self.thumbnailJPEGData = thumbnailJPEGData
        self.rawImagePath = rawImagePath
    }

    var isReadyForWallet: Bool {
        validation.status != .invalid
            && !traveler.fullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !journey.originCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !journey.destinationCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !journey.serviceNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasRequiredTravelTime
    }

    var hasRequiredTravelTime: Bool {
        !journey.departureTime.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(journey.boardingTime ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func applyUserEdit(field: BoardingPassEditableField, value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = stringValue(for: field)
        guard old != trimmed else { return }
        setStringValue(trimmed, for: field)
        revisions.append(PassRevision(field: field.rawValue, oldValue: old, newValue: trimmed))
        if !provenance.userEditedFields.contains(field.rawValue) {
            provenance.userEditedFields.append(field.rawValue)
        }
        provenance.observations.append(
            FieldObservation(key: field.rawValue, value: trimmed, confidence: 1, source: .userEdit)
        )
        validation = BoardingPassValidator.validate(self)
    }

    mutating func applyTransportMode(_ mode: BoardingPassTransportMode) {
        let old = transportMode
        guard old != mode else { return }
        let currentBackground = walletPresentation.backgroundColor
        transportMode = mode
        documentType = mode.documentType
        walletPresentation = .solidBackground(currentBackground, for: mode)
        revisions.append(PassRevision(field: "transportMode", oldValue: old.rawValue, newValue: mode.rawValue))
        if !provenance.userEditedFields.contains("transportMode") {
            provenance.userEditedFields.append("transportMode")
        }
        provenance.observations.append(
            FieldObservation(key: "transportMode", value: mode.rawValue, confidence: 1, source: .userEdit)
        )
        validation = BoardingPassValidator.validate(self)
    }

    func stringValue(for field: BoardingPassEditableField) -> String {
        switch field {
        case .travelerName: return traveler.fullName
        case .issuerName: return issuer.name
        case .serviceNumber: return journey.serviceNumber
        case .originCode: return journey.originCode
        case .destinationCode: return journey.destinationCode
        case .departureTime: return journey.departureTime
        case .boardingTime: return journey.boardingTime ?? ""
        case .seat: return journey.seat ?? ""
        case .gate: return journey.gate ?? ""
        case .terminalOrPlatform: return journey.terminal ?? journey.platform ?? ""
        case .confirmationNumber: return journey.confirmationNumber ?? ""
        }
    }

    mutating func setStringValue(_ value: String, for field: BoardingPassEditableField) {
        switch field {
        case .travelerName: traveler.fullName = value
        case .issuerName: issuer.name = value
        case .serviceNumber: journey.serviceNumber = value
        case .originCode: journey.originCode = value.uppercased()
        case .destinationCode: journey.destinationCode = value.uppercased()
        case .departureTime: journey.departureTime = value
        case .boardingTime: journey.boardingTime = value.isEmpty ? nil : value
        case .seat: journey.seat = value.isEmpty ? nil : value
        case .gate: journey.gate = value.isEmpty ? nil : value
        case .terminalOrPlatform:
            if transportMode == .train || transportMode == .bus || transportMode == .boat {
                journey.platform = value.isEmpty ? nil : value
                journey.terminal = nil
            } else {
                journey.terminal = value.isEmpty ? nil : value
                journey.platform = nil
            }
        case .confirmationNumber: journey.confirmationNumber = value.isEmpty ? nil : value
        }
    }
}

enum BoardingPassEditableField: String, CaseIterable, Identifiable, Sendable {
    case travelerName = "traveler.fullName"
    case issuerName = "issuer.name"
    case serviceNumber = "journey.serviceNumber"
    case originCode = "journey.originCode"
    case destinationCode = "journey.destinationCode"
    case departureTime = "journey.departureTime"
    case boardingTime = "journey.boardingTime"
    case seat = "journey.seat"
    case gate = "journey.gate"
    case terminalOrPlatform = "journey.terminalOrPlatform"
    case confirmationNumber = "journey.confirmationNumber"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .travelerName: return String(localized: "Passenger")
        case .issuerName: return String(localized: "Carrier")
        case .serviceNumber: return String(localized: "Flight / Service")
        case .originCode: return String(localized: "Origin")
        case .destinationCode: return String(localized: "Destination")
        case .departureTime: return String(localized: "Departure")
        case .boardingTime: return String(localized: "Boarding")
        case .seat: return String(localized: "Seat")
        case .gate: return String(localized: "Gate")
        case .terminalOrPlatform: return String(localized: "Terminal / Platform")
        case .confirmationNumber: return String(localized: "Booking Code")
        }
    }

    func matches(validationField: String?) -> Bool {
        guard let validationField else { return false }
        if validationField == rawValue { return true }
        switch self {
        case .terminalOrPlatform:
            return validationField == "journey.terminal" || validationField == "journey.platform"
        default:
            return false
        }
    }
}

enum BoardingPassValidator {
    static func validate(_ draft: BoardingPassDraft) -> PassValidation {
        var issues: [ValidationIssue] = []
        func require(_ value: String, field: String, message: String) {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ValidationIssue(field: field, message: message, severity: .error))
            }
        }

        require(draft.traveler.fullName, field: BoardingPassEditableField.travelerName.rawValue, message: String(localized: "Passenger name is required."))
        require(draft.journey.originCode, field: BoardingPassEditableField.originCode.rawValue, message: String(localized: "Origin is required."))
        require(draft.journey.destinationCode, field: BoardingPassEditableField.destinationCode.rawValue, message: String(localized: "Destination is required."))
        require(draft.journey.serviceNumber, field: BoardingPassEditableField.serviceNumber.rawValue, message: String(localized: "Flight or service number is required."))
        if !draft.hasRequiredTravelTime {
            issues.append(ValidationIssue(field: BoardingPassEditableField.departureTime.rawValue, message: String(localized: "Boarding or departure time is required."), severity: .error))
        }

        if !draft.journey.originCode.isEmpty,
           !draft.journey.destinationCode.isEmpty,
           draft.journey.originCode.caseInsensitiveCompare(draft.journey.destinationCode) == .orderedSame {
            issues.append(ValidationIssue(field: BoardingPassEditableField.destinationCode.rawValue, message: String(localized: "Origin and destination cannot be the same."), severity: .warning))
        }

        if draft.barcode.rawValue == nil {
            issues.append(ValidationIssue(field: "barcode.rawValue", message: String(localized: "No barcode was detected. Review each field before adding this pass."), severity: .warning))
        }

        let status: PassValidationStatus
        if issues.contains(where: { $0.severity == .error }) {
            status = .invalid
        } else if !issues.isEmpty || draft.confidence.overall < 0.72 {
            status = .needsReview
        } else {
            status = .valid
        }
        return PassValidation(status: status, issues: issues)
    }
}
