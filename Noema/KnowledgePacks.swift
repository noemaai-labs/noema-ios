import Foundation

struct KnowledgePack: Identifiable, Sendable {
    let id: String
    let displayName: String
    let publisher: String
    let category: DatasetCategory
    let summary: String
    let detailSummary: String
    let license: String
    let attribution: String
    /// Dataset-level persona appended to the system prompt while this pack is the
    /// active retrieval dataset. `nil` → no persona.
    let systemPrompt: String?
    /// Marks a pack that needs a persistent safety disclaimer (e.g. "medical").
    let disclaimerKey: String?
    /// Estimated chunk count once indexed; drives the on-device setup-time estimate.
    let chunkCount: Int
    /// Frozen-snapshot note shown on the detail page (e.g. "Data current as of …").
    let snapshotDate: String?
    /// Clean text content file(s). Each becomes a `<<<FILE:>>>`-attributed source.
    let files: [DatasetFile]

    var record: DatasetRecord {
        DatasetRecord(
            id: id,
            displayName: displayName,
            publisher: publisher,
            summary: summary,
            installed: false,
            category: category,
            license: license,
            chunkCount: chunkCount
        )
    }

    var details: DatasetDetails {
        DatasetDetails(
            id: id,
            summary: detailSummary,
            files: files,
            displayName: displayName,
            category: category,
            license: license,
            attribution: attribution,
            chunkCount: chunkCount,
            snapshotDate: snapshotDate
        )
    }

    var registryEntry: ManualDatasetRegistry.Entry {
        ManualDatasetRegistry.Entry(record: record, details: details)
    }
}

enum KnowledgePackCatalog {
    /// Prefix that identifies an installed dataset as a Knowledge Pack.
    static let idPrefix = "PACK/"

    /// Base URL for published pack artifacts (public HF dataset repo).
    private static let hostingBase = "https://huggingface.co/datasets/NoemaAI-labs/knowledge-packs/resolve/main"

    /// Stable English license token. It is rendered through `LocalizedStringKey`
    /// at the UI layer (so it re-localizes on an in-app language change); storing
    /// the already-localized string here would freeze it at first catalog access.
    static let publicDomainLabel = "Public Domain"

    private static func file(_ pack: String, _ name: String, _ approxBytes: Int64) -> DatasetFile {
        let url = URL(string: "\(hostingBase)/\(pack)/\(name)")!
        return DatasetFile(id: "\(pack)/\(name)", name: name, sizeBytes: approxBytes, downloadURL: url)
    }

    /// The launch catalog. Computed so the localized license label stays current.
    static var all: [KnowledgePack] {
        let pd = publicDomainLabel
        return [
            KnowledgePack(
                id: "PACK/wilderness-survival",
                displayName: "Wilderness & Survival",
                publisher: "U.S. Army (Public Domain)",
                category: .survival,
                summary: "Field-tested survival, shelter, water, fire, signaling and land-navigation guidance for the backcountry.",
                detailSummary: "The canonical U.S. Army survival corpus — FM 21-76 (Survival) and FM 3-25.26 (Map Reading & Land Navigation). Covers shelter, fire, water procurement and purification, food, signaling, first aid, navigation and environmental survival (desert, cold, tropical, coastal). Works fully offline once indexed.",
                license: pd,
                attribution: "U.S. Army field manuals FM 21-76 and FM 3-25.26 (via Internet Archive). Works of the U.S. federal government — public domain (17 U.S.C. §105).",
                systemPrompt: "You are a concise wilderness and survival field reference. Give clear, step-by-step, safety-first guidance grounded strictly in the retrieved field-manual passages. When an action carries real risk (cold water, unstable terrain, untested water, wild plants), state the safer alternative and the risk plainly. If the passages don't cover the question, say so rather than guessing.",
                disclaimerKey: nil,
                chunkCount: 148,
                snapshotDate: nil,
                files: [
                    file("wilderness-survival", "fm21-76-survival.txt", 311_000),
                    file("wilderness-survival", "fm3-25-26-land-nav.txt", 400_000),
                ]
            ),
            KnowledgePack(
                id: "PACK/first-aid",
                displayName: "First Aid & Field Medicine",
                publisher: "U.S. Army / CDC (Public Domain)",
                category: .medical,
                summary: "Step-by-step first aid: bleeding, fractures, burns, shock, and environmental injuries, with water-safety guidance.",
                detailSummary: "First-aid procedures from U.S. Army FM 4-25.11 — wounds, bleeding control, fractures, burns, shock, hypothermia, heat illness and field water treatment. Not a substitute for professional medical care.",
                license: pd,
                attribution: "U.S. Army FM 4-25.11 (First Aid, via Internet Archive). Work of the U.S. federal government — public domain (17 U.S.C. §105).",
                systemPrompt: "You are an offline first-aid reference. Answer only from the retrieved passages, keep procedures step-numbered, and preserve any dosage, ratio or water-treatment figures EXACTLY as written — never paraphrase a number. Never provide a definitive diagnosis.",
                disclaimerKey: "medical",
                chunkCount: 65,
                snapshotDate: nil,
                files: [
                    file("first-aid", "fm4-25-11-first-aid.txt", 305_000),
                ]
            ),
            KnowledgePack(
                id: "PACK/emergency-prep",
                displayName: "Emergency Preparedness",
                publisher: "Ready.gov / FEMA (Public Domain)",
                category: .preparedness,
                summary: "Build a kit, make a plan, and respond to floods, fires, storms, earthquakes and power outages.",
                detailSummary: "FEMA's Ready.gov citizen-preparedness guidance — emergency kits, family plans, evacuation, and per-hazard response for floods, wildfire, hurricanes, tornadoes, earthquakes, extreme heat/cold, winter weather, home fires and power outages.",
                license: pd,
                attribution: "Ready.gov / FEMA publications. Works of the U.S. federal government — public domain (17 U.S.C. §105).",
                systemPrompt: "You are an offline emergency-preparedness assistant. Give practical, prioritized, safety-first guidance grounded in the retrieved Ready.gov passages. For any life-threatening situation, lead with contacting local emergency services where possible.",
                disclaimerKey: nil,
                chunkCount: 25,
                snapshotDate: "Ready.gov content snapshot — June 2026.",
                files: [
                    file("emergency-prep", "ready-gov-preparedness.txt", 97_000),
                ]
            ),
            KnowledgePack(
                id: "PACK/travel-factbook",
                displayName: "Travel — World Factbook",
                publisher: "CIA World Factbook (Public Domain)",
                category: .travel,
                summary: "Offline country reference: geography, government, economy, people and infrastructure for 260 places.",
                detailSummary: "The CIA World Factbook — concise profiles for 260 countries and territories covering geography, people and society, government, economy, energy, communications and transportation. A frozen final snapshot (the Factbook was discontinued in February 2026), so figures will not update.",
                license: pd,
                attribution: "CIA World Factbook (factbook.json). Work of the U.S. federal government — public domain (17 U.S.C. §105); also released CC0. The CIA seal/logo is not included and must not be displayed.",
                systemPrompt: "You are an offline country and travel reference built on the CIA World Factbook. Answer from the retrieved country passages. Remind the user that the data is a fixed early-2026 snapshot and may be out of date for fast-changing figures (population, exchange rates, leadership).",
                disclaimerKey: nil,
                chunkCount: 1470,
                snapshotDate: "Data current as of early 2026; the source was discontinued 4 February 2026.",
                files: [
                    file("travel-factbook", "world-factbook.txt", 7_100_000),
                ]
            ),
        ]
    }

