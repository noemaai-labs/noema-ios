import Foundation

/// The model-facing document plan for one user turn. The app still owns every
/// implementation detail (full-content fit, RAG thresholds, PDF scope, and
/// policy gates); this value only selects the kind of access that best matches
/// the user's request.
enum DocumentAccessStrategy: String, Codable, Sendable, Equatable {
    case none
    case context
    case navigate
    case contextThenNavigate = "context_then_navigate"

    var usesAutomaticContext: Bool {
        self == .context || self == .contextThenNavigate
    }

    var usesPDFNavigation: Bool {
        self == .navigate || self == .contextThenNavigate
    }
}

/// Persisted receipt for the document decision that precedes retrieval. This is
/// deliberately separate from `RouteDecisionRecord`: document access runs for
/// dataset chats whether or not Autopilot escalation is enabled.
struct DocumentAccessDecisionRecord: Codable, Sendable, Equatable {
    enum DecidedBy: String, Codable, Sendable {
        case appleFoundationModel = "apple_foundation_model"
        case rulesFallback = "rules_fallback"
    }

    var datasetName: String
    /// The semantic plan produced by AFM (or the deterministic fallback).
    var requestedStrategy: DocumentAccessStrategy
    /// The plan after the selected answer model's capabilities are enforced.
    var effectiveStrategy: DocumentAccessStrategy
    var decidedBy: DecidedBy

    var wasCapabilityAdjusted: Bool {
        requestedStrategy != effectiveStrategy
    }
}

/// Capability-only snapshot supplied to the deterministic planner and AFM.
/// It deliberately contains no document text.
struct DocumentAccessContext: Sendable, Equatable {
    var hasActiveDataset: Bool
    var datasetTitle: String?
    var pdfNames: [String]
    var pdfNavigationAvailable: Bool
    var localCanNavigate: Bool
    var escalationCanNavigate: Bool
    /// Whether Noema may inject full-document or semantically retrieved context
    /// before generation. This is the per-chat RAG permission, independent of
    /// direct PDF navigation.
    var automaticContextAvailable: Bool = true

    static let none = DocumentAccessContext(
        hasActiveDataset: false,
        datasetTitle: nil,
        pdfNames: [],
        pdfNavigationAvailable: false,
        localCanNavigate: false,
        escalationCanNavigate: false,
        automaticContextAvailable: false
    )

    var isPDF: Bool { !pdfNames.isEmpty }
}

enum DocumentAccessPlanner {
    /// Universal fallback used on devices without AFM and whenever AFM is slow,
    /// unavailable, quarantined, or returns an unusable value. Bias to context:
    /// supplying relevant evidence is safer than forcing a weak model into a
    /// tool chain, while obvious exact/navigation requests still take the direct
    /// PDF path when that path is actually available.
    static func deterministic(
        userMessage: String,
        previousUserMessage: String? = nil,
        context: DocumentAccessContext
    ) -> DocumentAccessStrategy {
        guard context.hasActiveDataset else { return .none }

        let message = userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            if context.automaticContextAvailable { return .context }
            return context.pdfNavigationAvailable ? .navigate : .none
        }
        let normalized = message.lowercased()

        let quotedPhrase = message.range(
            of: #"[\"“][^\"”\n]{2,}[\"”]"#,
            options: .regularExpression
        ) != nil
        let explicitlyUnrelated = [
            "don't use the document", "do not use the document", "without the document",
            "ignore the document", "unrelated to the document", "general knowledge only"
        ].contains { normalized.contains($0) }
        let exactMarkers = [
            "what page", "which page", "page number", "where exactly",
            "exact wording", "exact phrase", "verbatim", "quote the",
            "every mention", "all mentions", "all occurrences", "each occurrence",
            "how many times", "find every", "find all", "locate the",
            "table of contents", "contents page", "grep", "regex"
        ]
        let conceptualMarkers = [
            "explain", "what does", "what do", "why does", "why do", "how does",
            "how do", "summarize", "summarise", "overview", "main idea", "theme",
            "according to", "compare", "contrast", "relationship", "implication",
            "argument", "conclusion", "recommendation"
        ]

