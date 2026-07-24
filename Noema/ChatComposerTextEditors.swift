import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
struct MobileBottomAnchoredTextEditor: UIViewRepresentable {
    struct SubmitConfiguration {
        var behavior: ChatSendBehavior
        var canSubmit: Bool
        var onSubmit: () -> Void
    }

    @Binding var text: String
    var focus: Binding<Bool>? = nil
    var isDisabled: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    var font: UIFont
    var submitConfiguration: SubmitConfiguration? = nil

    private protocol SubmitActionHandling: AnyObject {
        func submitFromKeyboard()
    }

#if os(iOS)
    private final class SubmitAwareTextView: UITextView {
        weak var submitHandler: SubmitActionHandling?
        var submitConfiguration: SubmitConfiguration? {
            didSet { updateSubmitUI(previousBehavior: oldValue?.behavior) }
        }

        override var keyCommands: [UIKeyCommand]? {
            guard submitConfiguration?.canSubmit == true else { return super.keyCommands }
            let command = UIKeyCommand(input: "\r", modifierFlags: [.command], action: #selector(handleCommandReturn))
            command.discoverabilityTitle = String(localized: "Send")
            if #available(iOS 15.0, *) {
                command.wantsPriorityOverSystemBehavior = true
            }
            return (super.keyCommands ?? []) + [command]
        }

        override var canBecomeFirstResponder: Bool { true }

        @objc private func handleCommandReturn() {
            guard submitConfiguration?.canSubmit == true else { return }
            submitHandler?.submitFromKeyboard()
        }

        private func updateSubmitUI(previousBehavior: ChatSendBehavior?) {
            inputAccessoryView = nil
            switch submitConfiguration?.behavior ?? .defaultValue {
            case .keyboardToolbarSend:
                returnKeyType = .default
            case .returnKeySends:
                returnKeyType = .send
            }
            if isFirstResponder && previousBehavior != submitConfiguration?.behavior {
                reloadInputViews()
            }
        }
    }
#endif

    final class Coordinator: NSObject, UITextViewDelegate, SubmitActionHandling {
        var parent: MobileBottomAnchoredTextEditor
        weak var textView: UITextView?
        private var isSyncingFromSwiftUI = false
        private var isPerformingProgrammaticFocusChange = false
        var lastSwiftUIFocusValue: Bool?
        private var pendingScrollWorkItem: DispatchWorkItem?

        init(parent: MobileBottomAnchoredTextEditor) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            setFocusState(true)
            scheduleScrollSelectionToVisible(in: textView)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            setFocusState(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isSyncingFromSwiftUI else { return }
            if parent.text != textView.text {
                parent.text = textView.text
            }
            scheduleScrollSelectionToVisible(in: textView, anchorToBottom: isSelectionAtEnd(in: textView))
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isSyncingFromSwiftUI else { return }
            scheduleScrollSelectionToVisible(in: textView)
        }

        func textView(_ textView: UITextView,
                      shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
#if os(iOS)
            guard let submitConfiguration = parent.submitConfiguration,
                  submitConfiguration.behavior == .returnKeySends,
                  text == "\n" else {
                return true
            }

            guard submitConfiguration.canSubmit else { return false }
            submitConfiguration.onSubmit()
            return false
#else
            return true
#endif
        }

        func synchronizeTextViewIfNeeded(with text: String) {
            guard let textView, textView.text != text else { return }
            let previousSelection = textView.selectedRange
            isSyncingFromSwiftUI = true
            textView.text = text
            textView.font = parent.font
            textView.typingAttributes[.font] = parent.font
            let utf16Count = text.utf16.count
            let clampedLocation = min(previousSelection.location, utf16Count)
            let clampedLength = min(previousSelection.length, max(utf16Count - clampedLocation, 0))
            textView.selectedRange = NSRange(location: clampedLocation, length: clampedLength)
            isSyncingFromSwiftUI = false
            scheduleScrollSelectionToVisible(in: textView, anchorToBottom: isSelectionAtEnd(in: textView))
        }

        func performProgrammaticFocusChange(_ change: () -> Void) {
            isPerformingProgrammaticFocusChange = true
            change()
            isPerformingProgrammaticFocusChange = false
        }

        func submitFromKeyboard() {
            guard parent.submitConfiguration?.canSubmit == true else { return }
            parent.submitConfiguration?.onSubmit()
        }

        func ensureCollapsedInsertionSelection(in textView: UITextView) {
            let utf16Count = textView.text.utf16.count
            let selectedRange = textView.selectedRange
            let insertionLocation: Int

            if selectedRange.location != NSNotFound {
                let clampedLocation = min(max(selectedRange.location, 0), utf16Count)
                let clampedLength = min(max(selectedRange.length, 0), max(utf16Count - clampedLocation, 0))
                insertionLocation = min(clampedLocation + clampedLength, utf16Count)
            } else {
                insertionLocation = utf16Count
            }

            let collapsedRange = NSRange(location: insertionLocation, length: 0)
            if textView.selectedRange != collapsedRange {
                textView.selectedRange = collapsedRange
            }
        }