    /// In-app lookup of a pack by its dataset id (used at chat time to resolve the
    /// persona/disclaimer for an installed pack).
    static func pack(forID id: String) -> KnowledgePack? {
        guard id.hasPrefix(idPrefix) else { return nil }
        return all.first { $0.id == id }
    }

    static var registryEntries: [ManualDatasetRegistry.Entry] {
        all.map(\.registryEntry)
    }
}

/// Estimates how long a pack will take to embed on-device, given the user's
/// currently-selected embedding model. There are no pre-shipped vectors, so this
/// is the honest "set up time" shown on the card instead of a false "instant".
enum KnowledgePackEstimator {
    enum Tier {
        case instant        // < 1 min
        case coffeeBreak    // 1–12 min
        case plugIn         // 12–60 min
        case overnight      // 1–8 hr
        case impractical    // > 8 hr
    }

    struct Estimate {
        let tier: Tier
        let minutes: Double
        let embeddingModelName: String
    }

    /// Rough per-chunk embedding cost (seconds) keyed off the active model's
    /// vector dimension as a proxy for model size. Conservative; replace with
    /// measured numbers during on-device QA.
    private static func secondsPerChunk(dimension: Int) -> Double {
        switch dimension {
        case 0..<512:   return 0.03   // small 384-dim models (e5/bge-small)
        case 512..<900: return 0.10   // ~768-dim
        default:        return 0.18   // 1024-dim+ (Qwen3-0.6B and up)
        }
    }

    static func estimate(chunkCount: Int) -> Estimate {
        let record = EmbeddingModelCatalog.activeRecord()
        let spc = secondsPerChunk(dimension: record.dimension)
        let minutes = (Double(max(chunkCount, 1)) * spc) / 60.0
        let tier: Tier
        switch minutes {
        case ..<1:   tier = .instant
        case ..<12:  tier = .coffeeBreak
        case ..<60:  tier = .plugIn
        case ..<480: tier = .overnight
        default:     tier = .impractical
        }
        return Estimate(tier: tier, minutes: minutes, embeddingModelName: record.displayName)
    }

    /// User-facing one-liner, e.g. "≈ 3 min to set up". When no embedding model
    /// is installed yet, the on-device index time is unknown AND gated behind a
    /// model download, so we say that honestly instead of showing a confident
    /// number that silently assumes a model is present.
    static func label(chunkCount: Int) -> String {
        let locale = LocalizationManager.preferredLocale()
        guard EmbeddingModelCatalog.activeRecord().isInstalled else {
            return String(localized: "Setup needs an embedding model download first", locale: locale)
        }
        let est = estimate(chunkCount: chunkCount)
        switch est.tier {
        case .instant:
            return String(localized: "Under a minute to set up", locale: locale)
        case .coffeeBreak, .plugIn:
            let mins = Int(ceil(est.minutes))
            return String(format: String(localized: "≈ %d min to set up", locale: locale), mins)
        case .overnight:
            let hrs = Int(ceil(est.minutes / 60.0))
            return String(format: String(localized: "≈ %d hr to set up — keep charging", locale: locale), hrs)
        case .impractical:
            return String(localized: "Too large to set up on this device", locale: locale)
        }
    }
}
