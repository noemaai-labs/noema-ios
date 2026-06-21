import Foundation

enum TokenLatencySparkline {
    private static let glyphs: [Character] = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    static func sparkline(for samplesMilliseconds: [Double], maxSamples: Int = 32) -> String {
        let samples = samplesMilliseconds
            .filter { $0.isFinite && $0 >= 0 }
            .suffix(max(1, maxSamples))
        guard !samples.isEmpty else { return "" }

        let minValue = samples.min() ?? 0
        let maxValue = samples.max() ?? minValue
        guard maxValue > minValue else {
            return String(repeating: String(glyphs[0]), count: samples.count)
        }

        return samples.map { value in
            let normalized = (value - minValue) / (maxValue - minValue)
            let index = min(glyphs.count - 1, max(0, Int((normalized * Double(glyphs.count - 1)).rounded())))
            return String(glyphs[index])
        }.joined()
    }

    static func maxLatencyMilliseconds(_ samplesMilliseconds: [Double]) -> Double? {
        samplesMilliseconds
            .filter { $0.isFinite && $0 >= 0 }
            .max()
    }
}
