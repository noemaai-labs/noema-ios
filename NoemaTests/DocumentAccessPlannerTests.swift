import Foundation
import XCTest
@testable import Noema
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class DocumentAccessPlannerTests: XCTestCase {
    private func context(
        navigationAvailable: Bool = true,
        localCanNavigate: Bool = true,
        escalationCanNavigate: Bool = true,
        automaticContextAvailable: Bool = true
    ) -> DocumentAccessContext {
        DocumentAccessContext(
            hasActiveDataset: true,
            datasetTitle: "Annual Report",
            pdfNames: ["report.pdf"],
            pdfNavigationAvailable: navigationAvailable,
            localCanNavigate: localCanNavigate,
            escalationCanNavigate: escalationCanNavigate,
            automaticContextAvailable: automaticContextAvailable
        )
    }

    func testNoActiveDatasetNeedsNoDocumentAccess() {
        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "Summarize this",
                context: .none
            ),
            .none
        )
    }

    func testConceptualQuestionUsesAutomaticContext() {
        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "Explain the report's main recommendation",
                context: context()
            ),
            .context
        )
    }

    func testExactQuotedQuestionUsesPDFNavigation() {
        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "Find every mention of “deferred revenue”",
                context: context()
            ),
            .navigate
        )
    }

    func testConceptualQuestionWithExactVerificationUsesBoth() {
        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "Explain the conclusion and quote the exact wording",
                context: context()
            ),
            .contextThenNavigate
        )
    }

    func testDisabledRAGUsesPDFNavigationForConceptualQuestion() {
        let pdfOnly = context(automaticContextAvailable: false)

        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "Summarize the report's main recommendation",
                context: pdfOnly
            ),
            .navigate
        )
        XCTAssertEqual(
            DocumentAccessPlanner.constrained(.context, context: pdfOnly, route: .local),
            .navigate
        )
    }

    func testDisabledRAGWithoutUsablePDFToolDisablesDocumentAccess() {
        let unavailable = context(
            navigationAvailable: true,
            localCanNavigate: false,
            automaticContextAvailable: false
        )

        XCTAssertEqual(
            DocumentAccessPlanner.constrained(.context, context: unavailable, route: .local),
            .none
        )
    }

    func testPDFGuidanceDoesNotOfferRAGWhenDatasetSearchIsWithheld() {
        let guidance = SystemPromptResolver.pdfReadToolGuidance(
            includeThinkRestriction: false,
            datasetSearchAvailable: false
        )

        XCTAssertTrue(guidance.contains("RAG is disabled for this chat"))
        XCTAssertTrue(guidance.contains("use `read` with `ocr`:true"))
        XCTAssertFalse(guidance.contains("prefer noema.rag.search"))
    }

    func testAutomaticPDFGuidanceExplainsFullDocumentResidencyHandoff() {
        let guidance = ChatVM.activePDFGuidance(
            documentNames: ["report.pdf"],
            preview: nil,
            strategy: .context,
            automaticContextAvailable: true
        )

        XCTAssertTrue(guidance.contains("complete document while the current context budget permits"))
        XCTAssertTrue(guidance.contains("do not assume the complete PDF remains resident"))
        XCTAssertTrue(guidance.contains("use `noema.pdf.read`"))
    }

    func testUnavailableNavigationFallsBackToContext() {
        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "What page contains the revenue figure?",
                context: context(navigationAvailable: false)
            ),
            .context
        )
    }

    func testExplicitlyUnrelatedQuestionSkipsDocument() {
        XCTAssertEqual(
            DocumentAccessPlanner.deterministic(
                userMessage: "General knowledge only; do not use the document. What is 2+2?",
                context: context()
            ),
            .none
        )
    }

    func testFinalRouteCannotUnlockUnavailablePDFTool() {
        let capabilities = context(
            navigationAvailable: true,
            localCanNavigate: false,
            escalationCanNavigate: true
        )
        XCTAssertEqual(
            DocumentAccessPlanner.constrained(.navigate, context: capabilities, route: .local),
            .context
        )
        XCTAssertEqual(
            DocumentAccessPlanner.constrained(.navigate, context: capabilities, route: .cloud),
            .navigate
        )
    }

    func testAFMDocumentAndEscalationPromptsStaySeparate() {
        var inputs = AutoRouteInputs(
            userMessage: "What page contains the exact phrase \"net revenue\"?",
            previousUserMessage: nil,
            conversationTurnCount: 1,
            historyTokenEstimate: 100,
            priorLocalRoutes: 0,
            priorCloudRoutes: 0,
            lastRoute: nil,
            localModel: LocalModelCard(
                name: "Local",
                format: .gguf,
                sizeGB: 4,
                quant: "Q4_K_M",
                parameterLabel: "4B",
                contextLength: 8_192,
                isToolCapable: true,
                isMultimodal: false,
                moeSummary: nil,
                recentAvgTokPerSec: 30
            ),
            escalationModel: EscalationModelCard(
                name: "Cloud",
                contextLength: 100_000,
                promptPricePerMillion: nil,
                completionPricePerMillion: nil,
                isVisionCapable: false
            ),
            hasImages: false,
            imageCount: 0,
            documentCount: 1,
            ragArmed: true,
            webSearchArmed: false,
            pythonArmed: false,
            promptTokenEstimate: 500,
            batteryLevel: 0.8,
            isCharging: false,
            lowPowerMode: false,
            thermalState: .nominal
        )
        inputs.documentAccess = context()

        let documentPrompt = AutopilotBrainClient.afmDocumentPlanningPrompt(
            context: inputs.documentAccess,
            userMessage: inputs.userMessage,
            previousUserMessage: nil
        )
        let escalationPrompt = AutopilotBrainClient.afmRoutingPrompt(
            inputs: inputs,
            aggressiveness: .balanced
        )

        XCTAssertTrue(documentPrompt.contains("DOCUMENT ACCESS POLICY"))
        XCTAssertTrue(documentPrompt.contains("CONTEXT_THEN_NAVIGATE"))
        XCTAssertFalse(documentPrompt.contains("ROUTING PROFILE"))
        XCTAssertTrue(escalationPrompt.contains("ROUTING PROFILE"))
        XCTAssertTrue(escalationPrompt.contains("POLICY: BALANCED"))
        XCTAssertFalse(escalationPrompt.contains("DOCUMENT ACCESS POLICY"))
        XCTAssertLessThan(documentPrompt.count, 3_000)
        XCTAssertLessThan(escalationPrompt.count, 4_000)
    }

    func testPDFDiscoveryStaysInsideTheSuppliedDataset() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let active = root.appendingPathComponent("active", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data().write(to: active.appendingPathComponent("inside.pdf"))
        try Data().write(to: other.appendingPathComponent("outside.pdf"))

        XCTAssertEqual(
            PDFDatasetAccess.pdfURLs(in: active).map(\.lastPathComponent),
            ["inside.pdf"]
        )
    }

    func testPDFReadToolSchemaExposesFullNavigationSurface() throws {
        let tool = PDFReadTool()
        let schemaData = Data(tool.schema.utf8)
        let schema = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        let properties = schema?["properties"] as? [String: Any]
        let action = properties?["action"] as? [String: Any]
        let actions = Set(action?["enum"] as? [String] ?? [])

        XCTAssertEqual(tool.name, "noema.pdf.read")
        XCTAssertEqual(actions, Set(["info", "grep", "lines", "read"]))
    }

    @MainActor
    func testPDFReadToolRegistersInSharedAppCatalog() async {
        await ToolRegistrar.shared.initializeTools()

        XCTAssertNotNil(ToolRegistry.shared.tool(named: "noema.pdf.read"))
    }

