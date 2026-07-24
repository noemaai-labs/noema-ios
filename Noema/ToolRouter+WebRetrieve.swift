import Foundation

@MainActor
func handle_noema_web_retrieve(_ argsJSON: Data, contextLimit: Double = 4096) async -> Data {
    await WebRetrieveExecutor.run(args: argsJSON, contextLimit: contextLimit)
}
