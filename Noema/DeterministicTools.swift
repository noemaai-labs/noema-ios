import Darwin
import Foundation

private struct CalculatorArguments: Decodable {
    let expression: String
}

private struct CalculatorResponse: Codable, Sendable {
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

public struct CalculatorTool: Tool {
    public let name = "noema.math.calculate"
    public let description = "Evaluate a deterministic local math expression without running arbitrary code. Supports +, -, *, /, ^, parentheses, constants pi/e, and common functions such as sqrt, abs, sin, cos, tan, log, ln, exp, floor, ceil, round."
    public let schema = #"""
    { "type":"object", "properties":{
        "expression":{"type":"string","description":"Math expression to evaluate locally. Trigonometric functions use radians."}
    }, "required":["expression"] }
    """#

    public func call(args: Data) async throws -> Data {
        let input = try JSONDecoder().decode(CalculatorArguments.self, from: args)
        let expression = input.expression.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            var parser = MathExpressionParser(expression)
            let value = try parser.parse()
            guard value.isFinite else {
                throw MathExpressionError.invalidResult
            }
            let response = CalculatorResponse(
                ok: true,
                expression: expression,
                result: value,
                formattedResult: Self.format(value),
                error: nil
            )
            return try Self.encoder.encode(response)
        } catch {
            let response = CalculatorResponse(
                ok: false,
                expression: expression,
                result: nil,
                formattedResult: nil,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            return try Self.encoder.encode(response)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private enum MathExpressionError: LocalizedError {
    case emptyExpression
    case unexpectedCharacter(Character)
    case expectedCharacter(Character)
    case expectedNumber
    case expectedFunctionArgument(String)
    case unknownIdentifier(String)
    case unsupportedFunction(String)
    case divideByZero
    case invalidResult
    case trailingInput(String)

    var errorDescription: String? {
        switch self {
        case .emptyExpression:
            return "Expression is empty."
        case .unexpectedCharacter(let character):
            return "Unexpected character '\(character)'."
        case .expectedCharacter(let character):
            return "Expected '\(character)'."
        case .expectedNumber:
            return "Expected a number."
        case .expectedFunctionArgument(let function):
            return "Expected an argument for \(function)."
        case .unknownIdentifier(let identifier):
            return "Unknown identifier '\(identifier)'."
        case .unsupportedFunction(let function):
            return "Unsupported function '\(function)'."
        case .divideByZero:
            return "Division by zero."
        case .invalidResult:
            return "Expression produced a non-finite result."
        case .trailingInput(let input):
            return "Unexpected trailing input '\(input)'."
        }
    }
}

private struct MathExpressionParser {
    private let characters: [Character]
    private var index = 0

    init(_ expression: String) {
        self.characters = Array(expression)
    }

    mutating func parse() throws -> Double {
        skipWhitespace()
        guard !isAtEnd else { throw MathExpressionError.emptyExpression }
        let value = try parseExpression()
        skipWhitespace()
        if !isAtEnd {
            throw MathExpressionError.trailingInput(String(characters[index...]))
        }
        return value
    }

    private mutating func parseExpression() throws -> Double {
        var value = try parseTerm()

        while true {
            skipWhitespace()
            if consume("+") {
                value += try parseTerm()
            } else if consume("-") {
                value -= try parseTerm()
            } else {
                return value
            }
        }
    }

    private mutating func parseTerm() throws -> Double {
        var value = try parsePower()

        while true {
            skipWhitespace()
            if consume("*") {
                value *= try parsePower()
            } else if consume("/") {
                let divisor = try parsePower()
                guard divisor != 0 else { throw MathExpressionError.divideByZero }
                value /= divisor
            } else {
                return value
            }
        }
    }

    private mutating func parsePower() throws -> Double {
        var value = try parseUnary()
        skipWhitespace()
        if consume("^") {
            value = pow(value, try parsePower())
        }
        return value
    }

    private mutating func parseUnary() throws -> Double {
        skipWhitespace()
        if consume("+") {
            return try parseUnary()
        }
        if consume("-") {
            return -(try parseUnary())
        }
        return try parsePrimary()
    }

    private mutating func parsePrimary() throws -> Double {
        skipWhitespace()
        if consume("(") {
            let value = try parseExpression()
            skipWhitespace()
            guard consume(")") else { throw MathExpressionError.expectedCharacter(")") }
            return value
        }

        if currentIsLetter {
            let identifier = parseIdentifier().lowercased()
            skipWhitespace()
            if consume("(") {
                skipWhitespace()
                guard !consume(")") else { throw MathExpressionError.expectedFunctionArgument(identifier) }
                let argument = try parseExpression()
                skipWhitespace()
                guard consume(")") else { throw MathExpressionError.expectedCharacter(")") }
                return try applyFunction(identifier, argument)
            }
            switch identifier {
            case "pi":
                return Double.pi
            case "e":
                return Darwin.M_E
            default:
                throw MathExpressionError.unknownIdentifier(identifier)
            }
        }

        return try parseNumber()
    }

    private mutating func parseNumber() throws -> Double {
        skipWhitespace()
        let start = index
        var hasDigit = false

        while !isAtEnd, characters[index].isNumber {
            hasDigit = true
            index += 1
        }

        if !isAtEnd, characters[index] == "." {
            index += 1
            while !isAtEnd, characters[index].isNumber {
                hasDigit = true
                index += 1
            }
        }

        if !isAtEnd, characters[index].lowercased() == "e" {
            let exponentStart = index
            index += 1
            if !isAtEnd, characters[index] == "+" || characters[index] == "-" {
                index += 1
            }
            var hasExponentDigit = false
            while !isAtEnd, characters[index].isNumber {
                hasExponentDigit = true
                index += 1
            }
            if !hasExponentDigit {
                index = exponentStart
            }
        }

        guard hasDigit else {
            if !isAtEnd { throw MathExpressionError.unexpectedCharacter(characters[index]) }
            throw MathExpressionError.expectedNumber
        }

        let token = String(characters[start..<index])
        guard let value = Double(token) else {
            throw MathExpressionError.expectedNumber
        }
        return value
    }

    private mutating func parseIdentifier() -> String {
        let start = index
        while !isAtEnd, characters[index].isLetter || characters[index] == "_" {
            index += 1
        }
        return String(characters[start..<index])
    }

    private func applyFunction(_ function: String, _ value: Double) throws -> Double {
        switch function {
        case "sqrt":
            return sqrt(value)
        case "abs":
            return Swift.abs(value)
        case "sin":
            return sin(value)
        case "cos":
            return cos(value)
        case "tan":
            return tan(value)
        case "log":
            return log10(value)
        case "ln":
            return log(value)
        case "exp":
            return exp(value)
        case "floor":
            return floor(value)
        case "ceil":
            return ceil(value)
        case "round":
            return round(value)
        default:
            throw MathExpressionError.unsupportedFunction(function)
        }
    }

    private var isAtEnd: Bool {
        index >= characters.count
    }

    private var currentIsLetter: Bool {
        !isAtEnd && characters[index].isLetter
    }

    private mutating func consume(_ character: Character) -> Bool {
        guard !isAtEnd, characters[index] == character else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while !isAtEnd, characters[index].isWhitespace {
            index += 1
        }
    }
}

private struct UnitConverterArguments: Decodable {
    let value: Double
    let fromUnit: String
    let toUnit: String

    private enum CodingKeys: String, CodingKey {
        case value
        case fromUnit = "from_unit"
        case toUnit = "to_unit"
    }
}

private struct UnitConverterResponse: Codable, Sendable {
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

public struct UnitConverterTool: Tool {
    public let name = "noema.units.convert"
    public let description = "Convert common units locally and deterministically. Supports length, mass, temperature, volume, time, data size, and speed units."
    public let schema = #"""
    { "type":"object", "properties":{
        "value":{"type":"number","description":"Numeric value to convert"},
        "from_unit":{"type":"string","description":"Source unit, such as m, km, ft, lb, c, f, l, gal, min, gb, or mph"},
        "to_unit":{"type":"string","description":"Target unit in the same unit family"}
    }, "required":["value","from_unit","to_unit"] }
    """#

    public func call(args: Data) async throws -> Data {
        let input = try JSONDecoder().decode(UnitConverterArguments.self, from: args)

        do {
            let conversion = try UnitConversionTable.convert(
                value: input.value,
                from: input.fromUnit,
                to: input.toUnit
            )
            let response = UnitConverterResponse(
                ok: true,
                value: input.value,
                fromUnit: conversion.fromCanonical,
                toUnit: conversion.toCanonical,
                category: conversion.category,
                result: conversion.result,
                formattedResult: Self.format(conversion.result),
                error: nil
            )
            return try Self.encoder.encode(response)
        } catch {
            let response = UnitConverterResponse(
                ok: false,
                value: input.value,
                fromUnit: input.fromUnit,
                toUnit: input.toUnit,
                category: nil,
                result: nil,
                formattedResult: nil,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            return try Self.encoder.encode(response)
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 12
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private enum UnitConversionError: LocalizedError {
    case unknownUnit(String)
    case incompatibleUnits(String, String)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .unknownUnit(let unit):
            return "Unknown unit '\(unit)'."
        case .incompatibleUnits(let from, let to):
            return "Cannot convert \(from) to \(to); units are in different families."
        case .invalidValue:
            return "Conversion produced a non-finite result."
        }
    }
}

private struct UnitConversionResult {
    let result: Double
    let category: String
    let fromCanonical: String
    let toCanonical: String
}

private enum UnitConversionTable {
    private struct LinearUnit {
        let canonical: String
        let category: String
        let factorToBase: Double
    }

    private static let linearUnits: [String: LinearUnit] = {
        var units: [String: LinearUnit] = [:]

        func add(_ aliases: [String], canonical: String, category: String, factor: Double) {
            let unit = LinearUnit(canonical: canonical, category: category, factorToBase: factor)
            for alias in aliases {
                units[normalize(alias)] = unit
            }
        }

        add(["m", "meter", "meters", "metre", "metres"], canonical: "m", category: "length", factor: 1)
        add(["km", "kilometer", "kilometers", "kilometre", "kilometres"], canonical: "km", category: "length", factor: 1_000)
        add(["cm", "centimeter", "centimeters", "centimetre", "centimetres"], canonical: "cm", category: "length", factor: 0.01)
        add(["mm", "millimeter", "millimeters", "millimetre", "millimetres"], canonical: "mm", category: "length", factor: 0.001)
        add(["in", "inch", "inches"], canonical: "in", category: "length", factor: 0.0254)
        add(["ft", "foot", "feet"], canonical: "ft", category: "length", factor: 0.3048)
        add(["yd", "yard", "yards"], canonical: "yd", category: "length", factor: 0.9144)
        add(["mi", "mile", "miles"], canonical: "mi", category: "length", factor: 1_609.344)

        add(["g", "gram", "grams"], canonical: "g", category: "mass", factor: 1)
        add(["kg", "kilogram", "kilograms"], canonical: "kg", category: "mass", factor: 1_000)
        add(["mg", "milligram", "milligrams"], canonical: "mg", category: "mass", factor: 0.001)
        add(["lb", "lbs", "pound", "pounds"], canonical: "lb", category: "mass", factor: 453.59237)
        add(["oz", "ounce", "ounces"], canonical: "oz", category: "mass", factor: 28.349523125)

        add(["l", "liter", "liters", "litre", "litres"], canonical: "l", category: "volume", factor: 1)
        add(["ml", "milliliter", "milliliters", "millilitre", "millilitres"], canonical: "ml", category: "volume", factor: 0.001)
        add(["gal", "gallon", "gallons"], canonical: "gal", category: "volume", factor: 3.785411784)
        add(["qt", "quart", "quarts"], canonical: "qt", category: "volume", factor: 0.946352946)
        add(["pt", "pint", "pints"], canonical: "pt", category: "volume", factor: 0.473176473)
        add(["cup", "cups"], canonical: "cup", category: "volume", factor: 0.2365882365)
        add(["floz", "fl_oz", "fluidounce", "fluidounces"], canonical: "fl_oz", category: "volume", factor: 0.0295735295625)

        add(["s", "sec", "second", "seconds"], canonical: "s", category: "time", factor: 1)
        add(["min", "minute", "minutes"], canonical: "min", category: "time", factor: 60)
        add(["h", "hr", "hour", "hours"], canonical: "h", category: "time", factor: 3_600)
        add(["day", "days", "d"], canonical: "day", category: "time", factor: 86_400)

        add(["b", "byte", "bytes"], canonical: "B", category: "data", factor: 1)
        add(["kb", "kilobyte", "kilobytes"], canonical: "KB", category: "data", factor: 1_000)
        add(["mb", "megabyte", "megabytes"], canonical: "MB", category: "data", factor: 1_000_000)
        add(["gb", "gigabyte", "gigabytes"], canonical: "GB", category: "data", factor: 1_000_000_000)
        add(["tb", "terabyte", "terabytes"], canonical: "TB", category: "data", factor: 1_000_000_000_000)
        add(["kib", "kibibyte", "kibibytes"], canonical: "KiB", category: "data", factor: 1_024)
        add(["mib", "mebibyte", "mebibytes"], canonical: "MiB", category: "data", factor: 1_048_576)
        add(["gib", "gibibyte", "gibibytes"], canonical: "GiB", category: "data", factor: 1_073_741_824)
        add(["tib", "tebibyte", "tebibytes"], canonical: "TiB", category: "data", factor: 1_099_511_627_776)

        add(["m/s", "mps", "meterpersecond", "meterspersecond"], canonical: "m/s", category: "speed", factor: 1)
        add(["km/h", "kph", "kmh", "kilometerperhour", "kilometersperhour"], canonical: "km/h", category: "speed", factor: 1 / 3.6)
        add(["mph", "mileperhour", "milesperhour"], canonical: "mph", category: "speed", factor: 0.44704)
        add(["ft/s", "fps", "footpersecond", "feetpersecond"], canonical: "ft/s", category: "speed", factor: 0.3048)

        return units
    }()

    private static let temperatureAliases: [String: String] = [
        "c": "C", "celsius": "C", "degc": "C", "degreecelsius": "C",
        "f": "F", "fahrenheit": "F", "degf": "F", "degreefahrenheit": "F",
        "k": "K", "kelvin": "K"
    ]

    static func convert(value: Double, from rawFromUnit: String, to rawToUnit: String) throws -> UnitConversionResult {
        let fromKey = normalize(rawFromUnit)
        let toKey = normalize(rawToUnit)

        if let fromTemperature = temperatureAliases[fromKey] {
            guard let toTemperature = temperatureAliases[toKey] else {
                throw UnitConversionError.incompatibleUnits(rawFromUnit, rawToUnit)
            }
            let celsius = toCelsius(value, from: fromTemperature)
            let result = fromCelsius(celsius, to: toTemperature)
            guard result.isFinite else { throw UnitConversionError.invalidValue }
            return UnitConversionResult(
                result: result,
                category: "temperature",
                fromCanonical: fromTemperature,
                toCanonical: toTemperature
            )
        }

        guard let fromUnit = linearUnits[fromKey] else {
            throw UnitConversionError.unknownUnit(rawFromUnit)
        }
        guard let toUnit = linearUnits[toKey] else {
            throw UnitConversionError.unknownUnit(rawToUnit)
        }
        guard fromUnit.category == toUnit.category else {
            throw UnitConversionError.incompatibleUnits(rawFromUnit, rawToUnit)
        }

        let baseValue = value * fromUnit.factorToBase
        let result = baseValue / toUnit.factorToBase
        guard result.isFinite else { throw UnitConversionError.invalidValue }
        return UnitConversionResult(
            result: result,
            category: fromUnit.category,
            fromCanonical: fromUnit.canonical,
            toCanonical: toUnit.canonical
        )
    }

    private static func normalize(_ unit: String) -> String {
        unit
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }

    private static func toCelsius(_ value: Double, from unit: String) -> Double {
        switch unit {
        case "F":
            return (value - 32) * 5 / 9
        case "K":
            return value - 273.15
        default:
            return value
        }
    }

    private static func fromCelsius(_ value: Double, to unit: String) -> Double {
        switch unit {
        case "F":
            return value * 9 / 5 + 32
        case "K":
            return value + 273.15
        default:
            return value
        }
    }
}
