enum PDFGrepQuerySemantics {
    static let modelInstruction = "- IMPORTANT: a plain `grep` query is one literal contiguous substring; spaces are part of that exact phrase, not separators between independent keywords. Never combine unrelated search terms into one plain query. Start with one distinctive word or short exact phrase, WAIT for the result, then make a separate `grep` call for a synonym if needed. Use `regex`:true only for intentional alternatives, such as `revenue|sales`."

    static func zeroMatchHint(query: String, regex: Bool) -> String? {
        guard !regex, query.split(whereSeparator: { $0.isWhitespace }).count > 1 else {
            return nil
        }
        return "No literal phrase matched. Plain grep treats a multi-word query as one contiguous phrase, not as separate keywords. Retry with one distinctive word or a shorter exact phrase; make a separate grep call for each alternative. Use regex:true only when you intentionally want alternatives, for example revenue|sales."
    }
}
