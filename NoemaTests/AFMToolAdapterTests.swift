import XCTest
@testable import Noema
#if canImport(FoundationModels)
import FoundationModels
#endif

final class AFMToolAdapterTests: XCTestCase {
    #if canImport(FoundationModels)
    private actor RecordedCalls {
        private var calls: [AFMToolCallSummary] = []

        func append(_ call: AFMToolCallSummary) {
            calls.append(call)
        }

        func snapshot() -> [AFMToolCallSummary] {
            calls
        }
    }

    private struct EchoTool: LoopbackTool {
        let name = "noema.test.echo"
        let description = "Echoes arguments back."
        let schema = #"{ "type":"object", "properties":{ "query":{"type":"string"}, "count":{"type":"integer"} }, "required":["query"] }"#
        func call(args: Data) async throws -> Data {
            let object = try JSONSerialization.jsonObject(with: args) as? [String: Any] ?? [:]
            let out: [String: Any] = ["echo": object, "image_base64": "AAAA"]
            return try JSONSerialization.data(withJSONObject: out)
        }
    }

    /// Every loopback tool the AFM client can wrap must have a schema the
    /// converter can express — a silent conversion failure would drop the tool
    /// from PCC sessions.
    func testRegisteredToolSchemasConvert() throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { throw XCTSkip("needs FoundationModels") }
        let tools: [any LoopbackTool] = [
            WebRetrieveTool(),
            DatasetSearchTool(),
            ChartRenderTool(),
            CalendarEventsTool(),
            CalendarAddEventTool(),
            CalculatorTool(),
            UnitConverterTool(),
            PDFReadTool()
        ]
        for tool in tools {
            XCTAssertNotNil(
                AFMJSONSchemaConverter.generationSchema(name: tool.name, jsonSchema: tool.schema),
                "schema conversion failed for \(tool.name)"
            )
        }
    }

    func testAdapterRecordsFullPayloadAndStripsImagesForModel() async throws {
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { throw XCTSkip("needs FoundationModels") }
        let liveCalls = RecordedCalls()
        let recorder = AFMToolRecorder { call in
            await liveCalls.append(call)
        }
        let adapter = try XCTUnwrap(AFMLoopbackToolAdapter(wrapping: EchoTool(), recorder: recorder))
        let args = try GeneratedContent(json: #"{"query":"hello","count":2}"#)

        let modelFacing = try await adapter.call(arguments: args)

        XCTAssertTrue(modelFacing.contains("hello"))
        XCTAssertTrue(modelFacing.contains("[image rendered and shown to the user]"))
        XCTAssertFalse(modelFacing.contains("AAAA"))

        let published = await liveCalls.snapshot()
        XCTAssertEqual(published.count, 2, "tool execution must publish both live and terminal phases")
        XCTAssertEqual(published.first?.phase, .executing)
        XCTAssertEqual(published.last?.phase, .completed)
        XCTAssertEqual(published.first?.id, published.last?.id)
        XCTAssertEqual(published.first?.toolName, "noema.test.echo")

        let drained = await recorder.drain()
        let summary = try XCTUnwrap(drained)
        XCTAssertEqual(summary.calls.count, 1, "drain must retain only the terminal record")
        let call = try XCTUnwrap(summary.calls.first)
        XCTAssertEqual(call.toolName, "noema.test.echo")
        XCTAssertEqual(call.phase, .completed)
        XCTAssertEqual(call.requestParams["query"]?.value as? String, "hello")
        XCTAssertTrue(call.result?.contains("AAAA") == true, "UI-facing record must keep the full payload")
    }
    #endif
}
