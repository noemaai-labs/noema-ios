import Foundation

struct ResolvedPassRoute: Equatable, Sendable {
    var originCode: String
    var originName: String?
    var destinationCode: String
    var destinationName: String?
}

enum PassRouteResolver {
    private struct Place: Equatable {
        let code: String
        let name: String
        let aliases: [String]
    }

    private static let airports: [Place] = [
        Place(code: "PHX", name: "Phoenix", aliases: ["PHOENIX"]),
        Place(code: "LAX", name: "Los Angeles", aliases: ["LOS ANGELES", "LOS ANGELES CA"]),
        Place(code: "JFK", name: "New York JFK", aliases: ["JFK", "NEW YORK", "NEW YORK JFK"]),
        Place(code: "ATL", name: "Atlanta", aliases: ["ATLANTA"]),
        Place(code: "MEM", name: "Memphis", aliases: ["MEMPHIS"]),
        Place(code: "BUD", name: "Budapest", aliases: ["BUD", "BUDAPEST", "BUDAPEST T2B"]),
        Place(code: "BGY", name: "Milan Bergamo", aliases: ["MILAN BERGAMO", "MILAN (BERGAMO)", "BERGAMO"]),
        Place(code: "REP", name: "Siem Reap", aliases: ["REP", "SIEM REAP"]),
        Place(code: "KUL", name: "Kuala Lumpur", aliases: ["KUL", "KUALA LUMPUR"]),
        Place(code: "ORD", name: "Chicago O'Hare", aliases: ["ORD", "CHICAGO", "CHICAGO ORD"]),
        Place(code: "CDG", name: "Paris Charles de Gaulle", aliases: ["CDG", "PARIS"]),
        Place(code: "MIA", name: "Miami", aliases: ["MIA", "MIAMI"]),
        Place(code: "ORL", name: "Orlando", aliases: ["ORL", "ORLANDO"])
    ]

    static func airRoute(in text: String) -> ResolvedPassRoute? {
        let normalized = normalize(text)
        if let arrowRoute = routeFromArrowOrToLine(in: normalized) {
            return arrowRoute
        }

        let matches = orderedAirportMatches(in: normalized)
        guard matches.count >= 2 else { return nil }
        return ResolvedPassRoute(
            originCode: matches[0].code,
            originName: matches[0].name,
            destinationCode: matches[1].code,
            destinationName: matches[1].name
        )
    }

    static func namedRoute(in text: String) -> ResolvedPassRoute? {
        let lines = normalizeSpacing(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for index in lines.indices {
            let current = lines[index].uppercased()
            if current == "FROM", lines.indices.contains(index + 1),
               let destinationIndex = lines[(index + 1)...].firstIndex(where: { $0.uppercased() == "TO" }),
               lines.indices.contains(destinationIndex + 1) {
                return makeNamedRoute(origin: lines[index + 1], destination: lines[destinationIndex + 1])
            }

            if current == "TO", lines.indices.contains(index - 1), lines.indices.contains(index + 1) {
                return makeNamedRoute(origin: lines[index - 1], destination: lines[index + 1])
            }

            if current.hasPrefix("FROM "), lines.indices.contains(index + 1),
               lines[index + 1].uppercased().hasPrefix("TO ") {
                return makeNamedRoute(
                    origin: String(lines[index].dropFirst(5)),
                    destination: String(lines[index + 1].dropFirst(3))
                )
            }
        }

        return nil
    }

    static func airportName(for code: String) -> String? {
        let upper = code.uppercased()
        return airports.first { $0.code == upper }?.name
    }

    private static func routeFromArrowOrToLine(in text: String) -> ResolvedPassRoute? {
        if let lineRoute = routeFromDelimitedLine(in: text) {
            return lineRoute
        }

        let patterns = [
            #"(?i)\b([A-Z]{3})\s*(?:->|→|-|TO)\s*([A-Z]{3})\b"#,
            #"(?i)\b([A-Z][A-Z ]{2,30})\s*(?:->|→|-| TO )\s*([A-Z][A-Z ]{2,30})\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 3,
                  let originRange = Range(match.range(at: 1), in: text),
                  let destinationRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            let originRaw = String(text[originRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let destinationRaw = String(text[destinationRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if let origin = airportMatch(for: originRaw), let destination = airportMatch(for: destinationRaw), origin.code != destination.code {
                return ResolvedPassRoute(originCode: origin.code, originName: origin.name, destinationCode: destination.code, destinationName: destination.name)
            }
        }

        return nil
    }

    private static func routeFromDelimitedLine(in text: String) -> ResolvedPassRoute? {
        let lines = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            let separators = ["->", "→", " - ", " TO "]
            for separator in separators {
                if separator == " TO " {
                    guard let range = line.range(of: separator, options: [.caseInsensitive]) else { continue }
                    let originRaw = String(line[..<range.lowerBound])
                    let destinationRaw = String(line[range.upperBound...])
                    if let route = routeFromRawPlaces(origin: originRaw, destination: destinationRaw) {
                        return route
                    }
                    continue
                }
                let parts = line.components(separatedBy: separator)
                guard parts.count == 2,
                      let route = routeFromRawPlaces(origin: parts[0], destination: parts[1]) else {
                    continue
                }
                return route
            }
        }

        return nil
    }

    private static func routeFromRawPlaces(origin originRaw: String, destination destinationRaw: String) -> ResolvedPassRoute? {
        guard let origin = airportMatch(for: originRaw),
              let destination = airportMatch(for: destinationRaw),
              origin.code != destination.code else {
            return nil
        }
        return ResolvedPassRoute(
            originCode: origin.code,
            originName: origin.name,
            destinationCode: destination.code,
            destinationName: destination.name
        )
    }

    private static func orderedAirportMatches(in text: String) -> [Place] {
        var indexed: [(offset: Int, place: Place)] = []
        for place in airports {
            guard let offset = firstOffset(ofAny: place.aliases, in: text) else { continue }
            indexed.append((offset, place))
        }
        return indexed
            .sorted { $0.offset < $1.offset }
            .reduce(into: [Place]()) { result, candidate in
                if !result.contains(where: { $0.code == candidate.place.code }) {
                    result.append(candidate.place)
                }
            }
    }

    private static func airportMatch(for raw: String) -> Place? {
        let normalized = raw
            .uppercased()
            .replacingOccurrences(of: #"[^A-Z0-9 ()']+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return airports.first { place in
            place.code == normalized
                || place.aliases.contains(normalized)
                || place.aliases.contains(where: { normalized.hasPrefix($0) || normalized.contains($0) })
        }
    }

    private static func firstOffset(ofAny aliases: [String], in text: String) -> Int? {
        aliases.compactMap { alias -> Int? in
            guard let range = text.range(of: alias, options: [.caseInsensitive]) else { return nil }
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }
        .min()
    }

    private static func makeNamedRoute(origin: String, destination: String) -> ResolvedPassRoute? {
        let cleanOrigin = cleanPlaceName(origin)
        let cleanDestination = cleanPlaceName(destination)
        guard !cleanOrigin.isEmpty, !cleanDestination.isEmpty else { return nil }
        return ResolvedPassRoute(
            originCode: cleanOrigin,
            originName: cleanOrigin,
            destinationCode: cleanDestination,
            destinationName: cleanDestination
        )
    }

    private static func cleanPlaceName(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"(?i)\b(from|to|destination|origin)\b"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":-")))
    }

    private static func normalize(_ text: String) -> String {
        normalizeSpacing(text)
            .uppercased()
    }

    private static func normalizeSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
    }
}
