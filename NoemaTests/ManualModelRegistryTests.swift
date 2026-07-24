import XCTest
@testable import Noema

final class ManualModelRegistryTests: XCTestCase {
    func testCuratedCatalogCoversCurrentDeviceTiersAndRuntimeFormats() async throws {
        let curated = try await ManualModelRegistry().curated()

        XCTAssertGreaterThanOrEqual(curated.count, 30)
        XCTAssertTrue(curated.allSatisfy { ($0.minRAMBytes ?? 0) > 0 })

        let formats = curated.reduce(into: Set<ModelFormat>()) { result, record in
            result.formUnion(record.formats)
        }
        XCTAssertTrue(formats.isSuperset(of: [.gguf, .mlx, .et, .ane, .coreai]))

        let budgets: [Int64] = [
            2_500_000_000,
            7_000_000_000,
            15_000_000_000,
            128_000_000_000
        ]
        let fittingCounts = budgets.map { budget in
            curated.filter {
                CuratedModelDeviceFit.shouldShowByDefault(
                    $0,
                    format: .gguf,
                    budgetBytes: budget
                )
            }.count
        }
        XCTAssertTrue(zip(fittingCounts, fittingCounts.dropFirst()).allSatisfy { pair in
            pair.0 < pair.1
        })
    }

    func testNewestCompactFamiliesCarryEveryPublishedAppleRuntime() async throws {
        let curated = try await ManualModelRegistry().curated()
        let qwen = try XCTUnwrap(curated.first(where: { $0.id == "unsloth/Qwen3.5-0.8B-GGUF" }))
        let gemma = try XCTUnwrap(curated.first(where: { $0.id == "unsloth/gemma-4-E2B-it-GGUF" }))

        XCTAssertEqual(qwen.formats, [.gguf, .mlx, .et, .ane, .coreai])
        XCTAssertEqual(gemma.formats, [.gguf, .mlx, .et, .ane, .coreai])
    }

    func testCuratedIncludesBonsai8BAsFeaturedCard() async throws {
        let registry = ManualModelRegistry()
        let curated = try await registry.curated()

        guard let bonsaiIndex = curated.firstIndex(where: { $0.id == "prism-ml/Bonsai-8B-gguf" }) else {
            XCTFail("Bonsai 8b should be included in the curated registry")
            return
        }

        XCTAssertEqual(curated[bonsaiIndex].displayName, "Bonsai 8b")
        XCTAssertLessThan(bonsaiIndex, 6, "Bonsai 8b should stay in the featured card group")
    }

    func testCuratedIncludesTernaryBonsai27BWithOfficialAppleFormats() throws {
        let entry = try XCTUnwrap(
            ManualModelRegistry.defaultEntries.first(where: {
                $0.record.id == "prism-ml/Ternary-Bonsai-27B-gguf"
            })
        )

        XCTAssertEqual(entry.record.displayName, "Ternary Bonsai 27B")
        XCTAssertEqual(entry.record.formats, [.gguf, .mlx])
        XCTAssertTrue(entry.record.supportsVision)
        XCTAssertEqual(entry.details.quants.map(\.format), [.gguf, .mlx])
        let ggufRAM = try XCTUnwrap(entry.record.minimumRAMBytes(for: .gguf))
        let mlxRAM = try XCTUnwrap(entry.record.minimumRAMBytes(for: .mlx))
        XCTAssertLessThan(ggufRAM, mlxRAM)
    }

    func testCuratedIncludesOneBitBonsai27BWithOfficialAppleFormats() throws {
        let entry = try XCTUnwrap(
            ManualModelRegistry.defaultEntries.first(where: {
                $0.record.id == "prism-ml/Bonsai-27B-gguf"
            })
        )

        XCTAssertEqual(entry.record.displayName, "Bonsai 27B (1-bit)")
        XCTAssertEqual(entry.record.formats, [.gguf, .mlx])
        XCTAssertTrue(entry.record.supportsVision)
        XCTAssertEqual(entry.details.quants.map(\.format), [.gguf, .mlx])
    }

