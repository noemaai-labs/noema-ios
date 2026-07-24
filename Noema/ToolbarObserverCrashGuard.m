#import "ToolbarObserverCrashGuard.h"

#if TARGET_OS_OSX

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <os/log.h>

typedef void (*NoemaRemoveObserverIMP)(id, SEL, id, NSString *, void *);

// The original NSObject implementation of -removeObserver:forKeyPath:context: that NSToolbar
// inherits. Captured before we install our wrapper so the wrapper can invoke it directly
// (bypassing dynamic dispatch) without recursing into itself.
static NoemaRemoveObserverIMP gOriginalRemoveObserverIMP = NULL;

static void NoemaSafeRemoveObserver(id self, SEL _cmd, id observer, NSString *keyPath, void *context) {
    @try {
        if (gOriginalRemoveObserverIMP != NULL) {
            gOriginalRemoveObserverIMP(self, _cmd, observer, keyPath, context);
        }
    } @catch (NSException *exception) {
        // Only swallow the specific "observer was never registered" range exception. Anything
        // else is a genuine programmer error and must keep propagating. This is intentionally
        // key-path-agnostic: removing an observer that was never registered is always a benign
        // no-op regardless of key path, and SwiftUI's toolbar bridge is not guaranteed to fault
        // only on "displayMode", so we cover every key path rather than hard-coding one.
        BOOL isUnregisteredObserver =
            [exception.name isEqualToString:NSRangeException] &&
            [exception.reason containsString:@"not registered as an observer"];
        if (isUnregisteredObserver) {
            os_log_error(OS_LOG_DEFAULT,
                         "Noema: swallowed SwiftUI toolbar KVO teardown exception (keyPath '%{public}@')",
                         keyPath ?: @"(nil)");
            return;
        }
        @throw;
    }
}

#endif // TARGET_OS_OSX

void NoemaInstallToolbarObserverCrashGuard(void) {
#if TARGET_OS_OSX
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class toolbarClass = [NSToolbar class];
        SEL selector = @selector(removeObserver:forKeyPath:context:);

        // NSToolbar inherits this from NSObject's KVO category and does not override it, so
        // class_getInstanceMethod resolves the inherited implementation.
        Method inherited = class_getInstanceMethod(toolbarClass, selector);
        if (inherited == NULL) { return; }

        gOriginalRemoveObserverIMP = (NoemaRemoveObserverIMP)method_getImplementation(inherited);
        const char *types = method_getTypeEncoding(inherited);

        // class_addMethod only succeeds when NSToolbar has no own implementation of the selector,
        // which keeps the wrapper scoped to NSToolbar instances and leaves every other class
        // (including NSObject) untouched. If it ever fails we simply leave KVO removal unguarded;
        // log it so a future OS change that breaks the mechanism is diagnosable rather than silent.
        if (!class_addMethod(toolbarClass, selector, (IMP)NoemaSafeRemoveObserver, types)) {
            os_log_error(OS_LOG_DEFAULT,
                         "Noema: could not install NSToolbar KVO crash guard (removeObserver override already present)");
        }
    });
#endif
}
