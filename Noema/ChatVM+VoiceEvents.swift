import Foundation

extension ChatVM {
    /// Lifecycle of one assistant turn as observed by await-style consumers
    /// (voice mode). `.continuingWithTool` marks the end of a streamed segment
    /// that will be followed by a tool continuation, not the end of the turn.
    enum AssistantTurnEvent: Sendable, Equatable {
        case completed(messageID: UUID)
        case continuingWithTool(messageID: UUID)
        case failed(messageID: UUID?)
        case cancelled
    }
}
