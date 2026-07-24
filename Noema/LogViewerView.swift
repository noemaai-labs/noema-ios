import SwiftUI

struct LogViewerView: View {
    let url: URL

    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    @State private var timer: Timer?

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .monospaced()
                .onAppear { load(); startTimer() }
                .onDisappear { timer?.invalidate() }
                .navigationTitle("Logs")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }

    }

    private func load() {
        let fileURL = url
        Task { @MainActor in
            let str = await Self.readLogTail(fileURL)
            text = str
        }
    }

    /// Read the log off the main thread, tailing to a bounded size — the log is never rotated and
    /// can be large, and the previous synchronous `Data(contentsOf:)` ran on the main actor on open.
    nonisolated private static func readLogTail(_ url: URL) async -> String {
        await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return "" }
            let maxBytes = 512 * 1024
            let slice = data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
            return String(decoding: slice, as: UTF8.self)
        }.value
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                load()
            }
        }
    }
}