    func testOneBitBonsaiRecommendedStarterUsesQ1ModelNotDSpark() throws {
        let files = [
            RepoFile(path: "Bonsai-27B-F16.gguf", size: 53_808_280_640, sha256: nil),
            RepoFile(path: "Bonsai-27B-Q1_0.gguf", size: 3_803_452_480, sha256: nil),
            RepoFile(path: "Bonsai-27B-dspark-Q4_1.gguf", size: 1_787_468_768, sha256: nil),
            RepoFile(path: "Bonsai-27B-mmproj-Q8_0.gguf", size: 629_246_880, sha256: nil)
        ]
        let quants = QuantExtractor.extract(
            from: files,
            repoID: "prism-ml/Bonsai-27B-gguf"
        ).filter { $0.format == .gguf }
        let details = ModelDetails(
            id: "prism-ml/Bonsai-27B-gguf",
            summary: nil,
            quants: quants,
            promptTemplate: nil
        )

        let starter = try XCTUnwrap(ManualModelRegistry.recommendedStarterQuant(in: details))
        XCTAssertEqual(QuantExtractor.shortLabel(from: starter.label, format: starter.format), "Q1_0")
        XCTAssertTrue(starter.downloadURL.lastPathComponent.contains("-Q1_0.gguf"))
        XCTAssertFalse(quants.contains(where: { $0.downloadURL.lastPathComponent.lowercased().contains("dspark") }))
        XCTAssertFalse(quants.contains(where: { $0.downloadURL.lastPathComponent.lowercased().contains("mmproj") }))
    }

    func testTernaryBonsaiQuantExtractionKeepsPQDistinctAndSkipsDSpark() throws {
        let files = [
            RepoFile(path: "Ternary-Bonsai-27B-F16.gguf", size: 53_808_280_640, sha256: nil),
            RepoFile(path: "Ternary-Bonsai-27B-PQ2_0.gguf", size: 7_165_121_600, sha256: nil),
            RepoFile(path: "Ternary-Bonsai-27B-Q2_0.gguf", size: 7_165_121_600, sha256: nil),
            RepoFile(path: "Ternary-Bonsai-27B-Q2_g64.gguf", size: 7_585_330_240, sha256: nil),
            RepoFile(path: "Ternary-Bonsai-27B-dspark-Q4_1.gguf", size: 1_946_393_568, sha256: nil),
            RepoFile(path: "Ternary-Bonsai-27B-mmproj-Q8_0.gguf", size: 629_246_880, sha256: nil)
        ]

        let quants = QuantExtractor.extract(
            from: files,
            repoID: "prism-ml/Ternary-Bonsai-27B-gguf"
        ).filter { $0.format == .gguf }
        let shortLabels = Set(quants.map {
            QuantExtractor.shortLabel(from: $0.label, format: $0.format)
        })

        XCTAssertTrue(shortLabels.contains("PQ2_0"))
        XCTAssertTrue(shortLabels.contains("Q2_0"))
        XCTAssertTrue(shortLabels.contains("Q2_G64"))
        XCTAssertFalse(quants.contains(where: { $0.downloadURL.lastPathComponent.lowercased().contains("dspark") }))
        XCTAssertFalse(quants.contains(where: { $0.downloadURL.lastPathComponent.lowercased().contains("mmproj") }))

        let details = ModelDetails(
            id: "prism-ml/Ternary-Bonsai-27B-gguf",
            summary: nil,
            quants: quants,
            promptTemplate: nil
        )
        let starter = try XCTUnwrap(ManualModelRegistry.recommendedStarterQuant(in: details))
        XCTAssertEqual(QuantExtractor.shortLabel(from: starter.label, format: starter.format), "Q2_0")
        XCTAssertTrue(starter.downloadURL.lastPathComponent.contains("-Q2_0.gguf"))
    }

