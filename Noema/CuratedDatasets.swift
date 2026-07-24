import Foundation

enum CuratedDatasets {
    static let hf: [ManualDatasetRegistry.Entry] = ManualDatasetRegistry.defaultEntries

    // Curated, ready-to-use offline Knowledge Packs (survival, first aid, …).
    static let knowledgePacks: [ManualDatasetRegistry.Entry] = KnowledgePackCatalog.registryEntries

    // Curated selections from the Open Textbook Library
    static var otl: [ManualDatasetRegistry.Entry] {
        let locale = LocalizationManager.preferredLocale()
        return [
            ManualDatasetRegistry.Entry(
                record: DatasetRecord(
                    id: "OTL/a-first-course-in-linear-algebra",
                    displayName: "A First Course in Linear Algebra",
                    publisher: "Robert A. Beezer",
                    summary: String(localized: "Introductory linear algebra textbook.", locale: locale),
                    installed: false),
                details: DatasetDetails(
                    id: "OTL/a-first-course-in-linear-algebra",
                    summary: String(localized: "A First Course in Linear Algebra is an introductory textbook aimed at college-level sophomores and juniors.", locale: locale),
                    files: [DatasetFile(
                        id: "a-first-course-in-linear-algebra.pdf",
                        name: "a-first-course-in-linear-algebra.pdf",
                        sizeBytes: 0,
                        downloadURL: URL(string: "https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=2d126254474e43b7d300ef5e60752d5e19f287c3")!
                    )],
                    displayName: "A First Course in Linear Algebra"
                )
            )
        ]
    }
}
