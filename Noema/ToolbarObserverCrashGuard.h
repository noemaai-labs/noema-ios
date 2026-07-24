#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Installs a narrowly-scoped guard against a known SwiftUI/AppKit reentrancy bug on macOS.
///
/// During a fullscreen live-resize SwiftUI's internal `BarAppearanceBridge` can call
/// `-[NSToolbar removeObserver:forKeyPath:context:]` for the `displayMode` key path when it
/// was never registered as an observer on that toolbar, which throws an `NSRangeException`
/// ("Cannot remove an observer … because it is not registered as an observer") and terminates
/// the app. The app cannot influence that reentrant call, so this installs a wrapper that
/// swallows *only* that specific exception on `NSToolbar` instances and re-raises anything else.
///
/// The guard is scoped to `NSToolbar` (no other class is affected), idempotent, and a no-op on
/// non-macOS platforms. Safe to call more than once.
void NoemaInstallToolbarObserverCrashGuard(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
