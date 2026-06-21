import XCTest
@testable import Noema

final class DeterministicToolsTests: XCTestCase {
    func testCalculatorEvaluatesLocalMathExpression() async throws {
        let response = try await callCalculator(expression: "sqrt(144) + 3 * 2")

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.expression, "sqrt(144) + 3 * 2")
        XCTAssertEqual(response.result ?? .nan, 18, accuracy: 0.000_001)
        XCTAssertEqual(response.formattedResult, "18")
        XCTAssertNil(response.error)
    }

    func testCalculatorRejectsUnsupportedIdentifiers() async throws {
        let response = try await callCalculator(expression: "ProcessInfo.processInfo")

        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertNil(response.formattedResult)
        XCTAssertEqual(response.error, "Unknown identifier 'processinfo'.")
    }

    func testUnitConverterHandlesTemperatureConversions() async throws {
        let response = try await callUnitConverter(value: 212, fromUnit: "F", toUnit: "C")

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.value, 212)
        XCTAssertEqual(response.fromUnit, "F")
        XCTAssertEqual(response.toUnit, "C")
        XCTAssertEqual(response.category, "temperature")
        XCTAssertEqual(response.result ?? .nan, 100, accuracy: 0.000_001)
        XCTAssertEqual(response.formattedResult, "100")
        XCTAssertNil(response.error)
    }

    func testUnitConverterRejectsIncompatibleFamilies() async throws {
        let response = try await callUnitConverter(value: 5, fromUnit: "km", toUnit: "lb")

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.fromUnit, "km")
        XCTAssertEqual(response.toUnit, "lb")
        XCTAssertNil(response.category)
        XCTAssertNil(response.result)
        XCTAssertNil(response.formattedResult)
        XCTAssertEqual(response.error, "Cannot convert km to lb; units are in different families.")
    }

    private func callCalculator(expression: String) async throws -> CalculatorTestResponse {
        let args = try JSONSerialization.data(withJSONObject: ["expression": expression])
        let data = try await CalculatorTool().call(args: args)
        return try JSONDecoder().decode(CalculatorTestResponse.self, from: data)
    }

    private func callUnitConverter(value: Double, fromUnit: String, toUnit: String) async throws -> UnitConverterTestResponse {
        let args = try JSONSerialization.data(
            withJSONObject: [
                "value": value,
                "from_unit": fromUnit,
                "to_unit": toUnit
            ]
        )
        let data = try await UnitConverterTool().call(args: args)
        return try JSONDecoder().decode(UnitConverterTestResponse.self, from: data)
    }
}

private struct CalculatorTestResponse: Decodable {
    let ok: Bool
    let expression: String
    let result: Double?
    let formattedResult: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case expression
        case result
        case formattedResult = "formatted_result"
        case error
    }
}

private struct UnitConverterTestResponse: Decodable {
    let ok: Bool
    let value: Double?
    let fromUnit: String
    let toUnit: String
    let category: String?
    let result: Double?
    let formattedResult: String?
    let error: String?

    private enum CodingKeys: String, CodingKey {
        case ok
        case value
        case fromUnit = "from_unit"
        case toUnit = "to_unit"
        case category
        case result
        case formattedResult = "formatted_result"
        case error
    }
}
