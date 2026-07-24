import Foundation

extension ChatVM {

    /// Re-run the most recent prompt with the currently-armed interventions and stream
    /// the result into the counterfactual panel. Runs sequentially with the chat: it
    /// shares the one MLX client, so it bails while the chat is generating (and the
    /// chat bails while this runs, via `jspaceCounterfactualRunning`).
    func runJSpaceCounterfactual() {
        let controller = JSpaceLensController.shared
        jspaceCounterfactualTask?.cancel()

        guard modelLoaded, loadedFormat == .mlx, let client = self.client else {
            controller.reportCounterfactualBlocked("Load an MLX model to run a counterfactual.")
            return
        }
        guard !isStreaming, !isStreamingInAnotherSession, !jspaceCounterfactualRunning, !sendInFlight else {
            controller.reportCounterfactualBlocked("Wait for the current response to finish.")
            return
        }
        guard controller.interventions.contains(where: \.enabled) else {
            controller.reportCounterfactualBlocked("Add a steer or swap first.")
            return
        }
        guard let sIdx = activeIndex, sessions.indices.contains(sIdx) else { return }

        let all = sessions[sIdx].messages
        guard let assistantIdx = all.lastIndex(where: {
            $0.role == "🤖" || $0.role.lowercased() == "assistant"
        }) else {
            controller.reportCounterfactualBlocked("Send a message first, then steer a token.")
            return
        }
        guard let userIdx = all[..<assistantIdx].lastIndex(where: {
            $0.role == "🧑‍💻" || $0.role.lowercased() == "user"
        }) else {
            controller.reportCounterfactualBlocked("No user message to re-run.")
            return
        }

        let userText = all[userIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = all[assistantIdx].text
        let cfHistory = Array(all[...userIdx])
        let summaries = controller.interventionSummaries()

        // Steering only installs when the lens is enabled; arming forces it on.
        controller.armForCounterfactual()
        // Reproduce the exact prompt the original turn used (same system prompt +
        // template). MLX text models consume the fully-templated string as `.plain`.
        let (promptStr, _, _) = buildPrompt(kind: currentKind, history: cfHistory)
        let input = LLMInput(.plain(promptStr))

        controller.beginCounterfactual(
            prompt: userText.isEmpty ? "(no text)" : userText,
            original: original,
            interventions: summaries
        )
        jspaceCounterfactualRunning = true

        jspaceCounterfactualTask = Task { [weak self] in
            guard let self else { return }
            defer { self.jspaceCounterfactualRunning = false }
            var caughtError: String?
            do {
                for try await token in try await client.textStream(from: input) {
                    if Task.isCancelled { break }
                    controller.appendCounterfactual(token)
                }
                caughtError = Task.isCancelled ? "Cancelled." : nil
            } catch is CancellationError {
                caughtError = "Cancelled."
            } catch {
                caughtError = error.localizedDescription
            }
            // Purge any steered K/V this run left in the shared MLX prompt cache, so a
            // later real turn — especially with the lens toggled off — never reuses
            // steered state. Correctness over the one-time re-prefill it costs.
            await client.reset()
            controller.finishCounterfactual(error: caughtError)
        }
    }

    /// Cancel any in-flight counterfactual generation and dismiss the panel. Only
    /// touches the shared client when *our* run owns it — otherwise closing the panel
    /// while a normal chat answer streams would abort that answer.
    func cancelJSpaceCounterfactual() {
        if jspaceCounterfactualRunning {
            jspaceCounterfactualTask?.cancel()
            client?.cancelActive()
        }
        jspaceCounterfactualTask = nil
        jspaceCounterfactualRunning = false
        JSpaceLensController.shared.clearCounterfactual()
    }
}
