import Foundation

@MainActor
final class BoardingPassDraftStore: ObservableObject {
    static let shared = BoardingPassDraftStore()

    @Published private(set) var drafts: [BoardingPassDraft] = []

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let baseDirectoryOverride: URL?

    init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.baseDirectoryOverride = baseDirectory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        load()
    }

    func save(_ draft: BoardingPassDraft) {
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) {
            drafts[index] = draft
        } else {
            drafts.insert(draft, at: 0)
        }
        persist()
    }

    func deleteAll() {
        drafts.removeAll()
        try? fileManager.removeItem(at: imagesDirectory)
        persist()
    }

    func delete(_ draft: BoardingPassDraft) {
        drafts.removeAll { $0.id == draft.id }
        if let path = draft.rawImagePath {
            try? fileManager.removeItem(atPath: path)
        }
        persist()
    }

    func protectedImageURL(for draftID: UUID) -> URL {
        imagesDirectory.appendingPathComponent("\(draftID.uuidString).jpg")
    }

    func writeRawImageData(_ data: Data, for draftID: UUID) throws -> URL {
        try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        let url = protectedImageURL(for: draftID)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return url
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? decoder.decode([BoardingPassDraft].self, from: data) else {
            drafts = []
            return
        }
        drafts = decoded.sorted { $0.provenance.capturedAt > $1.provenance.capturedAt }
    }

    private func persist() {
        do {
            try fileManager.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let data = try encoder.encode(drafts)
            try data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Task { await logger.log("[PassScanner] Failed to persist drafts: \(error.localizedDescription)") }
        }
    }

    private var storeURL: URL {
        baseDirectory.appendingPathComponent("BoardingPassDrafts.json")
    }

    private var imagesDirectory: URL {
        baseDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    private var baseDirectory: URL {
        if let baseDirectoryOverride {
            return baseDirectoryOverride
        }
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return documents.appendingPathComponent("BoardingPassDrafts", isDirectory: true)
    }
}

enum PassScannerSettings {
    static let signerBaseURLKey = "walletPassSignerBaseURL"
    static let keepScansWithDraftsKey = "walletPassKeepScansWithDrafts"
    static let remoteFallbackAllowedKey = "walletPassRemoteFallbackAllowed"
    static let warningSensitivityKey = "walletPassWarningSensitivity"
    static let defaultSignerBaseURL = "https://search.noemaai.com"

    static var signerBaseURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: signerBaseURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return stored.isEmpty ? defaultSignerBaseURL : stored
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: signerBaseURLKey) }
    }

    static var keepScansWithDrafts: Bool {
        UserDefaults.standard.object(forKey: keepScansWithDraftsKey) as? Bool ?? false
    }
}