    func testPagedPackageExtractionBuildsOneManifestLedMultipartQuant() throws {
        let root = "Qwen3.5-122B-A10B-Q4_K_M.noema-paged"
        let files = [
            RepoFile(path: "README.md", size: 100, sha256: nil),
            RepoFile(path: "\(root)/experts-001.bin", size: 300, sha256: "expert-1"),
            RepoFile(path: "\(root)/resident.gguf", size: 200, sha256: "resident"),
            RepoFile(path: "\(root)/manifest.json", size: 50, sha256: "manifest"),
            RepoFile(path: "\(root)/experts-000.bin", size: 250, sha256: "expert-0")
        ]

        let quants = QuantExtractor.extract(from: files, repoID: "NoemaAI-labs/Noema-Overfit")
        let paged = try XCTUnwrap(quants.first(where: \.isPagedPackage))

        XCTAssertEqual(quants.count, 1)
        XCTAssertTrue(paged.label.hasSuffix("· Paged"))
        XCTAssertEqual(paged.pagedModelDisplayName, "Qwen3.5-122B-A10B")
        XCTAssertEqual(paged.pagedQuantDisplayLabel, "Q4_K_M")
        XCTAssertEqual(paged.sizeBytes, 800)
        XCTAssertEqual(paged.pagedPackageRelativeDirectory, root)
        XCTAssertEqual(paged.primaryDownloadRelativePath, "\(root)/manifest.json")
        XCTAssertEqual(paged.allRelativeDownloadPaths, [
            "\(root)/manifest.json",
            "\(root)/resident.gguf",
            "\(root)/experts-000.bin",
            "\(root)/experts-001.bin"
        ])
    }

    func testPagedCatalogKeepsModelsWithTheSameQuantDistinct() throws {
        let roots = [
            "Qwen3.5-122B-A10B-Q4_K_M.noema-paged",
            "Qwen3.6-35B-A3B-Q4_K_M.noema-paged"
        ]
        let files = roots.flatMap { root in
            [
                RepoFile(path: "\(root)/manifest.json", size: 50, sha256: nil),
                RepoFile(path: "\(root)/resident.gguf", size: 200, sha256: nil)
            ]
        }

        let paged = QuantExtractor.extract(
            from: files,
            repoID: "NoemaAI-labs/Noema-Overfit"
        ).filter(\.isPagedPackage)

        XCTAssertEqual(paged.count, 2)
        XCTAssertEqual(Set(paged.map(\.id)).count, 2)
        XCTAssertEqual(Set(paged.compactMap(\.pagedModelDisplayName)), [
            "Qwen3.5-122B-A10B",
            "Qwen3.6-35B-A3B"
        ])
        XCTAssertEqual(Set(paged.compactMap(\.pagedQuantDisplayLabel)), ["Q4_K_M"])
    }

    func testMLXInferenceDoesNotPromoteGGUFOnlyLMStudioRecords() {
        let formats = HuggingFaceRegistry.inferFormats(
            tags: ["gguf", "text-generation"],
            id: "lmstudio-community/example-model-GGUF"
        )

        XCTAssertTrue(formats.contains(.gguf))
        XCTAssertFalse(formats.contains(.mlx))
    }

    func testMLXModeIncludesOnlyRecordsWithMLXFormat() {
        let ggufRecord = ModelRecord(
            id: "lmstudio-community/example-model-GGUF",
            displayName: "Example",
            publisher: "lmstudio-community",
            summary: nil,
            hasInstallableQuant: true,
            formats: [.gguf],
            installed: false,
            tags: ["gguf"],
            pipeline_tag: "text-generation"
        )
        let mlxRecord = ModelRecord(
            id: "mlx-community/example-model-4bit",
            displayName: "Example",
            publisher: "mlx-community",
            summary: nil,
            hasInstallableQuant: true,
            formats: [.mlx],
            installed: false,
            tags: nil,
            pipeline_tag: "text-generation"
        )

        XCTAssertFalse(ExploreSearchMode.mlx.includes(ggufRecord))
        XCTAssertTrue(ExploreSearchMode.mlx.includes(mlxRecord))
    }
}