#if canImport(PDFKit) && canImport(CoreGraphics)
    func testPDFReadToolInspectsTheActiveDatasetOnThisTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdf-tool-parity-\(UUID().uuidString)", isDirectory: true)
        let pdfURL = root.appendingPathComponent("sample.pdf")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        let consumer = try XCTUnwrap(CGDataConsumer(url: pdfURL as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        for _ in 0..<2 {
            context.beginPDFPage(nil)
            context.endPDFPage()
        }
        context.closePDF()

        let defaults = UserDefaults.standard
        let rootKey = "pdfToolActiveDatasetRoot"
        let preferredKey = "pdfToolPreferredDocuments"
        let previousRoot = defaults.object(forKey: rootKey)
        let previousPreferred = defaults.object(forKey: preferredKey)
        defer {
            if let previousRoot { defaults.set(previousRoot, forKey: rootKey) }
            else { defaults.removeObject(forKey: rootKey) }
            if let previousPreferred { defaults.set(previousPreferred, forKey: preferredKey) }
            else { defaults.removeObject(forKey: preferredKey) }
        }
        defaults.set(root.path, forKey: rootKey)
        defaults.set(pdfURL.lastPathComponent, forKey: preferredKey)

        let result = try await PDFReadTool().call(args: Data(#"{"action":"info"}"#.utf8))
        let info = try JSONDecoder().decode(PDFReadTool.InfoResult.self, from: result)

        XCTAssertEqual(info.documents.count, 1)
        XCTAssertEqual(info.documents.first?.name, "sample.pdf")
        XCTAssertEqual(info.documents.first?.pageCount, 2)
    }
#endif

    func testDocumentAccessReceiptPersistsIndependentlyOfRoute() throws {
        var message = ChatVM.Msg(role: "🤖", text: "Answer")
        message.documentAccessDecision = DocumentAccessDecisionRecord(
            datasetName: "report.pdf",
            requestedStrategy: .navigate,
            effectiveStrategy: .context,
            decidedBy: .appleFoundationModel
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatVM.Msg.self, from: data)

        XCTAssertNil(decoded.route)
        XCTAssertEqual(decoded.documentAccessDecision?.datasetName, "report.pdf")
        XCTAssertEqual(decoded.documentAccessDecision?.requestedStrategy, .navigate)
        XCTAssertEqual(decoded.documentAccessDecision?.effectiveStrategy, .context)
        XCTAssertEqual(decoded.documentAccessDecision?.decidedBy, .appleFoundationModel)
        XCTAssertEqual(decoded.documentAccessDecision?.wasCapabilityAdjusted, true)
    }
}
