import Foundation
import Combine

#if canImport(UIKit) || os(macOS)
/// Isolates high-frequency token updates from `ChatVM.objectWillChange`.
@MainActor final class StreamingMessageStore: ObservableObject {
    /// The id of the message currently streaming, or `nil` when idle.
    @Published private(set) var activeID: UUID?
    /// The latest visible assistant text for `activeID`.
    @Published private(set) var visibleText: String = ""

    func begin(id: UUID, initialText: String = "") {
        activeID = id
        visibleText = initialText
    }

    func update(_ text: String) {
        guard activeID != nil else { return }
        visibleText = text
    }

    func finish() {
        activeID = nil
        visibleText = ""
    }
}
#endif
