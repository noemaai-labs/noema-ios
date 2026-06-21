import Foundation

struct ImagePromptBudgetEstimate: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case comfortable
        case tight
        case overBudget
    }

    let imageCount: Int
    let estimatedPromptTokens: Int
    let totalFileBytes: Int64
    let usablePromptTokens: Int
    let status: Status

    var fractionOfPromptBudget: Double {
        guard usablePromptTokens > 0 else { return 0 }
        return min(1, Double(estimatedPromptTokens) / Double(usablePromptTokens))
    }
}

enum ImagePromptBudgetEstimator {
    static let promptTokensPerImage = 576

    static func estimate(
        imageCount: Int,
        totalFileBytes: Int64,
        usablePromptTokens: Int
    ) -> ImagePromptBudgetEstimate {
        let count = max(0, imageCount)
        let tokens = count * promptTokensPerImage
        let budget = max(0, usablePromptTokens)
        let status: ImagePromptBudgetEstimate.Status
        if budget > 0, tokens > budget {
            status = .overBudget
        } else if budget > 0, Double(tokens) / Double(budget) >= 0.35 {
            status = .tight
        } else {
            status = .comfortable
        }
        return ImagePromptBudgetEstimate(
            imageCount: count,
            estimatedPromptTokens: tokens,
            totalFileBytes: max(0, totalFileBytes),
            usablePromptTokens: budget,
            status: status
        )
    }
}
