import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

#if os(macOS)
private final class MacNonDraggableView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct MacWindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> MacNonDraggableView {
        MacNonDraggableView(frame: .zero)
    }

    func updateNSView(_ nsView: MacNonDraggableView, context: Context) {}
}

final class MacChatScrollObserverView: NSView {
    var onPositionChange: ((Bool, Bool) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private var boundsObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        translatesAutoresizingMaskIntoConstraints = false
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachIfNeeded()
    }

    func refreshObserver() {
        attachIfNeeded()
    }

    private func attachIfNeeded() {
        if boundsObserver != nil { return }
        guard let scrollView = findEnclosingScrollView() else { return }
        observedScrollView = scrollView

        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitPositionChange()
            }
        }

        Task { @MainActor [weak self] in
            self?.emitPositionChange()
        }
    }

    private func findEnclosingScrollView() -> NSScrollView? {
        var view: NSView? = self
        while let current = view {
            if let scrollView = current.enclosingScrollView {
                return scrollView
            }
            view = current.superview
        }
        return nil
    }

    private func emitPositionChange() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }

        let visibleMaxY = scrollView.contentView.bounds.maxY
        let contentMaxY = documentView.frame.maxY
        let distanceFromBottom = max(0, contentMaxY - visibleMaxY)
        let nearBottom = distanceFromBottom <= 28

        let userInitiated: Bool = {
            guard let event = NSApp.currentEvent else { return false }
            switch event.type {
            case .scrollWheel, .leftMouseDown, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                return true
            default:
                return false
            }
        }()

        onPositionChange?(nearBottom, userInitiated)
    }
}

struct MacChatScrollObserver: NSViewRepresentable {
    let onPositionChange: (Bool, Bool) -> Void

    func makeNSView(context: Context) -> MacChatScrollObserverView {
        let view = MacChatScrollObserverView(frame: .zero)
        view.onPositionChange = onPositionChange
        return view
    }

    func updateNSView(_ nsView: MacChatScrollObserverView, context: Context) {
        nsView.onPositionChange = onPositionChange
        nsView.refreshObserver()
    }
}

#endif

extension View {
    @ViewBuilder
    func macWindowDragDisabled() -> some View {
#if os(macOS)
        self.background(MacWindowDragBlocker().allowsHitTesting(false))
#else
        self
#endif
    }
}