        if explicitlyUnrelated { return .none }

        let wantsExact = quotedPhrase || exactMarkers.contains { normalized.contains($0) }
        let wantsContext = conceptualMarkers.contains { normalized.contains($0) }

        guard context.pdfNavigationAvailable else {
            return context.automaticContextAvailable ? .context : .none
        }
        if wantsExact && wantsContext {
            return context.automaticContextAvailable ? .contextThenNavigate : .navigate
        }
        if wantsExact { return .navigate }

        // Follow-ups such as "where was that?" often omit the noun that appeared
        // in the prior turn. Treat the deictic location form as navigation only
        // when there is prior conversational context to resolve it against.
        if previousUserMessage != nil,
           ["where was that", "where is that", "what page was that", "show me that section"]
            .contains(where: { normalized.contains($0) }) {
            return .navigate
        }

        return context.automaticContextAvailable ? .context : .navigate
    }

    /// Enforces platform/model capability after the answer route is known.
    /// A planner verdict can never make an unavailable tool executable.
    static func constrained(
        _ strategy: DocumentAccessStrategy,
        context: DocumentAccessContext,
        route: AutoRouteTarget? = nil
    ) -> DocumentAccessStrategy {
        guard context.hasActiveDataset else { return .none }

        let destinationCanNavigate: Bool
        switch route {
        case .cloud:
            destinationCanNavigate = context.escalationCanNavigate
        case .local, .none:
            destinationCanNavigate = context.localCanNavigate
        }
        let canNavigate = context.pdfNavigationAvailable && destinationCanNavigate
        let canUseContext = context.automaticContextAvailable
        switch strategy {
        case .none:
            return .none
        case .context:
            if canUseContext { return .context }
            return canNavigate ? .navigate : .none
        case .navigate:
            if canNavigate { return .navigate }
            return canUseContext ? .context : .none
        case .contextThenNavigate:
            if canUseContext && canNavigate { return .contextThenNavigate }
            if canUseContext { return .context }
            return canNavigate ? .navigate : .none
        }
    }

    static func snapshot(
        context: DocumentAccessContext,
        userMessage: String,
        previousUserMessage: String?
    ) -> String {
        let oneLine: (String, Int) -> String = { value, limit in
            let normalized = value
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return String(normalized.prefix(limit))
        }
        let title = oneLine(context.datasetTitle ?? "", 160)
        let names = context.pdfNames.prefix(8).map { oneLine($0, 120) }.joined(separator: ", ")
        var lines = [
            "DOCUMENT: active=\(context.hasActiveDataset ? "yes" : "no"), title=\(title.isEmpty ? "none" : title), kind=\(context.isPDF ? "pdf" : "dataset")",
            "DOCUMENT CAPABILITIES: automatic_context=\(context.automaticContextAvailable ? "yes" : "no"), pdf_navigation=\(context.pdfNavigationAvailable ? "yes" : "no"), local_can_navigate=\(context.localCanNavigate ? "yes" : "no"), escalation_can_navigate=\(context.escalationCanNavigate ? "yes" : "no")"
        ]
        if !names.isEmpty { lines.append("PDFS: \(names)") }
        if let previous = previousUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !previous.isEmpty {
            lines.append("PREVIOUS USER MESSAGE (may be truncated): \"\(String(previous.prefix(240)))\"")
        }
        let bounded: String
        if userMessage.count > 1_600 {
            bounded = String(userMessage.prefix(1_200)) + "\n[...]\n" + String(userMessage.suffix(400))
        } else {
            bounded = userMessage
        }
        lines.append("NEW MESSAGE:\n\"\(bounded)\"")
        return lines.joined(separator: "\n")
    }
}

/// Shared active-dataset PDF discovery. The tool and prompt use the same list so
/// a model is never offered a filename it cannot actually open.
enum PDFDatasetAccess {
    static func pdfURLs(in root: URL, limit: Int = 50) -> [URL] {
        if root.pathExtension.lowercased() == "pdf" { return [root] }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var urls: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile ?? true else { continue }
            urls.append(url)
            if urls.count >= max(1, limit) { break }
        }
        return urls.sorted {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
    }
}
