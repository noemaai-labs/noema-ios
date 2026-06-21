import XCTest
@testable import Noema

final class ModelDependencyGraphTests: XCTestCase {
    func testBuildsRootEdgesAndDependencyBucketsFromPlan() {
        let plan = ModelDownloadPlan(entries: [
            .init(kind: .weights, relativePath: "model.gguf", sizeBytes: 100, isRequired: true, isResolvedDuringInstall: false),
            .init(kind: .importanceMatrix, relativePath: "imatrix.dat", sizeBytes: 10, isRequired: false, isResolvedDuringInstall: false),
            .init(kind: .projector, relativePath: "mmproj / projector", sizeBytes: nil, isRequired: false, isResolvedDuringInstall: true)
        ])

        let graph = ModelDependencyGraph.make(rootTitle: "Q4_K_M", plan: plan)

        XCTAssertEqual(graph.root.title, "Q4_K_M")
        XCTAssertEqual(graph.dependencies.count, 3)
        XCTAssertEqual(graph.edges.count, 3)
        XCTAssertTrue(graph.edges.allSatisfy { $0.sourceID == graph.root.id })
        XCTAssertEqual(graph.requiredDependencies.map(\.title), ["model.gguf"])
        XCTAssertEqual(graph.optionalDependencies.map(\.title), ["imatrix.dat"])
        XCTAssertEqual(graph.installChecks.map(\.title), ["mmproj / projector"])
    }

    func testInstallTimeRequiredSidecarsStayInInstallCheckBucket() {
        let plan = ModelDownloadPlan(entries: [
            .init(kind: .tokenizer, relativePath: "ET tokenizer files", sizeBytes: nil, isRequired: true, isResolvedDuringInstall: true)
        ])

        let graph = ModelDependencyGraph.make(rootTitle: "ExecuTorch", plan: plan)

        XCTAssertEqual(graph.requiredDependencies.count, 0)
        XCTAssertEqual(graph.optionalDependencies.count, 0)
        XCTAssertEqual(graph.installChecks.count, 1)
        XCTAssertEqual(graph.installChecks.first?.detail, "required install check")
    }
}