        func scheduleScrollSelectionToVisible(in textView: UITextView, anchorToBottom: Bool? = nil) {
            pendingScrollWorkItem?.cancel()
            let shouldAnchorToBottom = anchorToBottom ?? isSelectionAtEnd(in: textView)
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.scrollSelectionToVisible(in: textView, anchorToBottom: shouldAnchorToBottom)
            }
            pendingScrollWorkItem = workItem
            DispatchQueue.main.async(execute: workItem)
        }

        private func isSelectionAtEnd(in textView: UITextView) -> Bool {
            let selectedRange = textView.selectedRange
            return selectedRange.length == 0 && selectedRange.location == textView.text.utf16.count
        }

        private func setFocusState(_ isFocused: Bool) {
            guard !isPerformingProgrammaticFocusChange else { return }
            guard parent.focus?.wrappedValue != isFocused else { return }
            parent.focus?.wrappedValue = isFocused
        }

        private func scrollSelectionToVisible(in textView: UITextView, anchorToBottom: Bool) {
            guard let selectedTextRange = textView.selectedTextRange else { return }
            textView.layoutManager.ensureLayout(for: textView.textContainer)

            var caretRect = textView.caretRect(for: selectedTextRange.end)
            if caretRect.isNull || caretRect.isInfinite {
                return
            }

            if caretRect.height == 0 {
                caretRect.size.height = textView.font?.lineHeight ?? parent.font.lineHeight
            }

            let boundsHeight = textView.bounds.height
            guard boundsHeight > 0 else { return }

            let minOffsetY = -textView.adjustedContentInset.top
            let maxOffsetY = max(minOffsetY, textView.contentSize.height - boundsHeight + textView.adjustedContentInset.bottom)
            let currentOffsetY = textView.contentOffset.y
            let topRevealPadding = max(parent.topInset, 6)
            let bottomAnchorMargin = max(parent.bottomInset, 10)
            let visibleMinY = currentOffsetY + topRevealPadding
            let visibleMaxY = currentOffsetY + boundsHeight - bottomAnchorMargin

            var targetOffsetY = currentOffsetY

            if anchorToBottom {
                let anchoredOffsetY = caretRect.maxY - boundsHeight + bottomAnchorMargin
                targetOffsetY = max(currentOffsetY, anchoredOffsetY)
            } else if caretRect.minY < visibleMinY {
                targetOffsetY = caretRect.minY - topRevealPadding
            } else if caretRect.maxY > visibleMaxY {
                targetOffsetY = caretRect.maxY - boundsHeight + bottomAnchorMargin
            }

            let clampedOffsetY = min(max(targetOffsetY, minOffsetY), maxOffsetY)
            guard abs(clampedOffsetY - currentOffsetY) > 0.5 else { return }
            textView.setContentOffset(CGPoint(x: textView.contentOffset.x, y: clampedOffsetY), animated: false)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        #if os(iOS)
        let textView = SubmitAwareTextView(frame: .zero)
        textView.submitHandler = context.coordinator
        textView.submitConfiguration = submitConfiguration
        #else
        let textView = UITextView(frame: .zero)
        #endif
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.font = font
        textView.typingAttributes[.font] = font
        textView.text = text
        textView.textAlignment = .natural
        textView.isScrollEnabled = true
        textView.showsVerticalScrollIndicator = false
        textView.showsHorizontalScrollIndicator = false
        textView.alwaysBounceVertical = false
        #if !os(visionOS)
        textView.keyboardDismissMode = .interactive
        #endif
        textView.autocapitalizationType = .sentences
        textView.autocorrectionType = .default
        textView.smartQuotesType = .default
        textView.smartDashesType = .default
        textView.smartInsertDeleteType = .default
        textView.allowsEditingTextAttributes = false
        textView.dataDetectorTypes = []
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        context.coordinator.textView = textView
        context.coordinator.lastSwiftUIFocusValue = focus?.wrappedValue
        updateTextView(textView, coordinator: context.coordinator)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.textView = textView
        updateTextView(textView, coordinator: context.coordinator)

        let requestedFocus = focus?.wrappedValue
        let shouldRequestFocus = requestedFocus == true && !isDisabled
        let didRequestBlur = context.coordinator.lastSwiftUIFocusValue == true && requestedFocus == false

        if shouldRequestFocus {
            if !textView.isFirstResponder {
                context.coordinator.ensureCollapsedInsertionSelection(in: textView)
                context.coordinator.performProgrammaticFocusChange {
                    textView.becomeFirstResponder()
                }
            }
        } else if textView.isFirstResponder && (isDisabled || didRequestBlur) {
            context.coordinator.performProgrammaticFocusChange {
                textView.resignFirstResponder()
            }
        }

        context.coordinator.lastSwiftUIFocusValue = requestedFocus
    }

