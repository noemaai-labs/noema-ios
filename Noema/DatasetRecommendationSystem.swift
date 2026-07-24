import Foundation

struct DatasetRecommendationSystem {
    // MARK: - Types
    
    struct Recommendation {
        let sizeCategory: SizeCategory
        let estimatedEmbeddingTime: TimeInterval
        let estimatedRAMUsage: Int64 // in bytes
        let performanceNote: String
        let suggestion: String
    }
    
    enum SizeCategory: String, CaseIterable {
        case small = "Small"
        case medium = "Medium"
        case large = "Large"
        case veryLarge = "Very Large"
        case extreme = "Extreme"

        func title(locale: Locale) -> String {
            String(localized: String.LocalizationValue(rawValue), locale: locale)
        }

        func description(locale: Locale) -> String {
            switch self {
            case .small: return String(localized: "Under 10 MB", locale: locale)
            case .medium: return String(localized: "10–50 MB", locale: locale)
            case .large: return String(localized: "50–200 MB", locale: locale)
            case .veryLarge: return String(localized: "200–500 MB", locale: locale)
            case .extreme: return String(localized: "Over 500 MB", locale: locale)
            }
        }
        
        var iconName: String {
            switch self {
            case .small: return "checkmark.circle.fill"
            case .medium: return "info.circle.fill"
            case .large: return "exclamationmark.triangle.fill"
            case .veryLarge: return "exclamationmark.triangle.fill"
            case .extreme: return "xmark.octagon.fill"
            }
        }
        
        var iconColor: String {
            switch self {
            case .small: return "green"
            case .medium: return "blue"
            case .large: return "orange"
            case .veryLarge: return "orange"
            case .extreme: return "red"
            }
        }
    }
    
    // MARK: - Constants
    
    // Embedding speed estimates (based on typical performance)
    // These are conservative estimates for typical hardware
    private static let bytesPerSecond: Double = 500_000 // ~0.5 MB/s for embedding
    
    // RAM multipliers
    private static let ramMultiplierBase = 2.5 // Base RAM usage is ~2.5x file size
    private static let ramMultiplierPeak = 4.0 // Peak RAM during processing can be ~4x
    
    // MARK: - Public Methods

    static func recommendation(for sizeBytes: Int64, locale: Locale) -> Recommendation {
        let category = categorize(sizeBytes: sizeBytes)
        let estimatedTime = estimateEmbeddingTime(sizeBytes: sizeBytes)
        let estimatedRAM = estimateRAMUsage(sizeBytes: sizeBytes)
        
        let performanceNote = generatePerformanceNote(category: category, locale: locale)
        let suggestion = generateSuggestion(category: category, locale: locale)
        
        return Recommendation(
            sizeCategory: category,
            estimatedEmbeddingTime: estimatedTime,
            estimatedRAMUsage: estimatedRAM,
            performanceNote: performanceNote,
            suggestion: suggestion
        )
    }
    
    // MARK: - Private Methods
    
    private static func categorize(sizeBytes: Int64) -> SizeCategory {
        let sizeMB = Double(sizeBytes) / 1_048_576.0
        
        switch sizeMB {
        case ..<10:
            return .small
        case 10..<50:
            return .medium
        case 50..<200:
            return .large
        case 200..<500:
            return .veryLarge
        default:
            return .extreme
        }
    }
    
    private static func estimateEmbeddingTime(sizeBytes: Int64) -> TimeInterval {
        // Add some overhead for initialization and finalization
        let baseTime = Double(sizeBytes) / bytesPerSecond
        let overhead = 10.0 // 10 seconds base overhead
        
        // Add scaling factor for larger files (processing gets slower)
        let sizeMB = Double(sizeBytes) / 1_048_576.0
        let scalingFactor: Double
        if sizeMB < 50 {
            scalingFactor = 1.0
        } else if sizeMB < 200 {
            scalingFactor = 1.2
        } else if sizeMB < 500 {
            scalingFactor = 1.5
        } else {
            scalingFactor = 2.0
        }
        
        return (baseTime * scalingFactor) + overhead
    }
    
    private static func estimateRAMUsage(sizeBytes: Int64) -> Int64 {
        // Peak RAM usage during embedding
        return Int64(Double(sizeBytes) * ramMultiplierPeak)
    }
    
    private static func generatePerformanceNote(category: SizeCategory, locale: Locale) -> String {
        switch category {
        case .small:
            return String(localized: "This dataset should embed quickly with minimal resource usage. Perfect for testing and quick experiments.", locale: locale)
        case .medium:
            return String(localized: "This dataset is a reasonable size for most systems. Embedding should complete in a few minutes.", locale: locale)
        case .large:
            return String(localized: "This is a substantial dataset. Ensure you have adequate RAM and expect embedding to take 10–30 minutes.", locale: locale)
        case .veryLarge:
            return String(localized: "This is a very large dataset. Embedding may take 30–60 minutes and requires significant RAM.", locale: locale)
        case .extreme:
            return String(localized: "This is an extremely large dataset. Consider splitting it into smaller parts for better performance.", locale: locale)
        }
    }
    
    private static func generateSuggestion(category: SizeCategory, locale: Locale) -> String {
        switch category {
        case .small:
            return String(localized: "Go ahead and download! This size works well on all systems.", locale: locale)
        case .medium:
            return String(localized: "Recommended for most users. Make sure you have at least 4GB of free RAM.", locale: locale)
        case .large:
            return String(localized: "Recommended only if you have 8GB+ RAM available. Close other applications before embedding.", locale: locale)
        case .veryLarge:
            return String(localized: "Recommended only for systems with 16GB+ RAM. Consider processing during off-hours.", locale: locale)
        case .extreme:
            return String(localized: "Not recommended for typical systems. Consider finding a smaller version or subset of this dataset.", locale: locale)
        }
    }
    
    // MARK: - Formatting Helpers
    
    static func formatTime(_ seconds: TimeInterval, locale: Locale) -> String {
        if seconds < 60 {
            return String(localized: "< 1 minute", locale: locale)
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds < 3600 ? [.minute] : [.hour, .minute]
        formatter.maximumUnitCount = seconds < 3600 ? 1 : 2
        formatter.collapsesLargestUnit = false
        formatter.zeroFormattingBehavior = .default
        var cal = Calendar.current
        cal.locale = locale
        formatter.calendar = cal
        if let formatted = formatter.string(from: seconds) {
            return formatted
        }
        let minutesFallback = Int(seconds / 60)
        return String.localizedStringWithFormat(String(localized: "%d minutes", locale: locale), minutesFallback)
    }
    
    static func formatRAM(_ bytes: Int64, locale: Locale) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }
}
