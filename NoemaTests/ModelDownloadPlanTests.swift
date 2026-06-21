import XCTest
@testable import Noema

final class ModelDownloadPlanTests: XCTestCase {
    func testMultipartGGUFPlanIncludesKnownArtifactsAndInstallChecks() throws {
        let quant = QuantInfo(
            label: "Q4_K_M",
            format: .gguf,
            sizeBytes: 300,
            downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/model-00001-of-00002.gguf")!,
            sha256: nil,
            configURL: URL(string: "https://huggingface.co/owner/model/raw/main/config.json"),
            downloadParts: [
                .init(
                    path: "model-00001-of-00002.gguf",
                    sizeBytes: 100,
                    sha256: "a",
                    downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/model-00001-of-00002.gguf")!
                ),
                .init(
                    path: "model-00002-of-00002.gguf",
                    sizeBytes: 200,
                    sha256: "b",
                    downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/model-00002-of-00002.gguf")!
                )
            ],
            importanceMatrix: .init(
                path: "imatrix.dat",
                sizeBytes: 12,
                sha256: "c",
                downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/imatrix.dat")!
            ),
            mtp: .init(
                path: "draft.gguf",
                sizeBytes: 24,
                sha256: "d",
                downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/draft.gguf")!
            )
        )

        let plan = ModelDownloadPlan.make(for: quant)

        XCTAssertEqual(plan.entries.filter { $0.kind == .weightShard }.count, 2)
        XCTAssertTrue(plan.entries.contains { $0.kind == .config && $0.relativePath == "config.json" })
        XCTAssertTrue(plan.entries.contains { $0.kind == .importanceMatrix && $0.relativePath == "imatrix.dat" })
        XCTAssertTrue(plan.entries.contains { $0.kind == .mtp && $0.relativePath == "draft.gguf" })
        XCTAssertTrue(plan.entries.contains { $0.kind == .projector && $0.isResolvedDuringInstall })
        XCTAssertEqual(plan.knownTotalBytes, 336)
    }

    func testMLXPlanMarksTokenizerAndProcessorSidecarsAsInstallTimeChecks() {
        let quant = QuantInfo(
            label: "MLX 4bit",
            format: .mlx,
            sizeBytes: 512,
            downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/model.safetensors")!,
            sha256: nil,
            configURL: URL(string: "https://huggingface.co/owner/model/raw/main/config.json")
        )

        let plan = ModelDownloadPlan.make(for: quant)

        XCTAssertTrue(plan.entries.contains { $0.kind == .weights && $0.sizeBytes == 512 })
        XCTAssertTrue(plan.entries.contains { $0.kind == .tokenizer && $0.isRequired && $0.isResolvedDuringInstall })
        XCTAssertTrue(plan.entries.contains { $0.kind == .template && $0.isResolvedDuringInstall })
        XCTAssertTrue(plan.entries.contains { $0.kind == .processor && $0.isResolvedDuringInstall })
        XCTAssertGreaterThanOrEqual(plan.installTimeCheckCount, 4)
    }

    func testETPlanTreatsTokenizerConfigAsRequiredSidecar() {
        let quant = QuantInfo(
            label: "ExecuTorch",
            format: .et,
            sizeBytes: 128,
            downloadURL: URL(string: "https://huggingface.co/owner/model/resolve/main/model.pte")!,
            sha256: nil,
            configURL: URL(string: "https://huggingface.co/owner/model/raw/main/tokenizer_config.json")
        )

        let plan = ModelDownloadPlan.make(for: quant)

        XCTAssertTrue(plan.entries.contains { $0.kind == .tokenizer && $0.relativePath == "tokenizer_config.json" && $0.isRequired })
        XCTAssertTrue(plan.entries.contains { $0.kind == .tokenizer && $0.relativePath == "ET tokenizer files" && $0.isRequired })
    }
}
