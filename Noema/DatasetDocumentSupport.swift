import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Single source of truth for which document types the dataset / RAG importer accepts.
///
/// Previously every import surface (Datasets Explore, Stored, the visionOS panel) carried
/// its own copy of the accepted-extension / UTType lists and they drifted out of sync —
/// most of them silently dropped Markdown, CSV and TSV files with no feedback, which read
/// to users as "nothing happened". This centralises the policy and the user-facing message.
enum DatasetDocumentSupport {
    /// File extensions we actually import as dataset documents. Transcription media
    /// (audio / video) is accepted separately via `TranscriptionMediaSupport`.
    static let acceptedExtensions: Set<String> = ["pdf", "epub", "txt", "md", "markdown", "json", "jsonl"]

    /// UTTypes offered to the system file picker. CSV/TSV are deliberately kept
    /// *selectable* so that picking one yields a clear "unsupported" message instead of
    /// appearing greyed-out with no explanation — they are then rejected after selection
    /// (see `isAccepted` / `skippedMessage`).
    static func allowedUTTypes() -> [UTType] {
        var types: [UTType] = [.pdf, .plainText]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        if let md = UTType(filenameExtension: "md") { types.append(md) }
        if let markdown = UTType(filenameExtension: "markdown") { types.append(markdown) }
        types.append(.json)
        if let jsonl = UTType(filenameExtension: "jsonl") { types.append(jsonl) }
        // Selectable but intentionally rejected so the drop is explained, not silent.
        types.append(.commaSeparatedText)
        if let tsv = UTType(filenameExtension: "tsv") { types.append(tsv) }
        types.append(contentsOf: TranscriptionMediaSupport.allowedContentTypes)
        return types
    }

    /// Whether a picked URL is something we will actually import.
    static func isAccepted(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
            || TranscriptionMediaSupport.isSupported(url)
    }

    /// Splits a picked selection into the files we'll import and the ones we'll skip.
    static func partition(_ urls: [URL]) -> (accepted: [URL], rejected: [URL]) {
        var accepted: [URL] = []
        var rejected: [URL] = []
        for url in urls {
            if isAccepted(url) { accepted.append(url) } else { rejected.append(url) }
        }
        return (accepted, rejected)
    }

    /// A user-facing message describing files skipped because their format is unsupported,
    /// or `nil` when there is nothing to report.
    static func skippedMessage(for urls: [URL]) -> String? {
        let names = urls.filter { !isAccepted($0) }.map { $0.lastPathComponent }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(3).joined(separator: ", ")
        if names.count > 3 {
            return String(localized: "Skipped \(shown) and \(names.count - 3) more. Supported formats: PDF, EPUB, TXT, Markdown and JSON.")
        } else {
            return String(localized: "Skipped \(shown). Supported formats: PDF, EPUB, TXT, Markdown and JSON.")
        }
    }
}

extension View {
    /// Presents a transient alert describing dataset files that were skipped because their
    /// format isn't supported. No-op while `message` is nil.
    func datasetImportNotice(_ message: Binding<String?>) -> some View {
        alert(
            LocalizedStringKey("Unsupported file type"),
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } }
            )
        ) {
            Button(LocalizedStringKey("OK"), role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