    private func updateTextView(_ textView: UITextView, coordinator: Coordinator) {
        textView.font = font
        textView.typingAttributes[.font] = font
        textView.textContainerInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
#if os(iOS)
        if let submitTextView = textView as? SubmitAwareTextView {
            submitTextView.submitHandler = coordinator
            submitTextView.submitConfiguration = submitConfiguration
        }
#endif
        coordinator.synchronizeTextViewIfNeeded(with: text)
        coordinator.scheduleScrollSelectionToVisible(in: textView)
    }
}
#endif

#if os(macOS)
/// NSTextView that routes ⌘-Return (and ⌘-keypad-Enter) to a send handler
/// instead of inserting a newline. Plain Return keeps its default newline
/// behavior so multi-line prompts still work.
final class CommandReturnTextView: NSTextView {
    var onCommandReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturnKey = event.keyCode == 36 || event.keyCode == 76 // Return, keypad Enter
        if isReturnKey, event.modifierFlags.contains(.command), let onCommandReturn {
            onCommandReturn()
            return
        }
        super.keyDown(with: event)
    }
}

struct MacAutoScrollingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var focus: Binding<Bool>
    var isDisabled: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    var font: NSFont
    var onCommandReturn: (() -> Void)? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacAutoScrollingTextEditor
        weak var textView: NSTextView?
        private var isSyncingFromSwiftUI = false
        private var isPerformingProgrammaticFocusChange = false

        init(parent: MacAutoScrollingTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            setFocusState(true)
            if let textView {
                scrollSelectionToVisible(in: textView)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            setFocusState(false)
        }

        func textDidChange(_ notification: Notification) {
            guard !isSyncingFromSwiftUI, let textView else { return }
            let updatedText = textView.string
            if parent.text != updatedText {
                parent.text = updatedText
            }
            scrollSelectionToVisible(in: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            scrollSelectionToVisible(in: textView)
        }

        func synchronizeTextViewIfNeeded(with text: String) {
            guard let textView, textView.string != text else { return }
            let previousSelection = textView.selectedRange()
            isSyncingFromSwiftUI = true
            textView.string = text
            textView.font = parent.font
            let utf16Count = text.utf16.count
            let clampedLocation = min(previousSelection.location, utf16Count)
            let clampedLength = min(previousSelection.length, max(utf16Count - clampedLocation, 0))
            textView.setSelectedRange(NSRange(location: clampedLocation, length: clampedLength))
            isSyncingFromSwiftUI = false
            scrollSelectionToVisible(in: textView)
        }

        func performProgrammaticFocusChange(_ change: () -> Void) {
            isPerformingProgrammaticFocusChange = true
            change()
            isPerformingProgrammaticFocusChange = false
        }

        private func setFocusState(_ isFocused: Bool) {
            guard !isPerformingProgrammaticFocusChange else { return }
            guard parent.focus.wrappedValue != isFocused else { return }
            parent.focus.wrappedValue = isFocused
        }

        func scrollSelectionToVisible(in textView: NSTextView) {
            if let textContainer = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: textContainer)
            }
            let selectedRange = textView.selectedRange()
            let visibleRange: NSRange
            if textView.string.isEmpty {
                visibleRange = NSRange(location: 0, length: 0)
            } else if selectedRange.length == 0 {
                visibleRange = NSRange(location: max(selectedRange.location - 1, 0), length: 1)
            } else {
                visibleRange = selectedRange
            }
            textView.scrollRangeToVisible(visibleRange)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = CommandReturnTextView(frame: .zero, textContainer: textContainer)
        textView.onCommandReturn = onCommandReturn
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = NSColor.clear
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize.zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = NSView.AutoresizingMask([.width])
        textView.textContainerInset = NSSize.zero
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.allowsUndo = true
        textView.font = font
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        scrollView.documentView = textView

        context.coordinator.textView = textView
        updateTextView(textView, in: scrollView, coordinator: context.coordinator)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView ?? scrollView.documentView as? NSTextView else { return }
        context.coordinator.textView = textView
        (textView as? CommandReturnTextView)?.onCommandReturn = onCommandReturn
        updateTextView(textView, in: scrollView, coordinator: context.coordinator)

        let isFirstResponder = scrollView.window?.firstResponder === textView
        if focus.wrappedValue {
            if !isFirstResponder {
                context.coordinator.performProgrammaticFocusChange {
                    scrollView.window?.makeFirstResponder(textView)
                }
            }
        } else if isFirstResponder {
            context.coordinator.performProgrammaticFocusChange {
                scrollView.window?.makeFirstResponder(nil)
            }
        }
    }

    private func updateTextView(_ textView: NSTextView, in scrollView: NSScrollView, coordinator: Coordinator) {
        scrollView.contentInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        textView.font = font
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        coordinator.synchronizeTextViewIfNeeded(with: text)
        coordinator.scrollSelectionToVisible(in: textView)
    }
}
#endif
