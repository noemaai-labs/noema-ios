import Foundation

#if canImport(UIKit) || os(macOS)
/// Process-wide memo for pure, deterministic text-parsing results.
///
/// Every ChatVM publish (~10 Hz while streaming) re-renders every visible
/// message row via `@EnvironmentObject`, and each row used to re-parse its
/// full markdown from scratch — saturating the main thread and making
/// scrolling/tool-call animations stutter during inference. Caching makes
/// those re-renders O(1) for unchanged text.
final class TextComputationCache<Value>: @unchecked Sendable {
    private final class Box {
        let value: Value
        init(_ value: Value) { self.value = value }
    }
    private let cache = NSCache<NSString, Box>()

    init(countLimit: Int = 512) {
        cache.countLimit = countLimit
    }

    func value(for key: String, compute: () -> Value) -> Value {
        let nsKey = key as NSString
        if let hit = cache.object(forKey: nsKey) { return hit.value }
        let computed = compute()
        cache.setObject(Box(computed), forKey: nsKey)
        return computed
    }
}
#endif
