import Foundation

@MainActor
final class SearchUsageTracker: ObservableObject {
    static let shared = SearchUsageTracker()
    
    private let dailyLimit = 5
    private let usageKey = "searchUsageData"
    
    struct UsageData: Codable {
        var count: Int
        var lastResetDate: Date
    }
    
    @Published var currentUsage: Int = 0
    @Published var limitReached: Bool = false
    @Published var lastResetDate: Date = Date()
    
    private init() {
        loadUsageData()
    }
    
    var remainingSearches: Int {
        max(0, dailyLimit - currentUsage)
    }
    
    var usageText: String {
        "\(currentUsage) / \(dailyLimit) searches used today"
    }
    
    func canPerformSearch() -> Bool {
        checkAndResetIfNeeded()
        return currentUsage < dailyLimit
    }
    
    func incrementUsage() {
        checkAndResetIfNeeded()
        currentUsage += 1
        limitReached = currentUsage >= dailyLimit
        saveUsageData()
    }
    
    private func checkAndResetIfNeeded() {
        let calendar = Calendar.current
        let now = Date()
        
        if calendar.dateComponents([.day], from: lastResetDate, to: now).day ?? 0 >= 1 {
            resetUsage()
        }
    }
    
    private func resetUsage() {
        currentUsage = 0
        limitReached = false
        lastResetDate = Date()
        saveUsageData()
    }
    
    private func loadUsageData() {
        guard let data = UserDefaults.standard.data(forKey: usageKey),
              let usage = try? JSONDecoder().decode(UsageData.self, from: data) else {
            // No saved data, start fresh
            resetUsage()
            return
        }
        
        currentUsage = usage.count
        lastResetDate = usage.lastResetDate
        checkAndResetIfNeeded()
        limitReached = currentUsage >= dailyLimit
    }
    
    private func saveUsageData() {
        let data = UsageData(count: currentUsage, lastResetDate: lastResetDate)
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: usageKey)
        }
    }
    
    func timeUntilReset() -> String {
        let calendar = Calendar.current
        let resetDate = calendar.date(byAdding: .day, value: 1, to: lastResetDate) ?? Date()
        let components = calendar.dateComponents([.hour, .minute], from: Date(), to: resetDate)
        
        if let hours = components.hour, let minutes = components.minute {
            if hours > 0 {
                return "Resets in \(hours)h \(minutes)m"
            } else {
                return "Resets in \(minutes)m"
            }
        }
        return "Resets soon"
    }
    
    // Alias method for consistency with SettingsStore
    func canSearch() -> Bool {
        return canPerformSearch()
    }
    
    // Method to reset daily count (used when subscription is activated)
    func resetDailyCount() {
        resetUsage()
    }
}
