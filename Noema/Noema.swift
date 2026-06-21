// Noema.swift
// Requires Swift Concurrency (iOS 17+).

import SwiftUI
import Foundation
import RelayKit
import Combine
import ImageIO
#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
import CoreSpotlight
import UniformTypeIdentifiers
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif
@_exported import Foundation

// Import RollingThought functionality through NoemaPackages
import NoemaPackages

// Removed LocalLLMClient MLX path in favor of mlx-swift/mlx-swift-examples integration
// Using our own llama.cpp implementation instead of LocalLLMClientLlama
#if canImport(MLX)
import MLX
#endif

struct NoemaSpotlightIndexRecord: Sendable, Hashable {
    let uniqueIdentifier: String
    let title: String
    let contentDescription: String
    let keywords: [String]
}

@MainActor
final class NoemaSpotlightIndexingService {
    static let shared = NoemaSpotlightIndexingService()

    private let chatDomain = "noema.chats"
    private let datasetDomain = "noema.datasets"
    private var chatTask: Task<Void, Never>?
    private var datasetTask: Task<Void, Never>?
    // Last successfully donated content per domain. Re-donating identical
    // records churns the OS-side donation translator (repeated
    // LNSpotlightCascadeTranslator failures in the log) for no gain.
    private var lastChatDigest: Int?
    private var lastDatasetDigest: Int?

    private init() {}

    func scheduleChatTitleIndex(records: [NoemaSpotlightIndexRecord]) {
        let digest = Self.digest(records)
        guard digest != lastChatDigest else { return }
        chatTask?.cancel()
        chatTask = Task { [chatDomain] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await Self.replaceDomain(chatDomain, records: records)
            await MainActor.run { Self.shared.lastChatDigest = digest }
        }
    }

    func scheduleDatasetNameIndex(records: [NoemaSpotlightIndexRecord]) {
        let digest = Self.digest(records)
        guard digest != lastDatasetDigest else { return }
        datasetTask?.cancel()
        datasetTask = Task { [datasetDomain] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            await Self.replaceDomain(datasetDomain, records: records)
            await MainActor.run { Self.shared.lastDatasetDigest = digest }
        }
    }

    private static func digest(_ records: [NoemaSpotlightIndexRecord]) -> Int {
        var hasher = Hasher()
        hasher.combine(records)
        return hasher.finalize()
    }

    func removeDatasetRecord(datasetID: String) {
        let identifier = Self.datasetIdentifier(for: datasetID)
        Task {
            await Self.deleteItems(identifiers: [identifier])
        }
    }

    static func chatIdentifier(for sessionID: UUID) -> String {
        "noema.chat.\(sessionID.uuidString)"
    }

    static func datasetIdentifier(for datasetID: String) -> String {
        "noema.dataset.\(datasetID)"
    }

    nonisolated private static func replaceDomain(_ domain: String, records: [NoemaSpotlightIndexRecord]) async {
#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
        guard CSSearchableIndex.isIndexingAvailable() else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
                let items = records.map { searchableItem(for: $0, domain: domain) }
                guard !items.isEmpty else {
                    continuation.resume()
                    return
                }
                CSSearchableIndex.default().indexSearchableItems(items) { _ in
                    continuation.resume()
                }
            }
        }
#else
        _ = domain
        _ = records
#endif
    }

    nonisolated private static func deleteItems(identifiers: [String]) async {
#if canImport(CoreSpotlight)
        guard CSSearchableIndex.isIndexingAvailable(), !identifiers.isEmpty else { return }
        await withCheckedContinuation { continuation in
            CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers) { _ in
                continuation.resume()
            }
        }
#else
        _ = identifiers
#endif
    }

#if canImport(CoreSpotlight) && canImport(UniformTypeIdentifiers)
    nonisolated private static func searchableItem(for record: NoemaSpotlightIndexRecord, domain: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = record.title
        attributes.contentDescription = record.contentDescription
        attributes.keywords = record.keywords
        return CSSearchableItem(
            uniqueIdentifier: record.uniqueIdentifier,
            domainIdentifier: domain,
            attributeSet: attributes
        )
    }
#endif
}

#if canImport(UIKit)
private extension UIImage {
    func resizedDown(to targetSize: CGSize) -> UIImage? {
        let maxW = max(1, Int(targetSize.width))
        let maxH = max(1, Int(targetSize.height))
        // If already smaller than target, skip expensive work
        if size.width <= CGFloat(maxW) && size.height <= CGFloat(maxH) { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: maxW, height: maxH), format: format)
        return renderer.image { _ in
            self.draw(in: CGRect(x: 0, y: 0, width: CGFloat(maxW), height: CGFloat(maxH)))
        }
    }
}
#endif

internal enum AttachmentImageNormalizer {
    static let maxLongEdgePixels = 1600
    static let suspiciousFileSizeBytes = 20 * 1024 * 1024
    private static let jpegCompressionQuality: CGFloat = 0.9

    struct Result {
        let data: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let originalPixelWidth: Int?
        let originalPixelHeight: Int?
        let wasClamped: Bool
        let suspiciouslyLargeSource: Bool
    }

    static func normalizeAttachmentData(_ data: Data, maxLongEdgePixels: Int = AttachmentImageNormalizer.maxLongEdgePixels) -> Result? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return normalize(source: source, fileBytes: data.count, maxLongEdgePixels: maxLongEdgePixels)
    }

    static func normalizeAttachmentImage(_ image: UIImage, maxLongEdgePixels: Int = AttachmentImageNormalizer.maxLongEdgePixels) -> Result? {
        if let data = image.jpegData(compressionQuality: 1.0),
           let normalized = normalizeAttachmentData(data, maxLongEdgePixels: maxLongEdgePixels) {
            return normalized
        }

        let fallbackWidth = max(1, Int(image.size.width.rounded()))
        let fallbackHeight = max(1, Int(image.size.height.rounded()))
        let longestEdge = max(fallbackWidth, fallbackHeight)
        let outputImage: UIImage
        if longestEdge > maxLongEdgePixels {
            let scale = CGFloat(maxLongEdgePixels) / CGFloat(longestEdge)
            let targetSize = CGSize(
                width: max(1, floor(CGFloat(fallbackWidth) * scale)),
                height: max(1, floor(CGFloat(fallbackHeight) * scale))
            )
            outputImage = image.resizedDown(to: targetSize) ?? image
        } else {
            outputImage = image
        }
        guard let jpeg = outputImage.jpegData(compressionQuality: jpegCompressionQuality) else { return nil }
        let outputWidth = max(1, Int(outputImage.size.width.rounded()))
        let outputHeight = max(1, Int(outputImage.size.height.rounded()))
        return Result(
            data: jpeg,
            pixelWidth: outputWidth,
            pixelHeight: outputHeight,
            originalPixelWidth: fallbackWidth,
            originalPixelHeight: fallbackHeight,
            wasClamped: outputWidth != fallbackWidth || outputHeight != fallbackHeight,
            suspiciouslyLargeSource: false
        )
    }

    static func metadata(forFileAt url: URL) -> (pixelWidth: Int, pixelHeight: Int, fileBytes: Int?)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }

        let width = intValue(properties[kCGImagePropertyPixelWidth]) ?? 0
        let height = intValue(properties[kCGImagePropertyPixelHeight]) ?? 0
        let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        return (width, height, fileBytes)
    }

    private static func normalize(source: CGImageSource, fileBytes: Int?, maxLongEdgePixels: Int) -> Result? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalPixelWidth = intValue(properties?[kCGImagePropertyPixelWidth])
        let originalPixelHeight = intValue(properties?[kCGImagePropertyPixelHeight])
        let longEdge = max(originalPixelWidth ?? 0, originalPixelHeight ?? 0)
        let suspiciouslyLargeSource = (fileBytes ?? 0) > suspiciousFileSizeBytes
        let outputMaxPixel = max(1, min(maxLongEdgePixels, longEdge > 0 ? longEdge : maxLongEdgePixels))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: outputMaxPixel,
            kCGImageSourceShouldCache: false
        ]
        guard let transformedImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let jpegData = encodeJPEG(from: transformedImage) else {
            return nil
        }

        let outputPixelWidth = transformedImage.width
        let outputPixelHeight = transformedImage.height
        let wasClamped = {
            guard let originalPixelWidth, let originalPixelHeight else { return false }
            return outputPixelWidth != originalPixelWidth || outputPixelHeight != originalPixelHeight
        }()

        return Result(
            data: jpegData,
            pixelWidth: outputPixelWidth,
            pixelHeight: outputPixelHeight,
            originalPixelWidth: originalPixelWidth,
            originalPixelHeight: originalPixelHeight,
            wasClamped: wasClamped,
            suspiciouslyLargeSource: suspiciouslyLargeSource
        )
    }

    private static func encodeJPEG(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegCompressionQuality
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let int as Int:
            return int
        default:
            return nil
        }
    }
}

private func currentDeviceWidth() -> CGFloat {
#if os(visionOS)
    return 1024
#elseif canImport(UIKit)
    return UIScreen.main.bounds.width
#elseif canImport(AppKit)
    return NSScreen.main?.frame.width ?? 1024
#else
    return 1024
#endif
}

let noemaToolAnchorToken = "<noema_tool_anchor/>"

enum StreamChunkMergeMode: Equatable {
    case unknown
    case delta
    case cumulative
}

struct StreamChunkMerger {
    private(set) var mode: StreamChunkMergeMode

    init(mode: StreamChunkMergeMode = .unknown) {
        self.mode = mode
    }

    @discardableResult
    mutating func append(_ newChunk: String, to existing: inout String) -> String {
        let delta = deltaToAppend(for: newChunk, existing: existing)
        existing += delta
        return delta
    }

    mutating func deltaToAppend(for newChunk: String, existing: String) -> String {
        guard !newChunk.isEmpty else { return "" }
        guard !existing.isEmpty else { return newChunk }

        switch mode {
        case .delta:
            return newChunk
        case .cumulative:
            return cumulativeDelta(newChunk: newChunk, existing: existing)
        case .unknown:
            if newChunk.count > existing.count, newChunk.hasPrefix(existing) {
                mode = .cumulative
                return String(newChunk.dropFirst(existing.count))
            }

            let overlap = suffixPrefixOverlapLength(existing: existing, incoming: newChunk)
            if overlap > 0, overlap < newChunk.count {
                return String(newChunk.dropFirst(overlap))
            }

            return newChunk
        }
    }

    private func cumulativeDelta(newChunk: String, existing: String) -> String {
        if newChunk == existing { return "" }
        if newChunk.count > existing.count, newChunk.hasPrefix(existing) {
            return String(newChunk.dropFirst(existing.count))
        }

        let overlap = suffixPrefixOverlapLength(existing: existing, incoming: newChunk)
        if overlap > 0 {
            return String(newChunk.dropFirst(overlap))
        }

        return newChunk
    }

    private func suffixPrefixOverlapLength(existing: String, incoming: String) -> Int {
        let maxOverlap = min(existing.count, incoming.count)
        guard maxOverlap > 0 else { return 0 }

        var overlap = maxOverlap
        while overlap > 0 {
            if existing.suffix(overlap) == incoming.prefix(overlap) {
                return overlap
            }
            overlap -= 1
        }

        return 0
    }
}

private enum ToolContinuationOutcome {
    case streamMore
    case restartWithTool(resultJSON: String)
    case finishWithVisibleText(String)
}

enum ChatMarkdownPlannerEntry: Equatable {
    case blank
    case thematicBreak
    case heading(level: Int, content: String)
    case bullet(marker: String, content: String)
    case mathBlock(String)
    case table
    case text(String)
}

enum ChatMarkdownRenderUnit: Equatable {
    case bulletBlock(String)
    case textMathBlock(String)
    case entryIndex(Int)
}

enum ChatMarkdownRenderPlanner {
    static func renderUnits(for entries: [ChatMarkdownPlannerEntry], isMacOS: Bool) -> [ChatMarkdownRenderUnit] {
        var units: [ChatMarkdownRenderUnit] = []
        var index = 0

        while index < entries.count {
            if isMacOS {
                switch entries[index] {
                case .table, .thematicBreak:
                    units.append(.entryIndex(index))
                    index += 1
                case .blank, .bullet, .mathBlock, .text, .heading:
                    // Headings fold into the same selectable block as the
                    // surrounding prose (rendered as "#"-prefixed paragraphs by
                    // MacSelectableMathText) so a drag-selection can sweep across
                    // them. Only tables and rules stay as standalone units.
                    var lines: [String] = []

                    macOSBlock: while index < entries.count {
                        switch entries[index] {
                        case .blank:
                            lines.append("")
                        case .bullet(let marker, let content):
                            lines.append("\(marker) \(content)")
                        case .mathBlock(let source):
                            lines.append(source)
                        case .text(let line):
                            lines.append(line)
                        case .heading(let level, let content):
                            // Surround with blank lines so the heading becomes
                            // its own paragraph (single newlines collapse to
                            // spaces in the renderer).
                            if !lines.isEmpty, lines.last != "" { lines.append("") }
                            lines.append(String(repeating: "#", count: level) + " " + content)
                            lines.append("")
                        case .table, .thematicBreak:
                            break macOSBlock
                        }
                        index += 1
                    }

                    units.append(.textMathBlock(lines.joined(separator: "\n")))
                }
            } else {
                switch entries[index] {
                case .text, .mathBlock, .blank:
                    var lines: [String] = []

                    textBlock: while index < entries.count {
                        switch entries[index] {
                        case .text(let line):
                            lines.append(line)
                        case .mathBlock(let source):
                            lines.append(source)
                        case .blank:
                            lines.append("")
                        case .heading, .table, .bullet, .thematicBreak:
                            break textBlock
                        }
                        index += 1
                    }

                    units.append(.textMathBlock(lines.joined(separator: "\n")))
                case .heading, .table, .thematicBreak:
                    units.append(.entryIndex(index))
                    index += 1
                case .bullet:
                    var lines: [String] = []

                    bulletBlock: while index < entries.count {
                        guard case .bullet(let marker, let content) = entries[index] else {
                            break bulletBlock
                        }
                        lines.append("\(marker) \(content)")
                        index += 1
                    }

                    units.append(.bulletBlock(lines.joined(separator: "\n\n")))
                }
            }
        }

        return units
    }
}

private typealias APILoopbackToolCall = ToolCall

private func appendingToolAnchor(to text: String) -> String {
    text + noemaToolAnchorToken
}

private func visibleAssistantText(from text: String) -> String {
    scrubVisibleToolArtifacts(from: text)
}

private func scrubVisibleToolArtifacts(from text: String) -> String {
    var output = text

    func findMatchingBrace(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
        guard text[startIndex] == "{" else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    func findMatchingBracket(in text: String, startingFrom startIndex: String.Index) -> String.Index? {
        guard text[startIndex] == "[" else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "[" {
                    depth += 1
                } else if char == "]" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    while let range = output.range(of: "<tool_call>") {
        if let end = output.range(of: "</tool_call>", range: range.upperBound..<output.endIndex) {
            output.removeSubrange(range.lowerBound..<end.upperBound)
        } else {
            output.removeSubrange(range.lowerBound..<output.endIndex)
        }
    }

    while let range = output.range(of: "TOOL_CALL:") {
        let after = output[range.upperBound...]
        if let nextBoundary = after.range(of: "TOOL_RESULT:")?.lowerBound
            ?? after.range(of: "<tool_response>")?.lowerBound
            ?? after.firstIndex(of: "\n") {
            output.removeSubrange(range.lowerBound..<nextBoundary)
        } else {
            output.removeSubrange(range.lowerBound..<output.endIndex)
        }
    }

    while let range = output.range(of: "<tool_response>") {
        if let end = output.range(of: "</tool_response>", range: range.upperBound..<output.endIndex) {
            output.removeSubrange(range.lowerBound..<end.upperBound)
        } else {
            output.removeSubrange(range.lowerBound..<output.endIndex)
        }
    }

    while let range = output.range(of: "TOOL_RESULT:") {
        let after = output[range.upperBound...]
        var removalEnd = output.endIndex
        if let firstNonWhitespace = after.firstIndex(where: { !$0.isWhitespace }) {
            if after[firstNonWhitespace] == "[",
               let close = findMatchingBracket(in: output, startingFrom: firstNonWhitespace) {
                removalEnd = output.index(after: close)
            } else if after[firstNonWhitespace] == "{",
                      let close = findMatchingBrace(in: output, startingFrom: firstNonWhitespace) {
                removalEnd = output.index(after: close)
            } else if let newline = after[firstNonWhitespace...].firstIndex(of: "\n") {
                removalEnd = newline
            }
        }
        output.removeSubrange(range.lowerBound..<removalEnd)
    }

    return output
}

@MainActor
private func performMediumImpact() {
#if os(iOS)
    Haptics.impact(.medium)
#endif
}

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

private final class MacChatScrollObserverView: NSView {
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

private struct MacChatScrollObserver: NSViewRepresentable {
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
                      replacementText replacementText: String) -> Bool {
#if os(iOS)
            guard let submitConfiguration = parent.submitConfiguration,
                  submitConfiguration.behavior == .returnKeySends,
                  replacementText == "\n" else {
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
private struct MacAutoScrollingTextEditor: NSViewRepresentable {
    @Binding var text: String
    var focus: Binding<Bool>
    var isDisabled: Bool
    var topInset: CGFloat
    var bottomInset: CGFloat
    var font: NSFont

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

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
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

// ---------------------------------------------------------------------------
// Temporary stubs for new SwiftUI modifiers used by iOS 26. These are no‑ops
// here so the project can compile on older toolchains.

enum TabBarMinimizeBehavior { case none, onScrollDown }
extension View {
    func tabBarMinimizeBehavior(_ behavior: TabBarMinimizeBehavior) -> some View { self }
    func tabViewBottomAccessory(alignment: Alignment = .center, @ViewBuilder content: () -> some View) -> some View { self }
}

enum ModelKind { case gemma, llama3, qwen, smol, lfm, mistral, phi, internlm, deepseek, yi, other
    static func detect(id: String) -> ModelKind {
        let s = id.lowercased()
        if s.contains("gemma") { return .gemma }
        if s.contains("llama-3") || s.contains("llama3") { return .llama3 }
        // Detect Liquid LFM separately (ChatML with <|startoftext|> prefix)
        if s.contains("lfm2") || s.contains("liquid") { return .lfm }
        // SmolLM models use ChatML with a default system prompt; detect separately
        if s.contains("smol") { return .smol }
        // Map specific families explicitly so we can build family-specific prompts
        if s.contains("internlm") { return .internlm }
        if s.contains("deepseek") { return .deepseek }
        if s.contains("yi") { return .yi }
        // Map other ChatML-adopting families to .qwen (ChatML): Qwen, MPT
        if s.contains("qwen") || s.contains("mpt") {
            return .qwen
        }
        // Llama 2 family uses [INST] with <<SYS>> inside first block
        if s.contains("llama-2") || s.contains("llama2") { return .mistral }
        if s.contains("mistral") || s.contains("mixtral") { return .mistral }
        if s.contains("phi-3") || s.contains("phi3") { return .phi }
        return .other
    }
}

enum RunPurpose { case chat, title }

// MARK: –– Model metadata ----------------------------------------------------
#if canImport(UIKit) || canImport(AppKit)
private enum ModelInfo {
    static let repoID   = "unsloth/Qwen3.5-2B-GGUF"
    static let fileName = "Qwen3.5-2B-Q3_K_M.gguf"

    /// Returns <Documents>/LocalLLMModels/qwen/Qwen3.5-2B-GGUF/.../Qwen3.5-2B-Q3_K_M.gguf
    static func sandboxURL() -> URL {
        var url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalLLMModels", isDirectory: true)
        for comp in repoID.split(separator: "/") {
            url.appendPathComponent(String(comp), isDirectory: true)
        }
        return url.appendingPathComponent(fileName)
    }
}


// MARK: –– One‑shot downloader ----------------------------------------------
@MainActor final class ModelDownloader: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)   // 0…1
        case finished
        case failed(String)
    }

    @Published var state: State = .idle
    @AppStorage("verboseLogging") private var verboseLogging = false

    /// Additional files some models may ship alongside the GGUF.
    /// These are optional so the downloader succeeds even if they are absent.
    private static let extraFiles: [String] = []
    private var fractions: [Double] = []

    init() {
        let modelOK  = FileManager.default.fileExists(atPath: ModelInfo.sandboxURL().path)
        let sideOK   = Self.extraFiles.allSatisfy { name in
            FileManager.default.fileExists(atPath: ModelInfo.sandboxURL()
                .deletingLastPathComponent()
                .appendingPathComponent(name).path)
        }
        state = (modelOK && sideOK) ? .finished : .idle
        if verboseLogging { print("[Downloader] init → state = \(state)") }
        // Startup diagnostics for Metal kernels
        if verboseLogging {
            if let metallib = Bundle.main.path(forResource: "default", ofType: "metallib") {
                print("[Startup] default.metallib found: \(metallib)")
            } else {
                print("[Startup] Warning: default.metallib not found. GPU will be disabled and CPU fallback used.")
            }
        }
    }

    func start() {
        guard state == .idle || state.isFailed else { return }
        if verboseLogging { print("[Downloader] starting…") }
        state = .downloading(0)

        let llmDir   = ModelInfo.sandboxURL().deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: llmDir, withIntermediateDirectories: true)
        } catch {
            state = .failed("mkdir: \(error.localizedDescription)")
            return
        }

        var items: [(repo: String, file: String, dest: URL)] = []
        items.append((ModelInfo.repoID, ModelInfo.fileName, llmDir.appendingPathComponent(ModelInfo.fileName)))
        items += Self.extraFiles.map { (ModelInfo.repoID, $0, llmDir.appendingPathComponent($0)) }

        let total = Double(items.count)
        fractions = Array(repeating: 0.0, count: items.count)

        Task {
            for (idx, item) in items.enumerated() {
                // '?download=1' ensures Hugging Face serves the raw file directly
                let remote  = URL(string: "https://huggingface.co/\(item.repo)/resolve/main/\(item.file)?download=1")!
                let dest    = item.dest

                if verboseLogging { print("[Downloader] ▶︎ \(item.file)") }
                do {
                    try await BackgroundDownloadManager.shared.download(from: remote, to: dest) { part in
                        Task { @MainActor in
                            self.fractions[idx] = part
                            if self.state.isDownloading {
                                self.state = .downloading(self.fractions.reduce(0, +) / total)
                            }
                        }
                    }
                    await MainActor.run {
                        if verboseLogging { print("[Downloader] ✓ \(item.file)") }
                    }
                } catch {
                    await MainActor.run {
                        self.state = .failed(error.localizedDescription)
                        if verboseLogging { print("[Downloader] ❌ \(item.file): \(error.localizedDescription)") }
                    }
                    return
                }
            }

            await MainActor.run {
                self.state = .finished
                if verboseLogging { print("[Downloader] all files done ✅") }
            }
        }
    }
}

private extension ModelDownloader.State {
    var isFailed: Bool       { if case .failed = self { true } else { false } }
    var isDownloading: Bool  { if case .downloading = self { true } else { false } }
}
#endif

// MARK: –– FileManager helpers ----------------------------------------------
extension FileManager {
    func removeItemIfExists(at url: URL) throws {
        if fileExists(atPath: url.path) { try removeItem(at: url) }
    }
    @discardableResult
    func moveItemReplacing(at dest: URL, from src: URL) throws -> URL {
        try removeItemIfExists(at: dest)
        try moveItem(at: src, to: dest)
        return dest
    }
}

// MARK: –– Download screen ---------------------------------------------------
#if canImport(UIKit) || os(macOS)
struct DownloadView: View {
    @ObservedObject var vm: ModelDownloader

    var body: some View {
        VStack(spacing: 20) {
            Text(LocalizedStringKey("First‑time setup: download the Qwen 3.5 2B Q3_K_M model and embeddings.\nWi‑Fi recommended."))
                .multilineTextAlignment(.center)

            switch vm.state {
            case .idle:
                Button(LocalizedStringKey("Download Models")) { vm.start() }
                    .buttonStyle(.borderedProminent)

            case .downloading(let p):
                VStack(spacing: 12) {
                    Text(LocalizedStringKey("Downloading…"))
                        .font(.headline)
                    ModernDownloadProgressView(progress: p, speed: nil)
                }

            case .failed(let msg):
                VStack(spacing: 12) {
                    Text("⚠️ " + msg).font(.caption)
                    Button(LocalizedStringKey("Retry")) { vm.start() }
                }

            case .finished:
                ProgressView().progressViewStyle(.circular)
                Text(LocalizedStringKey("Preparing…")).font(.caption)
            }
        }
        .padding()
    }
}

// MARK: –– Chat view‑model ---------------------------------------------------
// Helper utilities for MLX repo inference and tokenizer fetching
@MainActor
private func inferRepoID(from directory: URL) -> String? {
    // Prefer explicit repo.txt if present
    let explicit = directory.appendingPathComponent("repo.txt")
    if let data = try? Data(contentsOf: explicit), let s = String(data: data, encoding: .utf8) {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
    }
    // Typical layout: .../LocalLLMModels/<owner>/<repo>
    let owner = directory.deletingLastPathComponent().lastPathComponent
    let repo  = directory.lastPathComponent
    if !owner.isEmpty, owner != "LocalLLMModels" { return owner + "/" + repo }
    // Legacy single-component folder names
    if repo.contains("/") { return repo }
    if repo.contains("_") { return repo.replacingOccurrences(of: "_", with: "/") }
    return repo
}

@MainActor
private func fetchTokenizer(into dir: URL, repoID: String) async {
    let defaults = UserDefaults.standard
    let token = defaults.string(forKey: "huggingFaceToken")
    func request(_ url: URL, accept: String) async throws -> Data? {
        if NetworkKillSwitch.isEnabled { throw URLError(.notConnectedToInternet) }
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let t = token, !t.isEmpty { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        NetworkKillSwitch.track(session: URLSession.shared)
        let (data, resp) = try await URLSession.shared.data(for: HFEndpoint.rewrite(req))
        if let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) { return data }
        return nil
    }
    func isLFSPointerData(_ data: Data) -> Bool {
        if data.count > 4096 { return false }
        guard let s = String(data: data, encoding: .utf8) else { return false }
        let lower = s.lowercased()
        return lower.contains("git-lfs") || lower.contains("oid sha256:")
    }
    // Try to derive tokenizer path from local config.json if it references a subpath
    if let cfgData = try? Data(contentsOf: dir.appendingPathComponent("config.json")),
       let cfg = try? JSONSerialization.jsonObject(with: cfgData) as? [String: Any] {
        let keys = ["tokenizer_file", "tokenizer_json", "tokenizer", "tokenizer_path"]
        for k in keys {
            if let rel = cfg[k] as? String, rel.lowercased().contains("tokenizer") {
                let candidates = [
                    URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(rel)?download=1"),
                    URL(string: "https://huggingface.co/\(repoID)/raw/main/\(rel)")
                ].compactMap { $0 }
                for u in candidates {
                    if let data = try? await request(u, accept: "application/json"), data.count > 0, !isLFSPointerData(data) {
                        try? data.write(to: dir.appendingPathComponent("tokenizer.json"))
                        return
                    }
                }
            }
        }
    }
    // Try tokenizer.json via resolve first (works with LFS), then raw as fallback
    if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/resolve/main/tokenizer.json?download=1")!, accept: "application/json"), data.count > 0, !isLFSPointerData(data) {
        try? data.write(to: dir.appendingPathComponent("tokenizer.json"))
        return
    }
    if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/raw/main/tokenizer.json")!, accept: "application/json"), data.count > 0, !isLFSPointerData(data) {
        try? data.write(to: dir.appendingPathComponent("tokenizer.json"))
        return
    }
    // Try known SentencePiece names (prefer resolve first)
    for name in ["tokenizer.model", "spiece.model", "sentencepiece.bpe.model"] {
        if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(name)?download=1")!, accept: "application/octet-stream"), data.count > 0 {
            try? data.write(to: dir.appendingPathComponent(name))
            return
        }
        if let data = try? await request(URL(string: "https://huggingface.co/\(repoID)/raw/main/\(name)")!, accept: "application/octet-stream"), data.count > 0 {
            try? data.write(to: dir.appendingPathComponent(name))
            return
        }
    }
}

@MainActor final class AppModelManager: ObservableObject {
    // Thread-safe store (internally synchronized) is safe to access off the main actor.
    private nonisolated let store: InstalledModelsStore
    @Published var downloadedModels: [LocalModel] = []
    @Published var hiddenModels: [LocalModel] = []
    @Published var loadedModel: LocalModel?
    @Published var lastUsedModel: LocalModel?
    @Published var modelSettings: [String: ModelSettings] = [:]
    @Published var downloadedDatasets: [LocalDataset] = []
    @Published var remoteBackends: [RemoteBackend] = []
    @Published var remoteBackendsFetching: Set<RemoteBackend.ID> = []
    @Published var activeRemoteSession: ActiveRemoteSession?
    @Published var activeLMStudioRemoteDownloadTargetID: RemoteBackend.ID?
    @Published var activeDataset: LocalDataset?
    @Published var loadingModelName: String?  // Track model name during loading
    private var favouritePaths: [String] = []
    private static let favouriteLimit = 3
    fileprivate var datasetManager: DatasetManager?
    private var cancellables: Set<AnyCancellable> = []
    var activeRelayLANRefreshes: Set<RemoteBackend.ID> = []
    var relayLANRefreshTimestamps: [RemoteBackend.ID: Date] = [:]
    // Track one-time early LAN health probes per backend so we don't spam.
    var lanInitialProbePerformed: Set<RemoteBackend.ID> = []
    private static let remoteModelSettingsStorageKey = "remoteModelSettings.v1"
    private static let openRouterFavoriteModelsStorageKey = "openRouterFavoriteModels.v1"
    private var remoteModelSettingsByKey: [String: ModelSettings] = [:]
    @Published private var openRouterFavoriteModelKeys: Set<String> = []

    init(store: InstalledModelsStore = InstalledModelsStore()) {
        self.store = store
        store.migrateLegacySLMEntries()
        store.migratePaths()
        store.migrateShardedGGUFEntries()
        store.rehomeIfMissing()
        Self.syncBuiltInAFMModel(in: store, supported: AppleFoundationModelAvailability.isSupportedDevice)
        if let fav = UserDefaults.standard.array(forKey: "favouriteModels") as? [String] {
            favouritePaths = Array(fav.prefix(Self.favouriteLimit))
            if favouritePaths.count != fav.count {
                UserDefaults.standard.set(favouritePaths, forKey: "favouriteModels")
            }
        }
        var installed = LocalModel.loadInstalled(store: store)
            .removingDuplicateURLs()
        let partitionedInstalled = partitionHiddenModels(installed)
        pruneFavouritePaths(against: partitionedInstalled.visible)
        installed = installed.map { model in
            var m = model
            m.isFavourite = favouritePaths.contains(m.url.path)
            return m
        }
        let partitionedFavorites = partitionHiddenModels(installed)
        downloadedModels = partitionedFavorites.visible
        hiddenModels = partitionedFavorites.hidden
        invalidateLocalGGUFMoeInfoIfNeeded()
        hydrateMoEInfoFromCache()
        updateLastUsedModel()
        // Merge durable and legacy path-based settings into the in-memory path-keyed map.
        let legacyModelSettings: [String: ModelSettings] = {
            guard let data = UserDefaults.standard.data(forKey: "modelSettings"),
                  let decoded = try? JSONDecoder().decode([String: ModelSettings].self, from: data) else {
                return [:]
            }
            return decoded
        }()
        modelSettings = ModelSettingsStore.resolveLocalSettings(
            installedModels: store.all(),
            legacySettingsByPath: legacyModelSettings
        )
        remoteBackends = RemoteBackendsStore.load()
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let data = UserDefaults.standard.data(forKey: Self.remoteModelSettingsStorageKey),
           let decoded = ModelSettingsPersistenceDecoder.decodeRemoteSettingsMap(from: data) {
            remoteModelSettingsByKey = decoded.map
            if decoded.droppedInvalidEntries {
                persistRemoteSettings()
            }
        }
        if let favorites = UserDefaults.standard.array(forKey: Self.openRouterFavoriteModelsStorageKey) as? [String] {
            openRouterFavoriteModelKeys = Set(favorites)
        }
        scanLayersIfNeeded()
        scanMoEInfoIfNeeded()
    }

    nonisolated private static func syncBuiltInAFMModel(in store: InstalledModelsStore, supported: Bool) {
        let modelID = AppleFoundationModelRegistry.modelID
        let quantLabel = AppleFoundationModelRegistry.quantLabel

        if !supported {
            store.remove(modelID: modelID, quantLabel: quantLabel)
            return
        }

        let fm = FileManager.default
        let base = InstalledModelsStore.baseDir(for: .afm, modelID: modelID)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        let canonical = InstalledModelsStore.canonicalURL(for: base, format: .afm)

        let existing = store.all().filter { $0.modelID == modelID && $0.quantLabel == quantLabel }
        if existing.count > 1 {
            store.remove(modelID: modelID, quantLabel: quantLabel)
        }
        let existingModel = existing.count == 1 ? existing.first : nil

        let installed = InstalledModel(
            id: existingModel?.id ?? UUID(),
            modelID: modelID,
            quantLabel: quantLabel,
            parameterCountLabel: AppleFoundationModelRegistry.parameterCountLabel,
            url: canonical,
            format: .afm,
            sizeBytes: 0,
            lastUsed: existingModel?.lastUsed,
            installDate: existingModel?.installDate ?? Date(),
            checksum: existingModel?.checksum,
            isFavourite: existingModel?.isFavourite ?? false,
            totalLayers: 0,
            isMultimodal: false,
            isToolCapable: true,
            moeInfo: nil,
            etBackend: nil
        )
        store.upsert(installed)
    }

    var activeLMStudioRemoteDownloadTargetBackend: RemoteBackend? {
        guard let targetID = activeLMStudioRemoteDownloadTargetID,
              let backend = remoteBackends.first(where: { $0.id == targetID }),
              backend.endpointType == .lmStudio else {
            return nil
        }
        return backend
    }

    func remoteSettingsKey(backendID: RemoteBackend.ID, modelID: String) -> String {
        let normalizedModelID = modelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(backendID.uuidString)|\(normalizedModelID)"
    }

    func clampedRemoteSettings(_ settings: ModelSettings, maxContextLength: Int?) -> ModelSettings {
        func quantize(_ value: Double, step: Double) -> Double {
            guard step > 0 else { return value }
            return (value / step).rounded() * step
        }

        var clamped = settings
        clamped.contextLength = max(1, clamped.contextLength.rounded())
        if let maxContextLength, maxContextLength > 0 {
            clamped.contextLength = min(clamped.contextLength, Double(maxContextLength))
        }
        clamped.topP = quantize(max(0, min(1, clamped.topP)), step: 0.01)
        clamped.topK = max(1, clamped.topK)
        clamped.minP = quantize(max(0, min(1, clamped.minP)), step: 0.01)
        clamped.temperature = quantize(max(0, min(2, clamped.temperature)), step: 0.01)
        let repeatPenalty = Double(max(0.1, min(3.0, clamped.repetitionPenalty)))
        clamped.repetitionPenalty = Float(quantize(repeatPenalty, step: 0.01))
        return clamped.normalizedSystemPromptSettings()
    }

    func remoteSettings(for backendID: RemoteBackend.ID, model: RemoteModel) -> ModelSettings {
        let key = remoteSettingsKey(backendID: backendID, modelID: model.id)
        if let existing = remoteModelSettingsByKey[key] {
            let clamped = clampedRemoteSettings(existing, maxContextLength: model.maxContextLength)
            if clamped != existing {
                remoteModelSettingsByKey[key] = clamped
                persistRemoteSettings()
            }
            return clamped
        }
        let defaults = ModelSettings.default(for: model.compatibilityFormat ?? .gguf)
        return clampedRemoteSettings(defaults, maxContextLength: model.maxContextLength)
    }

    func hasSavedRemoteSettings(for backendID: RemoteBackend.ID, modelID: String) -> Bool {
        remoteModelSettingsByKey[remoteSettingsKey(backendID: backendID, modelID: modelID)] != nil
    }

    func saveRemoteSettings(_ settings: ModelSettings, for backendID: RemoteBackend.ID, model: RemoteModel) {
        let key = remoteSettingsKey(backendID: backendID, modelID: model.id)
        remoteModelSettingsByKey[key] = clampedRemoteSettings(settings, maxContextLength: model.maxContextLength)
        persistRemoteSettings()
    }

    func clearRemoteSettings(for backendID: RemoteBackend.ID) {
        let prefix = "\(backendID.uuidString)|"
        let previousCount = remoteModelSettingsByKey.count
        remoteModelSettingsByKey = remoteModelSettingsByKey.filter { !$0.key.hasPrefix(prefix) }
        if remoteModelSettingsByKey.count != previousCount {
            persistRemoteSettings()
        }
    }

    private func persistRemoteSettings() {
        guard let data = try? JSONEncoder().encode(remoteModelSettingsByKey) else { return }
        UserDefaults.standard.set(data, forKey: Self.remoteModelSettingsStorageKey)
    }

    func isOpenRouterFavorite(backendID: RemoteBackend.ID, modelID: String) -> Bool {
        openRouterFavoriteModelKeys.contains(remoteSettingsKey(backendID: backendID, modelID: modelID))
    }

    @discardableResult
    func setOpenRouterFavorite(_ isFavorite: Bool, backendID: RemoteBackend.ID, modelID: String) -> Bool {
        let key = remoteSettingsKey(backendID: backendID, modelID: modelID)
        let changed: Bool
        if isFavorite {
            changed = openRouterFavoriteModelKeys.insert(key).inserted
        } else {
            changed = openRouterFavoriteModelKeys.remove(key) != nil
        }
        if changed {
            persistOpenRouterFavorites()
        }
        return changed
    }

    @discardableResult
    func toggleOpenRouterFavorite(backendID: RemoteBackend.ID, modelID: String) -> Bool {
        let newValue = !isOpenRouterFavorite(backendID: backendID, modelID: modelID)
        _ = setOpenRouterFavorite(newValue, backendID: backendID, modelID: modelID)
        return newValue
    }

    func openRouterFavoriteModelIDs(for backendID: RemoteBackend.ID) -> Set<String> {
        let prefix = "\(backendID.uuidString)|"
        return Set(
            openRouterFavoriteModelKeys.compactMap { key in
                guard key.hasPrefix(prefix) else { return nil }
                return String(key.dropFirst(prefix.count))
            }
        )
    }

    func clearOpenRouterFavorites(for backendID: RemoteBackend.ID) {
        let prefix = "\(backendID.uuidString)|"
        let filtered = openRouterFavoriteModelKeys.filter { !$0.hasPrefix(prefix) }
        guard filtered.count != openRouterFavoriteModelKeys.count else { return }
        openRouterFavoriteModelKeys = filtered
        persistOpenRouterFavorites()
    }

    private func persistOpenRouterFavorites() {
        UserDefaults.standard.set(Array(openRouterFavoriteModelKeys).sorted(), forKey: Self.openRouterFavoriteModelsStorageKey)
    }

    func refresh() {
        store.reload()
        store.migrateLegacySLMEntries()
        store.migratePaths()
        store.migrateShardedGGUFEntries()
        store.rehomeIfMissing()
        Self.syncBuiltInAFMModel(in: store, supported: AppleFoundationModelAvailability.isSupportedDevice)
        var installed = LocalModel.loadInstalled(store: store)
            .removingDuplicateURLs()
        let partitionedInstalled = partitionHiddenModels(installed)
        pruneFavouritePaths(against: partitionedInstalled.visible)
        installed = installed.map { model in
            var m = model
            m.isFavourite = favouritePaths.contains(m.url.path)
            return m
        }
        let partitionedFavorites = partitionHiddenModels(installed)
        downloadedModels = partitionedFavorites.visible
        hiddenModels = partitionedFavorites.hidden
        invalidateLocalGGUFMoeInfoIfNeeded()
        hydrateMoEInfoFromCache()
        updateLastUsedModel()
        scanLayersIfNeeded()
        scanMoEInfoIfNeeded()
        scanCapabilitiesIfNeeded()
        datasetManager?.reloadFromDisk()
    }

    // MARK: - Async Refresh (Performance Optimized)

    private var lastRefreshTime: Date = .distantPast
    private static let refreshDebounceInterval: TimeInterval = 0.3

    /// Async version of refresh that moves heavy I/O off the main thread.
    /// Includes debouncing to prevent redundant refreshes when rapidly switching tabs.
    func refreshAsync() async {
        let now = Date()
        guard now.timeIntervalSince(lastRefreshTime) > Self.refreshDebounceInterval else { return }
        lastRefreshTime = now

        // Capture store reference for use in detached task
        let store = self.store
        let currentFavouritePaths = self.favouritePaths
        let afmSupported = AppleFoundationModelAvailability.isSupportedDevice

        // Perform heavy I/O operations off the main actor
        let installed = await Task.detached(priority: .userInitiated) {
            store.reload()
            store.migrateLegacySLMEntries()
            store.migratePaths()
            store.migrateShardedGGUFEntries()
            store.rehomeIfMissing()
            Self.syncBuiltInAFMModel(in: store, supported: afmSupported)
            var models = LocalModel.loadInstalled(store: store)
                .removingDuplicateURLs()
            models = models.map { model in
                var m = model
                m.isFavourite = currentFavouritePaths.contains(m.url.path)
                return m
            }
            return models
        }.value

        // Update UI on main actor
        let partitionedInstalled = partitionHiddenModels(installed)
        pruneFavouritePaths(against: partitionedInstalled.visible)
        let refreshedInstalled = installed.map { model in
            var refreshed = model
            refreshed.isFavourite = favouritePaths.contains(model.url.path)
            return refreshed
        }
        let partitionedFavorites = partitionHiddenModels(refreshedInstalled)
        downloadedModels = partitionedFavorites.visible
        hiddenModels = partitionedFavorites.hidden
        hydrateMoEInfoFromCache()
        updateLastUsedModel()

        // These already use Task.detached internally
        scanLayersIfNeeded()
        scanMoEInfoIfNeeded()
        scanCapabilitiesIfNeeded()
    }

    private func updateLastUsedModel() {
        lastUsedModel = downloadedModels
            .filter { $0.lastUsedDate != nil }
            .sorted { $0.lastUsedDate! > $1.lastUsedDate! }
            .first
    }

    private func partitionHiddenModels(_ models: [LocalModel]) -> (visible: [LocalModel], hidden: [LocalModel]) {
        let hiddenKeys = HiddenModelsStore.load()
        let partitioned = models.reduce(into: (visible: [LocalModel](), hidden: [LocalModel]())) { partialResult, model in
            let key = HiddenModelsStore.key(modelID: model.modelID, quantLabel: model.quant)
            if hiddenKeys.contains(key) {
                partialResult.hidden.append(model)
            } else {
                partialResult.visible.append(model)
            }
        }
        return partitioned
    }

    func isHidden(_ model: LocalModel) -> Bool {
        HiddenModelsStore.isHidden(modelID: model.modelID, quantLabel: model.quant)
    }

    func hide(_ model: LocalModel) {
        HiddenModelsStore.hide(modelID: model.modelID, quantLabel: model.quant)
        refresh()
    }

    func unhide(modelID: String, quantLabel: String) {
        HiddenModelsStore.unhide(modelID: modelID, quantLabel: quantLabel)
        refresh()
    }

    /// Set the given model as recently used and mark it as loaded.
    func markModelUsed(_ model: LocalModel) {
        var m = model
        m.lastUsedDate = Date()
        store.updateLastUsed(modelID: m.modelID, quantLabel: m.quant, date: m.lastUsedDate!)
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx] = m
        } else {
            downloadedModels.append(m)
        }
        loadedModel = m
        lastUsedModel = m
    }
    
    func setCapabilities(modelID: String, quant: String, isMultimodal: Bool, isToolCapable: Bool) {
        store.updateCapabilities(modelID: modelID, quantLabel: quant, isMultimodal: isMultimodal, isToolCapable: isToolCapable)
        refresh()
    }

    func bind(datasetManager: DatasetManager) {
        guard self.datasetManager !== datasetManager else { return }
        self.datasetManager = datasetManager
        datasetManager.$datasets
            .receive(on: RunLoop.main)
            .sink { [weak self] ds in
                // Publish changes on the next runloop to avoid nested view-update warnings
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.downloadedDatasets = ds
                    let selectedID = UserDefaults.standard.string(forKey: "selectedDatasetID") ?? ""
                    if selectedID.isEmpty {
                        self.activeDataset = nil
                        return
                    }

                    if let selected = ds.first(where: { $0.datasetID == selectedID }) {
                        // Keep the active dataset object fresh (e.g., when indexing flips isIndexed).
                        self.activeDataset = selected
                    } else {
                        // Selected dataset no longer exists on disk.
                        self.activeDataset = nil
                        UserDefaults.standard.set("", forKey: "selectedDatasetID")
                    }
                }
            }
            .store(in: &cancellables)
    }

    func setActiveDataset(_ ds: LocalDataset?) {
        datasetManager?.select(ds)
        // Defer publishing selection to avoid modifying state during view updates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeDataset = ds
            let id = ds?.datasetID ?? ""
            UserDefaults.standard.set(id, forKey: "selectedDatasetID")
        }
    }

    /// Adds a newly installed model to the store and refreshes the list.
    func install(_ model: InstalledModel) {
        store.add(model)
        refresh()
    }

    func installedModel(matching model: LocalModel) -> InstalledModel? {
        store.all().first { installed in
            installed.modelID == model.modelID
            && installed.quantLabel == model.quant
            && InstalledModelsStore.canonicalURL(for: installed.url, format: installed.format).path == InstalledModelsStore.canonicalURL(for: model.url, format: model.format).path
        } ?? store.all().first { installed in
            installed.modelID == model.modelID
            && installed.quantLabel == model.quant
            && installed.format == model.format
        }
    }

    func delete(_ model: LocalModel) {
        if model.format == .afm {
            return
        }
        let canonicalURL = InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
#if canImport(CoreML) && (os(iOS) || os(visionOS))
        if model.format == .ane {
            try? ANEModelResolver.removeCompiledCache(for: model.url)
        }
#endif
        let installedBeforeDelete = store.all()
        _ = ModelStorageCleanup.deleteModelFiles(for: model, installedModels: installedBeforeDelete)
        store.remove(modelID: model.modelID, quantLabel: model.quant)
        ModelSettingsStore.remove(modelID: model.modelID, quantLabel: model.quant, canonicalPath: canonicalURL.path)
        modelSettings.removeValue(forKey: canonicalURL.path)
        modelSettings.removeValue(forKey: model.url.path)
        HiddenModelsStore.unhide(modelID: model.modelID, quantLabel: model.quant)
        ModelStorageCleanup.clearPassExtractionSelectionIfNeeded(deletedModel: model)
        Task {
            await MoEDetectionStore.shared.remove(modelID: model.modelID, quantLabel: model.quant)
        }
        refresh()
        if loadedModel?.id == model.id { loadedModel = nil }
        if lastUsedModel?.id == model.id { lastUsedModel = nil }
        StartupPreferencesStore.clearLocalPath(model.url.path)
        StartupPreferencesStore.clearLocalPath(canonicalURL.path)
    }

    private func resolvedSettings(for model: LocalModel,
                                  persistIfMissing: Bool,
                                  deferPublishedWrites: Bool = false) -> ModelSettings {
        if var existing = modelSettings[model.url.path] {
            let stored = existing
            existing = normalizeLocalSettings(existing, for: model)
            var shouldPersistNormalized = existing != stored
            if model.format == .ane,
               (existing.tokenizerPath ?? "").isEmpty,
               let tokenizerPath = ModelSettings.resolvedTokenizerPath(for: model) {
                existing.tokenizerPath = tokenizerPath
                shouldPersistNormalized = true
            }
            if persistIfMissing && shouldPersistNormalized {
                if deferPublishedWrites {
                    scheduleSettingsPersistence(existing, for: model)
                } else {
                    updateSettings(existing, for: model)
                }
            }
            return existing
        }
        var s = ModelSettings.fromConfig(for: model)
        // Default to sentinel (-1) meaning "all layers" for GGUF unless already set elsewhere.
        if model.format == .gguf && s.gpuLayers == 0 {
            s.gpuLayers = -1
        }
        if model.format == .et {
            let storedBackend = store
                .all()
                .first(where: { $0.modelID == model.modelID && $0.quantLabel == model.quant })?
                .etBackend
            s.etBackend = ETBackendDetector.effectiveBackend(userSelected: storedBackend ?? s.etBackend, detected: nil)
        }
        s = normalizeLocalSettings(s, for: model)
        if persistIfMissing {
            if deferPublishedWrites {
                scheduleSettingsCaching(s, for: model)
            } else {
                modelSettings[model.url.path] = s
            }
        }
        return s
    }

    private func scheduleSettingsCaching(_ settings: ModelSettings, for model: LocalModel) {
        let path = model.url.path
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.modelSettings[path] == nil else { return }
            self.modelSettings[path] = settings
        }
    }

    private func scheduleSettingsPersistence(_ settings: ModelSettings, for model: LocalModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let latest = self.modelSettings[model.url.path]
            let normalizedLatest = latest.map { self.normalizeLocalSettings($0, for: model) }
            guard normalizedLatest != settings else { return }
            self.updateSettings(settings, for: model)
        }
    }

    func settings(for model: LocalModel) -> ModelSettings {
        resolvedSettings(for: model, persistIfMissing: true, deferPublishedWrites: true)
    }

    func displaySettings(for model: LocalModel) -> ModelSettings {
        resolvedSettings(for: model, persistIfMissing: false)
    }

    func normalizeLocalSettings(_ settings: ModelSettings, for model: LocalModel) -> ModelSettings {
        settings.normalizedForLocalModel(model)
    }

    func updateSettings(_ settings: ModelSettings, for model: LocalModel) {
        let normalized = normalizeLocalSettings(settings, for: model)
        modelSettings[model.url.path] = normalized
        // Persist to legacy store for backwards compatibility
        if let data = try? JSONEncoder().encode(modelSettings) {
            UserDefaults.standard.set(data, forKey: "modelSettings")
        }
        // Persist to durable store using the current canonical model path.
        ModelSettingsStore.save(settings: normalized, for: model)
        if model.format == .et {
            store.updateETBackend(modelID: model.modelID, quantLabel: model.quant, backend: normalized.etBackend)
        }
    }

    func updateAlias(_ alias: String?, for model: LocalModel) {
        store.updateAlias(modelID: model.modelID, quantLabel: model.quant, alias: alias)
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAlias = trimmed?.isEmpty == false ? trimmed : nil

        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx].alias = normalizedAlias
        }
        if let idx = hiddenModels.firstIndex(where: { $0.id == model.id }) {
            hiddenModels[idx].alias = normalizedAlias
        }
        if loadedModel?.id == model.id {
            loadedModel?.alias = normalizedAlias
        }
        if lastUsedModel?.id == model.id {
            lastUsedModel?.alias = normalizedAlias
        }
    }

    var favouriteCount: Int { favouritePaths.count }
    var favouriteCapacity: Int { Self.favouriteLimit }

    private func persistFavourites() {
        if favouritePaths.count > Self.favouriteLimit {
            favouritePaths = Array(favouritePaths.prefix(Self.favouriteLimit))
        }
        UserDefaults.standard.set(favouritePaths, forKey: "favouriteModels")
    }

    @discardableResult
    private func pruneFavouritePaths(against models: [LocalModel]) -> Bool {
        let validPaths = Set(models.map { $0.url.path })
        let filtered = favouritePaths.filter { validPaths.contains($0) }
        guard filtered != favouritePaths else { return false }
        favouritePaths = filtered
        persistFavourites()
        return true
    }

    func canFavourite(_ model: LocalModel) -> Bool {
        _ = pruneFavouritePaths(against: downloadedModels)
        return favouritePaths.contains(model.url.path) || favouritePaths.count < Self.favouriteLimit
    }

    @discardableResult
    func setFavourite(_ model: LocalModel, isFavourite desired: Bool) -> Bool {
        _ = pruneFavouritePaths(against: downloadedModels)
        let path = model.url.path
        if desired {
            if !favouritePaths.contains(path) {
                guard favouritePaths.count < Self.favouriteLimit else { return false }
                favouritePaths.append(path)
            }
        } else {
            favouritePaths.removeAll { $0 == path }
        }
        persistFavourites()

        let updatedValue = favouritePaths.contains(path)
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            var models = downloadedModels
            models[idx].isFavourite = updatedValue
            downloadedModels = models
        }
        store.updateFavorite(modelID: model.modelID, quantLabel: model.quant, fav: updatedValue)
        return true
    }

    @discardableResult
    func toggleFavourite(_ model: LocalModel) -> Bool {
        _ = pruneFavouritePaths(against: downloadedModels)
        let shouldFavourite = !favouritePaths.contains(model.url.path)
        if shouldFavourite && favouritePaths.count >= Self.favouriteLimit {
            return false
        }
        return setFavourite(model, isFavourite: shouldFavourite)
    }

    func favouriteModels(limit: Int = AppModelManager.favouriteLimit) -> [LocalModel] {
        let favourites = downloadedModels
            .filter { favouritePaths.contains($0.url.path) }
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUsedDate ?? lhs.downloadDate
                let rhsDate = rhs.lastUsedDate ?? rhs.downloadDate
                return lhsDate > rhsDate
            }
        return limit > 0 ? Array(favourites.prefix(limit)) : favourites
    }

    func recentModels(limit: Int = 3, excludingIDs: Set<String> = []) -> [LocalModel] {
        let recents = downloadedModels
            .filter { $0.lastUsedDate != nil }
            .filter { !excludingIDs.contains($0.id) }
            .sorted { ($0.lastUsedDate ?? Date.distantPast) > ($1.lastUsedDate ?? Date.distantPast) }
        return limit > 0 ? Array(recents.prefix(limit)) : recents
    }

    private func scanLayersIfNeeded() {
        let pending = downloadedModels.filter { $0.totalLayers == 0 }
        guard !pending.isEmpty else { return }
        let models = pending
        Task.detached(priority: .utility) { [weak self] in
            for model in models {
                let count = ModelScanner.layerCount(for: model.url, format: model.format)
                await self?.applyLayerCount(count, to: model)
                // Stagger to avoid startup spikes
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func scanMoEInfoIfNeeded() {
        let pending = downloadedModels.filter { model in
            switch model.format {
            case .gguf:
                guard let info = model.moeInfo else { return true }
                if info.isMoE {
                    return info.moeLayerCount == nil || info.totalLayerCount == nil || info.hiddenSize == nil || info.feedForwardSize == nil || info.vocabSize == nil
                }
                return info.totalLayerCount == nil
            case .mlx:
                guard let info = model.moeInfo else { return true }
                if info.isMoE {
                    return info.expertCount <= 1
                }
                if info.totalLayerCount == nil, info.moeLayerCount == 0 {
                    return true
                }
                return false
            case .et, .ane, .afm, .coreai:
                return false
            }
        }
        guard !pending.isEmpty else { return }
        let models = pending
        Task.detached(priority: .utility) { [weak self] in
            print("[MoEDetect] queued \(models.count) models for metadata scan")
            for model in models {
                let descriptor = "\(model.name) (\(model.quant)) [\(model.format.displayName)]"
                print("[MoEDetect] ▶︎ scanning \(descriptor)")
                let info = ModelScanner.moeInfo(for: model.url, format: model.format)
                let resolvedInfo: MoEInfo
                if let info {
                    let label = info.isMoE ? "MoE" : "Dense"
                    let moeLayers = info.moeLayerCount.map(String.init) ?? "n/a"
                    let totalLayers = info.totalLayerCount.map(String.init) ?? "n/a"
                    print("[MoEDetect] ✓ \(descriptor) result=\(label) experts=\(info.expertCount) moeLayers=\(moeLayers) totalLayers=\(totalLayers)")
                    resolvedInfo = info
                } else {
                    print("[MoEDetect] ⚠︎ \(descriptor) scan failed; defaulting to Dense metadata")
                    resolvedInfo = .denseFallback
                }
                guard let self else {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    continue
                }
                await self.applyMoEInfo(resolvedInfo, to: model)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    private func scanCapabilitiesIfNeeded() {
        let token = UserDefaults.standard.string(forKey: "huggingFaceToken")
        // Prepare a list of models that still need capability detection
        let candidates: [(id: String, quant: String, format: ModelFormat, url: URL)] = downloadedModels.compactMap { model in
            // Skip if we already have capability info
            if model.isMultimodal || model.isToolCapable { return nil }
            if let installed = store.all().first(where: { $0.modelID == model.modelID && $0.quantLabel == model.quant }),
               (installed.isMultimodal || installed.isToolCapable) { return nil }
            return (model.modelID, model.quant, model.format, model.url)
        }
        guard !candidates.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for (modelID, quant, format, localURL) in candidates {
                // Only use pipeline tag for multimodality
                var isVision = false
                var toolCap = false

                switch format {
                case .gguf, .mlx:
                    let meta = await HuggingFaceMetadataCache.fetchAndCache(repoId: modelID, token: token)
                    isVision = meta?.isVision ?? false
                    if !isVision {
                        // Fallback to on-disk heuristics for missing/incorrect tags
                        let ggufDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                        if let gguf = InstalledModelsStore.firstGGUF(in: ggufDir) {
                            isVision = ChatVM.guessLlamaVisionModel(from: gguf)
                        } else {
                            let mlxDir = InstalledModelsStore.baseDir(for: .mlx, modelID: modelID)
                            isVision = MLXBridge.isVLMModel(at: mlxDir)
                        }
                    }
                    toolCap = await ToolCapabilityDetector.isToolCapable(repoId: modelID, token: token)
                    if toolCap == false {
                        // Local fallback: prefer GGUF file or MLX directory
                        let ggufDir = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                        if let gguf = InstalledModelsStore.firstGGUF(in: ggufDir) {
                            toolCap = ToolCapabilityDetector.isToolCapableLocal(url: gguf, format: .gguf)
                        } else {
                            let mlxDir = InstalledModelsStore.baseDir(for: .mlx, modelID: modelID)
                            toolCap = ToolCapabilityDetector.isToolCapableLocal(url: mlxDir, format: .mlx)
                        }
                    }
                case .et:
                    isVision = LeapCatalogService.isVisionQuantizationSlug(modelID) || LeapCatalogService.bundleLikelyVision(at: localURL)
                    toolCap = true
                case .ane:
                    isVision = false
                    let aneDir = InstalledModelsStore.baseDir(for: .ane, modelID: modelID)
                    toolCap = ToolCapabilityDetector.isToolCapableLocal(url: aneDir, format: .ane)
                case .afm:
                    isVision = false
                    toolCap = true
                case .coreai:
                    isVision = false
                    let coreaiDir = InstalledModelsStore.baseDir(for: .coreai, modelID: modelID)
                    toolCap = ToolCapabilityDetector.isToolCapableLocal(url: coreaiDir, format: .coreai)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.store.updateCapabilities(modelID: modelID, quantLabel: quant, isMultimodal: isVision, isToolCapable: toolCap)
                    // Update in-memory list in place to avoid full refresh loops
                    if let idx = self.downloadedModels.firstIndex(where: { $0.modelID == modelID && $0.quant == quant }) {
                        self.downloadedModels[idx].isMultimodal = isVision
                        self.downloadedModels[idx].isToolCapable = toolCap
                    }
                }
                // Stagger requests
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func applyLayerCount(_ count: Int, to model: LocalModel) {
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx].totalLayers = count
            store.updateLayers(modelID: model.modelID, quantLabel: model.quant, layers: count)
        }
    }

    private func hydrateMoEInfoFromCache() {
        Task { [weak self] in
            let cache = await MoEDetectionStore.shared.all()
            guard !cache.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                var updated = self.downloadedModels
                var mutated = false
                for idx in updated.indices {
                    if updated[idx].moeInfo == nil && !updated[idx].modelID.hasPrefix("local/") {
                        let key = MoEDetectionStore.key(modelID: updated[idx].modelID, quantLabel: updated[idx].quant)
                        if let cachedInfo = cache[key] {
                            updated[idx].moeInfo = cachedInfo
                            self.store.updateMoEInfo(modelID: updated[idx].modelID, quantLabel: updated[idx].quant, info: cachedInfo)
                            mutated = true
                        }
                    }
                }
                if mutated {
                    self.downloadedModels = updated
                }
            }
        }
    }

    private static let moeDetectorVersionKey = "moeDetectorVersion"
    private static let currentMoEDetectorVersion = 2

    /// Imported models (`local/*`) historically used less-complete GGUF metadata keys/tensors, leading to
    /// dense misclassification. When our detector improves, clear cached results for local GGUF models once
    /// so they get re-scanned with the updated heuristics.
    private func invalidateLocalGGUFMoeInfoIfNeeded() {
        let storedVersion = UserDefaults.standard.integer(forKey: Self.moeDetectorVersionKey)
        guard storedVersion < Self.currentMoEDetectorVersion else { return }
        let localGGUFModels = downloadedModels.filter { $0.format == .gguf && $0.modelID.hasPrefix("local/") }
        guard !localGGUFModels.isEmpty else {
            UserDefaults.standard.set(Self.currentMoEDetectorVersion, forKey: Self.moeDetectorVersionKey)
            return
        }

        var updated = downloadedModels
        var mutated = false
        for idx in updated.indices {
            let model = updated[idx]
            guard model.format == .gguf, model.modelID.hasPrefix("local/") else { continue }
            if updated[idx].moeInfo != nil {
                updated[idx].moeInfo = nil
                store.updateMoEInfo(modelID: model.modelID, quantLabel: model.quant, info: nil)
                mutated = true
            }
        }
        if mutated {
            downloadedModels = updated
        }

        Task.detached(priority: .utility) {
            for model in localGGUFModels {
                await MoEDetectionStore.shared.remove(modelID: model.modelID, quantLabel: model.quant)
            }
        }
        UserDefaults.standard.set(Self.currentMoEDetectorVersion, forKey: Self.moeDetectorVersionKey)
    }

    @MainActor
    private func applyMoEInfo(_ info: MoEInfo, to model: LocalModel) async {
        if let idx = downloadedModels.firstIndex(where: { $0.id == model.id }) {
            downloadedModels[idx].moeInfo = info
        }
        store.updateMoEInfo(modelID: model.modelID, quantLabel: model.quant, info: info)
        await MoEDetectionStore.shared.update(info: info, modelID: model.modelID, quantLabel: model.quant)
    }
}

extension AppModelManager: ModelLoadingManaging {}

/// Holds the live text of the message currently being generated.
///
/// During streaming the model can emit tokens faster than 60 Hz. Writing every token
/// into `ChatVM.sessions` (which is `@Published` and observed by every tab via
/// `.environmentObject`) makes the *whole* app re-evaluate view bodies per token, which
/// is the main source of UI stutter during inference. Instead, high-frequency token
/// updates flow into this small, separate observable: only the streaming chat bubble and
/// the auto-scroll observer subscribe to it, so unrelated tabs are not disturbed.
///
/// `ChatVM` holds this as a plain `let` (not `@Published`), so mutating it does **not**
/// trip `ChatVM.objectWillChange`.
@MainActor final class StreamingMessageStore: ObservableObject {
    /// The id of the message currently streaming, or `nil` when idle.
    @Published private(set) var activeID: UUID?
    /// The latest visible assistant text for `activeID`.
    @Published private(set) var visibleText: String = ""

    func begin(id: UUID, initialText: String = "") {
        activeID = id
        visibleText = initialText
    }

    func update(_ text: String) {
        guard activeID != nil else { return }
        visibleText = text
    }

    func finish() {
        activeID = nil
        visibleText = ""
    }
}

    @MainActor final class ChatVM: ObservableObject {
    struct ETRepairCandidate: Equatable {
        let modelID: String
        let quantLabel: String
        let modelURL: URL
        let sourceRepoID: String?
    }

    // Progress tracker for model loading
    @Published var loadingProgressTracker = ModelLoadingProgressTracker()
    struct Msg: Identifiable, Equatable, Codable {
        struct Perf: Equatable, Codable {
            var tokenCount: Int
            var avgTokPerSec: Double
            var timeToFirst: Double
            /// Wall-clock seconds from the request being sent to the final token,
            /// i.e. time-to-first-token plus generation time. Surfaced as the
            /// "total" generation duration in the diagnostics footer.
            var totalDuration: Double
            var latencySamplesMs: [Double]

            init(
                tokenCount: Int,
                avgTokPerSec: Double,
                timeToFirst: Double,
                totalDuration: Double = 0,
                latencySamplesMs: [Double] = []
            ) {
                self.tokenCount = tokenCount
                self.avgTokPerSec = avgTokPerSec
                self.timeToFirst = timeToFirst
                self.totalDuration = totalDuration
                self.latencySamplesMs = latencySamplesMs
            }

            private enum CodingKeys: String, CodingKey {
                case tokenCount
                case avgTokPerSec
                case timeToFirst
                case totalDuration
                case latencySamplesMs
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                tokenCount = try container.decode(Int.self, forKey: .tokenCount)
                avgTokPerSec = try container.decode(Double.self, forKey: .avgTokPerSec)
                timeToFirst = try container.decode(Double.self, forKey: .timeToFirst)
                totalDuration = try container.decodeIfPresent(Double.self, forKey: .totalDuration) ?? 0
                latencySamplesMs = try container.decodeIfPresent([Double].self, forKey: .latencySamplesMs) ?? []
            }
        }

        struct PromptProcessingState: Equatable, Codable {
            var progress: Double
        }
        
        struct Citation: Equatable, Codable {
            let text: String
            let source: String?
            let score: Float?

            init(text: String, source: String?, score: Float? = nil) {
                self.text = text
                self.source = source
                self.score = score
            }
        }

        struct RAGInjectionInfo: Equatable, Codable {
            enum Stage: String, Equatable, Codable {
                case deciding
                case chosen
                case injected
            }

            enum Method: String, Equatable, Codable {
                case fullContent
                case rag
            }

            let datasetName: String
            let stage: Stage
            let method: Method?
            let requestedMaxChunks: Int
            let retrievedChunkCount: Int
            let injectedChunkCount: Int
            let trimmedChunkCount: Int
            let partialChunkInjected: Bool
            let fullContentEstimateTokens: Int?
            let configuredContextTokens: Int
            let reservedResponseTokens: Int
            let contextBudgetTokens: Int
            let injectedContextTokens: Int
            let decisionReason: String

            init(
                datasetName: String,
                stage: Stage,
                method: Method?,
                requestedMaxChunks: Int,
                retrievedChunkCount: Int,
                injectedChunkCount: Int,
                trimmedChunkCount: Int,
                partialChunkInjected: Bool,
                fullContentEstimateTokens: Int?,
                configuredContextTokens: Int,
                reservedResponseTokens: Int,
                contextBudgetTokens: Int,
                injectedContextTokens: Int,
                decisionReason: String
            ) {
                self.datasetName = datasetName
                self.stage = stage
                self.method = method
                self.requestedMaxChunks = requestedMaxChunks
                self.retrievedChunkCount = retrievedChunkCount
                self.injectedChunkCount = injectedChunkCount
                self.trimmedChunkCount = trimmedChunkCount
                self.partialChunkInjected = partialChunkInjected
                self.fullContentEstimateTokens = fullContentEstimateTokens
                self.configuredContextTokens = configuredContextTokens
                self.reservedResponseTokens = reservedResponseTokens
                self.contextBudgetTokens = contextBudgetTokens
                self.injectedContextTokens = injectedContextTokens
                self.decisionReason = decisionReason
            }

            enum CodingKeys: String, CodingKey {
                case datasetName
                case stage
                case method
                case requestedMaxChunks
                case retrievedChunkCount
                case injectedChunkCount
                case trimmedChunkCount
                case partialChunkInjected
                case fullContentEstimateTokens
                case configuredContextTokens
                case reservedResponseTokens
                case contextBudgetTokens
                case injectedContextTokens
                case decisionReason
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                datasetName = try container.decode(String.self, forKey: .datasetName)
                stage = try container.decode(Stage.self, forKey: .stage)
                method = try container.decodeIfPresent(Method.self, forKey: .method)
                requestedMaxChunks = try container.decode(Int.self, forKey: .requestedMaxChunks)
                retrievedChunkCount = try container.decode(Int.self, forKey: .retrievedChunkCount)
                injectedChunkCount = try container.decode(Int.self, forKey: .injectedChunkCount)
                trimmedChunkCount = try container.decode(Int.self, forKey: .trimmedChunkCount)
                partialChunkInjected = try container.decode(Bool.self, forKey: .partialChunkInjected)
                fullContentEstimateTokens = try container.decodeIfPresent(Int.self, forKey: .fullContentEstimateTokens)
                contextBudgetTokens = try container.decode(Int.self, forKey: .contextBudgetTokens)
                configuredContextTokens = try container.decodeIfPresent(Int.self, forKey: .configuredContextTokens)
                    ?? contextBudgetTokens
                reservedResponseTokens = try container.decodeIfPresent(Int.self, forKey: .reservedResponseTokens)
                    ?? max(0, configuredContextTokens - contextBudgetTokens)
                injectedContextTokens = try container.decode(Int.self, forKey: .injectedContextTokens)
                decisionReason = try container.decode(String.self, forKey: .decisionReason)
            }
        }

        // Web tool metadata captured from TOOL_RESULT output
        struct WebHit: Equatable, Codable {
            let id: String
            let title: String
            let snippet: String
            let url: String
            let engine: String
            let score: Double
        }

        enum ToolCallPhase: String, Equatable, Codable {
            case requesting
            case executing
            case running
            case completed
            case failed

            var isInFlight: Bool {
                self == .requesting || self == .executing || self == .running
            }

            var isExecutingLike: Bool {
                self == .executing || self == .running
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let rawValue = try container.decode(String.self)
                switch rawValue {
                case Self.requesting.rawValue:
                    self = .requesting
                case Self.executing.rawValue, Self.running.rawValue:
                    self = .executing
                case Self.completed.rawValue:
                    self = .completed
                case Self.failed.rawValue:
                    self = .failed
                default:
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "Unknown ToolCallPhase value: \(rawValue)"
                    )
                }
            }
        }
        
        // Generic tool call metadata for UI display
        struct ToolCall: Equatable, Codable, Identifiable {
            let id: UUID
            let toolName: String
            let displayName: String
            let iconName: String
            let requestParams: [String: AnyCodable]
            let phase: ToolCallPhase
            let externalToolCallID: String?
            let result: String?
            let error: String?
            let timestamp: Date
            
            init(
                id: UUID = UUID(),
                toolName: String,
                displayName: String,
                iconName: String,
                requestParams: [String: AnyCodable],
                phase: ToolCallPhase = .executing,
                externalToolCallID: String? = nil,
                result: String? = nil,
                error: String? = nil,
                timestamp: Date = Date()
            ) {
                self.id = id
                self.toolName = toolName
                self.displayName = displayName
                self.iconName = iconName
                self.requestParams = requestParams
                self.phase = phase
                self.externalToolCallID = externalToolCallID
                self.result = result
                self.error = error
                self.timestamp = timestamp
            }

            enum CodingKeys: String, CodingKey {
                case id, toolName, displayName, iconName, requestParams
                case phase, externalToolCallID, result, error, timestamp
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(UUID.self, forKey: .id)
                toolName = try c.decode(String.self, forKey: .toolName)
                displayName = try c.decode(String.self, forKey: .displayName)
                iconName = try c.decode(String.self, forKey: .iconName)
                requestParams = (try? c.decode([String: AnyCodable].self, forKey: .requestParams)) ?? [:]
                externalToolCallID = try? c.decode(String.self, forKey: .externalToolCallID)
                result = try? c.decode(String.self, forKey: .result)
                error = try? c.decode(String.self, forKey: .error)
                timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
                if let decodedPhase = try? c.decode(ToolCallPhase.self, forKey: .phase) {
                    phase = decodedPhase
                } else if error != nil {
                    phase = .failed
                } else if result != nil {
                    phase = .completed
                } else {
                    phase = .executing
                }
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(toolName, forKey: .toolName)
                try c.encode(displayName, forKey: .displayName)
                try c.encode(iconName, forKey: .iconName)
                try c.encode(requestParams, forKey: .requestParams)
                try c.encode(phase, forKey: .phase)
                try c.encodeIfPresent(externalToolCallID, forKey: .externalToolCallID)
                try c.encodeIfPresent(result, forKey: .result)
                try c.encodeIfPresent(error, forKey: .error)
                try c.encode(timestamp, forKey: .timestamp)
            }
        }

        let id: UUID
        let role: String
        var text: String
        var timestamp: Date
        var datasetID: String?
        var datasetName: String?
        var perf: Perf?
        var streaming: Bool = false
        var promptProcessing: PromptProcessingState?
        // Shows a post-tool-call waiting spinner in the UI until
        // the first continuation token arrives after a tool result.
        var postToolWaiting: Bool = false
        var retrievedContext: String?
        var citations: [Citation]?
        var ragInjectionInfo: RAGInjectionInfo?
        var usedWebSearch: Bool?
        var usedRemoteBackend: Bool?
        var remoteBackendName: String?
        var remoteModelName: String?
        /// True when this reply was produced (fully or via mid-turn handoff)
        /// by Apple's Private Cloud Compute rather than on-device AFM.
        var ranOnPrivateCloudCompute: Bool?
        var webHits: [WebHit]?
        var webError: String?
        var imagePaths: [String]?
        var mediaAttachments: [ChatMediaAttachment]?
        var toolCalls: [ToolCall]?
        var isBookmarked: Bool = false

        var trimmedVisibleAssistantText: String {
            visibleAssistantText(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var hasVisibleAssistantText: Bool {
            !trimmedVisibleAssistantText.isEmpty
        }

        var shouldShowPromptProcessingCard: Bool {
            role == "🤖" && streaming && promptProcessing != nil
        }

        var shouldShowGenericLoadingIndicator: Bool {
            role == "🤖"
                && streaming
                && promptProcessing == nil
                && !postToolWaiting
                && !hasVisibleAssistantText
        }

        init(id: UUID = UUID(),
             role: String,
             text: String,
             timestamp: Date = Date(),
             datasetID: String? = nil,
             datasetName: String? = nil,
             perf: Perf? = nil,
             streaming: Bool = false,
             promptProcessing: PromptProcessingState? = nil,
             usedRemoteBackend: Bool? = nil,
             remoteBackendName: String? = nil,
             remoteModelName: String? = nil,
             isBookmarked: Bool = false) {
            self.id = id
            self.role = role
            self.text = text
            self.timestamp = timestamp
            self.datasetID = datasetID
            self.datasetName = datasetName
            self.perf = perf
            self.streaming = streaming
            self.promptProcessing = promptProcessing
            self.usedRemoteBackend = usedRemoteBackend
            self.remoteBackendName = remoteBackendName
            self.remoteModelName = remoteModelName
            self.isBookmarked = isBookmarked
        }

        enum CodingKeys: String, CodingKey { case id, role, text, timestamp, datasetID, datasetName, perf, promptProcessing, retrievedContext, citations, ragInjectionInfo, usedWebSearch, usedRemoteBackend, remoteBackendName, remoteModelName, ranOnPrivateCloudCompute, webHits, webError, imagePaths, mediaAttachments, toolCalls, isBookmarked }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            role = try c.decode(String.self, forKey: .role)
            text = try c.decode(String.self, forKey: .text)
            timestamp = (try? c.decode(Date.self, forKey: .timestamp)) ?? Date()
            datasetID = try? c.decode(String.self, forKey: .datasetID)
            datasetName = try? c.decode(String.self, forKey: .datasetName)
            perf = try? c.decode(Perf.self, forKey: .perf)
            promptProcessing = try? c.decode(PromptProcessingState.self, forKey: .promptProcessing)
            retrievedContext = try? c.decode(String.self, forKey: .retrievedContext)
            citations = try? c.decode([Citation].self, forKey: .citations)
            ragInjectionInfo = try? c.decode(RAGInjectionInfo.self, forKey: .ragInjectionInfo)
            usedWebSearch = try? c.decode(Bool.self, forKey: .usedWebSearch)
            usedRemoteBackend = try? c.decode(Bool.self, forKey: .usedRemoteBackend)
            remoteBackendName = try? c.decode(String.self, forKey: .remoteBackendName)
            remoteModelName = try? c.decode(String.self, forKey: .remoteModelName)
            ranOnPrivateCloudCompute = try? c.decode(Bool.self, forKey: .ranOnPrivateCloudCompute)
            webHits = try? c.decode([WebHit].self, forKey: .webHits)
            webError = try? c.decode(String.self, forKey: .webError)
            imagePaths = try? c.decode([String].self, forKey: .imagePaths)
            mediaAttachments = try? c.decode([ChatMediaAttachment].self, forKey: .mediaAttachments)
            toolCalls = try? c.decode([ToolCall].self, forKey: .toolCalls)
            isBookmarked = (try? c.decode(Bool.self, forKey: .isBookmarked)) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(role, forKey: .role)
            try c.encode(text, forKey: .text)
            try c.encode(timestamp, forKey: .timestamp)
            try c.encodeIfPresent(datasetID, forKey: .datasetID)
            try c.encodeIfPresent(datasetName, forKey: .datasetName)
            try c.encodeIfPresent(perf, forKey: .perf)
            try c.encodeIfPresent(promptProcessing, forKey: .promptProcessing)
            try c.encodeIfPresent(retrievedContext, forKey: .retrievedContext)
            try c.encode(citations, forKey: .citations)
            try c.encodeIfPresent(ragInjectionInfo, forKey: .ragInjectionInfo)
            try c.encodeIfPresent(usedWebSearch, forKey: .usedWebSearch)
            try c.encodeIfPresent(usedRemoteBackend, forKey: .usedRemoteBackend)
            try c.encodeIfPresent(remoteBackendName, forKey: .remoteBackendName)
            try c.encodeIfPresent(remoteModelName, forKey: .remoteModelName)
            try c.encodeIfPresent(ranOnPrivateCloudCompute, forKey: .ranOnPrivateCloudCompute)
            try c.encodeIfPresent(webHits, forKey: .webHits)
            try c.encodeIfPresent(webError, forKey: .webError)
            try c.encodeIfPresent(imagePaths, forKey: .imagePaths)
            try c.encodeIfPresent(mediaAttachments, forKey: .mediaAttachments)
            try c.encodeIfPresent(toolCalls, forKey: .toolCalls)
            if isBookmarked {
                try c.encode(isBookmarked, forKey: .isBookmarked)
            }
        }
    }

    // Expose Msg.ToolCall as ChatVM.ToolCall for convenience
    typealias ToolCall = Msg.ToolCall

    struct ChatToolPermissions: Equatable, Codable {
        var webSearch: Bool
        var python: Bool
        var memory: Bool
        var datasetRetrieval: Bool

        static let allEnabled = ChatToolPermissions(webSearch: true, python: true, memory: true, datasetRetrieval: true)
        static let allDisabled = ChatToolPermissions(webSearch: false, python: false, memory: false, datasetRetrieval: false)

        init(webSearch: Bool, python: Bool, memory: Bool, datasetRetrieval: Bool = true) {
            self.webSearch = webSearch
            self.python = python
            self.memory = memory
            self.datasetRetrieval = datasetRetrieval
        }

        private enum CodingKeys: String, CodingKey {
            case webSearch
            case python
            case memory
            case datasetRetrieval
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            webSearch = try container.decodeIfPresent(Bool.self, forKey: .webSearch) ?? true
            python = try container.decodeIfPresent(Bool.self, forKey: .python) ?? true
            memory = try container.decodeIfPresent(Bool.self, forKey: .memory) ?? true
            datasetRetrieval = try container.decodeIfPresent(Bool.self, forKey: .datasetRetrieval) ?? true
        }

        var enabledCount: Int {
            [webSearch, python, memory, datasetRetrieval].filter { $0 }.count
        }

        func filtered(_ availability: ToolAvailability) -> ToolAvailability {
            ToolAvailability(
                webSearch: availability.webSearch && webSearch,
                python: availability.python && python,
                memory: availability.memory && memory,
                calculator: availability.calculator,
                unitConverter: availability.unitConverter
            )
        }

        func allows(toolName: String) -> Bool {
            switch toolName {
            case "noema.web.retrieve":
                return webSearch
            case "noema.python.execute":
                return python
            case "noema.memory":
                return memory
            default:
                return true
            }
        }
    }

    enum ChatToolPermissionKind {
        case webSearch
        case python
        case memory
        case datasetRetrieval
    }

    enum ChatMode: String, CaseIterable, Identifiable, Codable {
        case general
        case research
        case study
        case code
        case meetingPrep
        case travel
        case medicalNotes
        case legalReading
        case creativeDrafting

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .general: return "General Chat"
            case .research: return "Research Mode"
            case .study: return "Study Mode"
            case .code: return "Code Mode"
            case .meetingPrep: return "Meeting Prep Mode"
            case .travel: return "Travel Mode"
            case .medicalNotes: return "Medical Notes Mode"
            case .legalReading: return "Legal Reading Mode"
            case .creativeDrafting: return "Creative Drafting Mode"
            }
        }

        var systemImage: String {
            switch self {
            case .general: return "bubble.left.and.bubble.right"
            case .research: return "doc.text.magnifyingglass"
            case .study: return "book"
            case .code: return "chevron.left.forwardslash.chevron.right"
            case .meetingPrep: return "calendar.badge.clock"
            case .travel: return "airplane"
            case .medicalNotes: return "cross.case"
            case .legalReading: return "scroll"
            case .creativeDrafting: return "paintbrush"
            }
        }

        var promptGuidance: String? {
            switch self {
            case .general:
                return nil
            case .research:
                return "Chat mode: Research. Prioritize source-grounded synthesis, call out uncertainty, separate findings from assumptions, and preserve citations when retrieval or tools provide evidence."
            case .study:
                return "Chat mode: Study. Teach step by step, check understanding, create short examples, and prefer quizzes or summaries when they help the user learn."
            case .code:
                return "Chat mode: Code. Be precise about files, APIs, edge cases, and tests. Prefer minimal patches, explain tradeoffs, and avoid speculative implementation details."
            case .meetingPrep:
                return "Chat mode: Meeting Prep. Extract goals, decisions needed, risks, agenda items, and concrete follow-ups. Keep the result scannable."
            case .travel:
                return "Chat mode: Travel. Organize by time, place, constraints, confirmations, and contingencies. Highlight missing details and offline-relevant information."
            case .medicalNotes:
                return "Chat mode: Medical Notes. Summarize clearly, distinguish user-provided facts from interpretation, avoid diagnosis certainty, and recommend professional care for urgent or risky symptoms."
            case .legalReading:
                return "Chat mode: Legal Reading. Identify facts, issues, rules, analysis, caveats, and cited text. Avoid presenting legal conclusions as professional legal advice."
            case .creativeDrafting:
                return "Chat mode: Creative Drafting. Offer strong options, preserve the user's voice, make intentional style choices, and keep iterations easy to compare."
            }
        }
    }

    enum AnswerStyle: String, CaseIterable, Identifiable, Codable {
        case natural
        case terse
        case cited
        case stepByStep
        case socratic
        case executiveBrief
        case tableFirst

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .natural: return "Natural Style"
            case .terse: return "Terse"
            case .cited: return "Cited"
            case .stepByStep: return "Step-by-step"
            case .socratic: return "Socratic"
            case .executiveBrief: return "Executive Brief"
            case .tableFirst: return "Table-first"
            }
        }

        var promptGuidance: String? {
            switch self {
            case .natural:
                return nil
            case .terse:
                return "Answer style: Terse. Prefer concise direct answers, remove filler, and use bullets only when they improve clarity."
            case .cited:
                return "Answer style: Cited. Preserve citations and source labels when available; clearly separate uncited model knowledge from cited evidence."
            case .stepByStep:
                return "Answer style: Step-by-step. Explain the reasoning path as user-visible steps without exposing hidden chain-of-thought; summarize before details when useful."
            case .socratic:
                return "Answer style: Socratic. Ask one focused question at a time when teaching or debugging; guide the user toward the answer instead of dumping everything at once."
            case .executiveBrief:
                return "Answer style: Executive Brief. Lead with the decision, risks, and next actions; keep sections short and scan-friendly."
            case .tableFirst:
                return "Answer style: Table-first. Use a compact table for comparisons, options, or extracted facts before any prose summary."
            }
        }
    }

    struct Session: Identifiable, Equatable, Codable {
        let id: UUID
        var title: String
        var messages: [Msg]
        var isFavorite: Bool = false
        var date: Date
        var datasetID: String?
        var toolPermissions: ChatToolPermissions?
        var scratchpad: String?
        var chatMode: ChatMode?
        var answerStyle: AnswerStyle?
        var chatInstructions: String?

        init(id: UUID = UUID(), title: String, messages: [Msg], isFavorite: Bool = false, date: Date, datasetID: String? = nil, toolPermissions: ChatToolPermissions? = .allEnabled, scratchpad: String? = nil, chatMode: ChatMode? = nil, answerStyle: AnswerStyle? = nil, chatInstructions: String? = nil) {
            self.id = id
            self.title = title
            self.messages = messages
            self.isFavorite = isFavorite
            self.date = date
            self.datasetID = datasetID
            self.toolPermissions = toolPermissions
            self.scratchpad = scratchpad
            self.chatMode = chatMode
            self.answerStyle = answerStyle
            self.chatInstructions = chatInstructions
        }
    }
    
    fileprivate enum Piece: Identifiable {
        case text(String)
        case think(String, done: Bool)
        case code(String, language: String?)
        case tool(Int) // Index of the tool call in the message's toolCalls array

        var id: UUID { UUID() }

        var isThink: Bool {
            if case .think = self { return true }
            return false
        }

        var isTool: Bool {
            if case .tool = self { return true }
            return false
        }
    }

    enum InjectionStage { case none, deciding, decided, processing, predicting }
    enum InjectionMethod { case full, rag }

    @Published var sessions: [Session] = [] {
        didSet { saveSessions() }
    }
    @Published var activeSessionID: Session.ID? {
        didSet {
            saveSessions()
            syncModelManagerDatasetForActiveSession()
            refreshSystemPromptForActiveSession()
            // Recreate rolling thought view models when switching sessions
            DispatchQueue.main.async { [weak self] in
                self?.recreateRollingThoughtViewModels()
            }
            if let id = activeSessionID {
                Task { [weak self] in
                    guard let self else { return }
                    await self.remoteService?.updateConversationID(id)
                }
            }
        }
    }
    @Published var prompt: String = ""
    @Published var loading  = false {
        didSet {
            if !loading {
                loadingProgressTracker.completeLoading()
            }
        }
    }
    @Published var stillLoading = false
    @Published var loadError: String?
    @Published var pendingETRepairCandidate: ETRepairCandidate?
    @Published private(set) var modelLoaded = false
    @Published private(set) var lastUnloadVerification: ModelUnloadMemoryVerificationResult?
    @Published private(set) var lastGenerationPowerPolicy: GenerationPowerPolicyDecision?
    @Published var stopAfterParagraphRequested = false
    var canAcceptChatInput: Bool {
        (modelLoaded && client != nil && !loading && !stillLoading)
            || modelManager?.activeRemoteSession != nil
    }
    var hasActiveChatModel: Bool {
        canAcceptChatInput
            || modelManager?.loadedModel != nil
            || loadedURL != nil
            || loadedFormat != nil
    }
    @Published var injectionStage: InjectionStage = .none
    @Published var injectionMethod: InjectionMethod?
    @Published var supportsImageInput: Bool = false
    @Published var pendingImageURLs: [URL] = []
    @Published var pendingMediaAttachments: [ChatMediaAttachment] = []
    @Published var isRecordingAudio: Bool = false
    @Published var audioRecordingError: String?
    @Published var audioRecordingStartedAt: Date?
    @Published var audioRecordingLevel: Float = 0
    // In-memory thumbnails for pending attachments to avoid re-decoding on each keystroke.
    @Published private(set) var pendingThumbnails: [URL: UIImage] = [:]
    @Published var crossSessionSendBlocked: Bool = false
    @Published var spotlightMessageID: UUID?
    @Published private var contextOverflowBanners: [Session.ID: ContextOverflowBannerState] = [:]
    @Published private(set) var memoryPromptBudgetStatus: MemoryPromptBudgetStatus = .inactive

    var contextOverflowBanner: ContextOverflowBannerState? {
        guard let sessionID = activeSessionID else { return nil }
        return contextOverflowBanners[sessionID]
    }

    var memoryPromptBudgetNoticeText: String? {
        let status = memoryPromptBudgetStatus
        guard status.shouldDisplayNotice else { return nil }
        switch status.state {
        case .partiallyLoaded:
            return String.localizedStringWithFormat(
                String(localized: "Memory limited: %d of %d preloaded"),
                status.loadedCount,
                status.totalCount
            )
        case .notLoaded:
            return String(localized: "Memory not preloaded")
        case .inactive, .allLoaded:
            return nil
        }
    }

    var memoryPromptBudgetAlertTitle: String {
        switch memoryPromptBudgetStatus.state {
        case .partiallyLoaded:
            return String(localized: "Memory Limited")
        case .notLoaded:
            return String(localized: "Memory Not Preloaded")
        case .inactive, .allLoaded:
            return String(localized: "Memory")
        }
    }

    var memoryPromptBudgetAlertBody: String {
        let status = memoryPromptBudgetStatus
        switch status.state {
        case .partiallyLoaded:
            return String.localizedStringWithFormat(
                String(localized: "Only %d of %d saved memories were preloaded for this turn. The remaining memories were skipped so the current model stays within its context budget."),
                status.loadedCount,
                status.totalCount
            )
        case .notLoaded:
            return String(localized: "Saved memories were not preloaded for this turn because the current model's context budget is too small.")
        case .inactive, .allLoaded:
            return String(localized: "All saved memories fit within the current model's context budget.")
        }
    }

    struct ContextOverflowBannerState: Equatable {
        let strategy: ContextOverflowStrategy
        let promptTokens: Int?
        let contextTokens: Int?
        let timestamp: Date
    }

    private struct ContextOverflowDetails {
        let promptTokens: Int?
        let contextTokens: Int?
        let rawMessage: String
    }

    private struct ContextHistoryPlan {
        let history: [Msg]
        let initialEstimate: Int
        let finalEstimate: Int
        let trimmed: Bool
        let requiresStop: Bool
    }

    struct RAGPackedContext: Equatable {
        let injectedContext: String
        let injectedCitations: [Msg.Citation]
        let retrievedChunkCount: Int
        let injectedChunkCount: Int
        let trimmedChunkCount: Int
        let partialChunkInjected: Bool
        let contextTokenCount: Int
        let contextBudgetTokens: Int
    }

    private struct ResolvedRAGContext {
        let injectedContext: String
        let citations: [Msg.Citation]
        let info: Msg.RAGInjectionInfo
    }

    struct AFMContextPreflight: Equatable {
        let history: [Msg]
        let promptTokens: Int
        let contextLimit: Int
        let stopMessage: String?
    }

    struct PromptBudget: Equatable {
        let configuredContextTokens: Int
        let reservedResponseTokens: Int
        let usablePromptTokens: Int
    }

    struct FullContextFitResult: Equatable {
        let fullContextTokens: Int
        let promptTokens: Int
        let budget: PromptBudget

        var fits: Bool {
            promptTokens <= budget.usablePromptTokens
        }
    }

    private struct PendingPerfAccumulator {
        static let maxLatencySamples = 32

        var start: Date
        var firstToken: Date?
        var lastToken: Date?
        var tokenCount: Int
        var latencySamplesMs: [Double]
    }

    private var pendingPerfAccumulators: [UUID: PendingPerfAccumulator] = [:]

    private func beginPerfTracking(messageID: UUID, start: Date) {
        pendingPerfAccumulators[messageID] = PendingPerfAccumulator(
            start: start,
            firstToken: nil,
            lastToken: nil,
            tokenCount: 0,
            latencySamplesMs: []
        )
    }

    private func recordToken(messageID: UUID, timestamp: Date = Date()) {
        guard var acc = pendingPerfAccumulators[messageID] else { return }
        acc.tokenCount += 1
        if acc.firstToken == nil {
            acc.firstToken = timestamp
        }
        if let previous = acc.lastToken {
            let latencyMs = timestamp.timeIntervalSince(previous) * 1000
            if latencyMs.isFinite, latencyMs >= 0 {
                if acc.latencySamplesMs.count >= PendingPerfAccumulator.maxLatencySamples {
                    acc.latencySamplesMs.removeFirst(acc.latencySamplesMs.count - PendingPerfAccumulator.maxLatencySamples + 1)
                }
                acc.latencySamplesMs.append(latencyMs)
            }
        }
        acc.lastToken = timestamp
        pendingPerfAccumulators[messageID] = acc
    }

    private func finalizePerf(messageID: UUID, injectionOverhead: Int) -> Msg.Perf? {
        guard let acc = pendingPerfAccumulators.removeValue(forKey: messageID),
              let first = acc.firstToken,
              let last = acc.lastToken else { return nil }
        let duration = last.timeIntervalSince(first)
        let rate = duration > 0 ? Double(acc.tokenCount) / duration : 0
        let totalTokens = acc.tokenCount + max(0, injectionOverhead)
        let timeToFirst = first.timeIntervalSince(acc.start)
        let totalDuration = last.timeIntervalSince(acc.start)
        return Msg.Perf(
            tokenCount: totalTokens,
            avgTokPerSec: rate,
            timeToFirst: timeToFirst,
            totalDuration: totalDuration,
            latencySamplesMs: acc.latencySamplesMs
        )
    }

    private func cancelPerfTracking(messageID: UUID) {
        pendingPerfAccumulators.removeValue(forKey: messageID)
    }

    nonisolated static func diagnosticHash(for text: String) -> String {
        String(text.hashValue, radix: 16)
    }

    nonisolated static func systemPromptMetadataSummary(_ systemPrompt: String) -> String {
        "[ChatVM] SYSTEM PROMPT len=\(systemPrompt.count) hash=\(diagnosticHash(for: systemPrompt))"
    }

    nonisolated static func promptMetadataSummary(
        prompt: String,
        stops: [String],
        format: ModelFormat?,
        kind: ModelKind,
        hasTemplate: Bool
    ) -> String {
        let formatLabel = format?.displayName ?? "<none>"
        let templateLabel = hasTemplate ? "custom" : "default"
        return "len=\(prompt.count) stops=\(stops.count) hash=\(diagnosticHash(for: prompt)) format=\(formatLabel) kind=\(String(describing: kind)) template=\(templateLabel)"
    }

    nonisolated static func ragMetadataSummary(
        method: String,
        contextLength: Int,
        prompt: String
    ) -> String {
        "method=\(method) contextChars=\(contextLength) promptLen=\(prompt.count) promptHash=\(diagnosticHash(for: prompt))"
    }

    nonisolated static func promptBudget(for contextLimit: Double) -> PromptBudget {
        let configuredContextTokens = max(1, Int(contextLimit.rounded()))
        let reservedResponseTokens = min(4096, max(512, Int(Double(configuredContextTokens) * 0.05)))
        let usablePromptTokens = max(256, configuredContextTokens - reservedResponseTokens)
        return PromptBudget(
            configuredContextTokens: configuredContextTokens,
            reservedResponseTokens: reservedResponseTokens,
            usablePromptTokens: usablePromptTokens
        )
    }

    private func currentPromptBudget() -> PromptBudget {
        Self.promptBudget(for: contextLimit)
    }

    private func estimatedPromptTokens(for prompt: String) async -> Int {
        if loadedFormat == .gguf, let exact = await tokenCountViaServer(prompt) {
            return exact
        }
        if let exact = await client?.countTokens(in: prompt) {
            return exact
        }
        return estimateTokensSync(prompt)
    }

    nonisolated static func evaluateFullContextInjection(
        fullContext: String,
        contextLimit: Double,
        promptBuilder: @escaping @Sendable (String) -> String,
        promptTokenCounter: @escaping @Sendable (String) async -> Int
    ) async -> FullContextFitResult {
        let budget = promptBudget(for: contextLimit)
        let trimmedContext = fullContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullContextTokens = trimmedContext.isEmpty ? 0 : await promptTokenCounter(trimmedContext)
        let promptTokens = await promptTokenCounter(promptBuilder(fullContext))
        return FullContextFitResult(
            fullContextTokens: fullContextTokens,
            promptTokens: promptTokens,
            budget: budget
        )
    }

    private func updateRAGInjectionInfo(messageIndex: Int, _ info: Msg.RAGInjectionInfo?) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        streamMsgs[messageIndex].ragInjectionInfo = info
    }

    private func clearRAGInjectionArtifacts(messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        streamMsgs[messageIndex].retrievedContext = nil
        streamMsgs[messageIndex].citations = nil
        streamMsgs[messageIndex].ragInjectionInfo = nil
    }

    private func updateStreamMessage(at messageIndex: Int, mutate: (inout Msg) -> Void) {
        guard streamMsgs.indices.contains(messageIndex) else { return }
        var messages = streamMsgs
        mutate(&messages[messageIndex])
        streamMsgs = messages
    }

    private func cachedFullDatasetContent(for dataset: LocalDataset) async -> String {
        if let cached = fullDatasetContentCache[dataset.datasetID] {
            return cached
        }
        let fullContent = await DatasetRetriever.shared.fetchAllContent(for: dataset)
        fullDatasetContentCache[dataset.datasetID] = fullContent
        return fullContent
    }

    nonisolated private static func formattedRAGChunk(index: Int, text: String, source: String?) -> String {
        let src = source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if src.isEmpty {
            return "[\(index)] \(text)"
        }
        return "[\(index)] (\(src)) \(text)"
    }

    nonisolated private static func trimmedChunkPrefix(_ text: String, characterCount: Int) -> String {
        guard characterCount > 0 else { return "" }
        let rawPrefix = String(text.prefix(characterCount))
        let trimmed = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard characterCount < text.count else { return trimmed }

        if let lastWhitespace = trimmed.lastIndex(where: { $0.isWhitespace }),
           trimmed.distance(from: trimmed.startIndex, to: lastWhitespace) >= max(16, trimmed.count / 2) {
            return String(trimmed[..<lastWhitespace]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    nonisolated static func packRAGContext(
        chunks: [(text: String, source: String?, score: Float?)],
        requestedMaxChunks: Int,
        usablePromptTokens: Int,
        promptTokenCounter: @escaping @Sendable (String) async -> Int,
        promptBuilder: @escaping @Sendable (String) -> String
    ) async -> RAGPackedContext {
        let retrievedChunks = Array(chunks.prefix(max(0, requestedMaxChunks)))
        let contextBudgetTokens = max(256, usablePromptTokens)
        guard requestedMaxChunks > 0, !retrievedChunks.isEmpty else {
            return RAGPackedContext(
                injectedContext: "",
                injectedCitations: [],
                retrievedChunkCount: retrievedChunks.count,
                injectedChunkCount: 0,
                trimmedChunkCount: 0,
                partialChunkInjected: false,
                contextTokenCount: 0,
                contextBudgetTokens: contextBudgetTokens
            )
        }

        var injectedBlocks: [String] = []
        var injectedCitations: [Msg.Citation] = []

        for chunk in retrievedChunks {
            let nextIndex = injectedBlocks.count + 1
            let formatted = formattedRAGChunk(index: nextIndex, text: chunk.text, source: chunk.source)
            let candidate = injectedBlocks.isEmpty ? formatted : injectedBlocks.joined(separator: "\n\n") + "\n\n" + formatted
            let tokenCount = await promptTokenCounter(promptBuilder(candidate))
            if tokenCount <= contextBudgetTokens {
                injectedBlocks.append(formatted)
                injectedCitations.append(Msg.Citation(text: chunk.text, source: chunk.source, score: chunk.score))
            } else {
                break
            }
        }

        var partialChunkInjected = false
        if injectedBlocks.isEmpty, let firstChunk = retrievedChunks.first {
            let firstText = firstChunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !firstText.isEmpty {
                var low = 1
                var high = firstText.count
                var bestText = ""

                while low <= high {
                    let mid = (low + high) / 2
                    let candidateText = trimmedChunkPrefix(firstText, characterCount: mid)
                    if candidateText.isEmpty {
                        low = mid + 1
                        continue
                    }

                    let formatted = formattedRAGChunk(index: 1, text: candidateText, source: firstChunk.source)
                    let tokenCount = await promptTokenCounter(promptBuilder(formatted))
                    if tokenCount <= contextBudgetTokens {
                        bestText = candidateText
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }

                if !bestText.isEmpty {
                    injectedBlocks = [formattedRAGChunk(index: 1, text: bestText, source: firstChunk.source)]
                    injectedCitations = [Msg.Citation(text: bestText, source: firstChunk.source, score: firstChunk.score)]
                    partialChunkInjected = bestText != firstText
                }
            }
        }

        let injectedContext = injectedBlocks.joined(separator: "\n\n")
        let contextTokenCount = injectedContext.isEmpty ? 0 : await promptTokenCounter(injectedContext)
        let injectedChunkCount = injectedCitations.count
        return RAGPackedContext(
            injectedContext: injectedContext,
            injectedCitations: injectedCitations,
            retrievedChunkCount: retrievedChunks.count,
            injectedChunkCount: injectedChunkCount,
            trimmedChunkCount: max(0, retrievedChunks.count - injectedChunkCount),
            partialChunkInjected: partialChunkInjected,
            contextTokenCount: contextTokenCount,
            contextBudgetTokens: contextBudgetTokens
        )
    }

    nonisolated private func logRAGInjectionInfo(_ info: Msg.RAGInjectionInfo) {
        let method = info.method?.rawValue ?? "pending"
        Task {
            await logger.log(
                "[Prompt][RAG] method=\(method) stage=\(info.stage.rawValue) configured=\(info.configuredContextTokens) reserved=\(info.reservedResponseTokens) usable=\(info.contextBudgetTokens) requested=\(info.requestedMaxChunks) retrieved=\(info.retrievedChunkCount) injected=\(info.injectedChunkCount) trimmed=\(info.trimmedChunkCount) partial=\(info.partialChunkInjected) injectedTokens=\(info.injectedContextTokens) reason=\(info.decisionReason)"
            )
        }
    }

    nonisolated static func shouldDiscardCancelledAssistantPlaceholder(_ message: Msg) -> Bool {
        let visibleText = message.trimmedVisibleAssistantText
        let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
        let hasWebHits = !(message.webHits?.isEmpty ?? true)
        let hasWebError = !(message.webError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return message.role == "🤖"
            && visibleText.isEmpty
            && !hasToolCalls
            && !hasWebHits
            && !hasWebError
    }

    nonisolated static func removingCancelledAssistantPlaceholder(from messages: [Msg]) -> [Msg] {
        guard let last = messages.last else { return messages }
        guard shouldDiscardCancelledAssistantPlaceholder(last) else { return messages }
        return Array(messages.dropLast())
    }

    /// True when the active remote session is currently routing over Cloud
    /// Relay (CloudKit). In that mode the host does not forward incremental
    /// prompt-prefill progress to us, so the prompt-processing card would just
    /// sit at 0% — we show a plain spinner instead.
    var isCloudRelayTransportActive: Bool {
        guard let session = modelManager?.activeRemoteSession else { return false }
        if case .cloudRelay = session.transport { return true }
        return false
    }

    /// Whether the prompt-processing progress card should be used for the
    /// active run. Only on-device gguf/CoreAI runs report incremental
    /// prompt-prefill progress; Cloud Relay (CloudKit) sends none, so we fall
    /// back to the generic spinner there.
    var supportsPromptProcessingCard: Bool {
        (loadedFormat == .gguf || loadedFormat == .coreai) && !isCloudRelayTransportActive
    }

    func startPromptProcessing(for messageIndex: Int) {
        guard loadedFormat == .gguf, !isCloudRelayTransportActive else { return }
        updateStreamMessage(at: messageIndex) { message in
            message.promptProcessing = .init(progress: 0)
        }
    }

    func updatePromptProcessingProgress(_ progress: Double, messageIndex: Int) {
        let clamped = min(1.0, max(0.0, progress))
        guard streamMsgs.indices.contains(messageIndex) else { return }
        let current = streamMsgs[messageIndex].promptProcessing?.progress ?? 0
        guard streamMsgs[messageIndex].streaming,
              streamMsgs[messageIndex].promptProcessing != nil,
              clamped >= current else { return }
        updateStreamMessage(at: messageIndex) { message in
            message.promptProcessing = .init(progress: clamped)
        }
    }

    func clearPromptProcessing(for messageIndex: Int) {
        updateStreamMessage(at: messageIndex) { message in
            message.promptProcessing = nil
        }
    }

    private func finalizeAssistantStream(
        runID: Int,
        messageIndex: Int,
        cleanedText: String,
        pendingToolJSON: String?,
        perfResult: Msg.Perf?,
        tokenCount: Int,
        generationStart: Date,
        firstTokenTimestamp: Date?,
        isMLXFormat: Bool
    ) {
        guard runID == activeRunID,
              streamMsgs.indices.contains(messageIndex) else { return }

        let existingVisibleText = streamMsgs[messageIndex].trimmedVisibleAssistantText
        let displayText: String
        if cleanedText.isEmpty, pendingToolJSON != nil {
            displayText = ""
        } else if pendingToolJSON == nil, !existingVisibleText.isEmpty {
            displayText = streamMsgs[messageIndex].text
        } else {
            let normalized = finalizeVisibleAssistantText(
                cleanedText,
                toolCalls: streamMsgs[messageIndex].toolCalls
            )
            displayText = normalized.isEmpty ? "(no output)" : normalized
        }

        streamMsgs[messageIndex].text = displayText
        streamMsgs[messageIndex].streaming = false
        streamMsgs[messageIndex].promptProcessing = nil
        // Streaming finished for this segment: stop rendering the bubble from the store so
        // it falls back to the committed `sessions` text. (A tool continuation re-begins it.)
        streamingStore.finish()
        clearStopAfterParagraphRequest()
        if let perfResult {
            streamMsgs[messageIndex].perf = perfResult
        }

        if pendingToolJSON == nil {
#if os(iOS)
            if strictFinalAnswerText(for: streamMsgs[messageIndex]) != nil {
                Haptics.successLight()
            }
#endif
            AccessibilityAnnouncer.announceLocalized("Response generated.")
            markRollingThoughtsInterrupted(forMessageAt: messageIndex)
        }

        if verboseLogging {
            print("[ChatVM] BOT ✓ \(displayText.prefix(80))…")
        }

        let ttfbStr: String = {
            guard let firstTokenTimestamp else { return "n/a" }
            return String(format: "%.2fs", firstTokenTimestamp.timeIntervalSince(generationStart))
        }()
        let tokenRateStr: String = {
            guard let perfResult else { return "n/a" }
            return String(format: "%.2f tok/s", perfResult.avgTokPerSec)
        }()
        let loggedTokenCount = perfResult?.tokenCount ?? tokenCount

        let botText = streamMsgs[messageIndex].text
        let logPrefix = "[ChatVM] BOT ✓ tokens=\(loggedTokenCount) ttfb=\(ttfbStr) rate=\(tokenRateStr)"
        Task {
            if isMLXFormat {
                let logMessage = "\(logPrefix)\n\(botText)"
                await logger.log(logMessage, truncateConsole: false)
            } else {
                let previewLimit = 120
                let preview = String(botText.prefix(previewLimit))
                let suffix = botText.count > previewLimit ? "…" : ""
                let logMessage = "\(logPrefix) preview=\(preview)\(suffix)"
                await logger.log(logMessage)
            }
        }

        let clearDelay: TimeInterval = 2.0
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(clearDelay * 1_000_000_000))
            if runID == self.activeRunID {
                self.injectionStage = .none
                self.injectionMethod = nil
            }
        }
    }

    private func finalizeVisibleAssistantText(
        _ text: String,
        toolCalls: [Msg.ToolCall]?
    ) -> String {
        visibleAssistantText(from: text)
    }

    func resolvedVisiblePostToolFinalText(
        existingVisibleText: String,
        fallbackText: String,
        toolCalls: [Msg.ToolCall]?
    ) -> String {
        let sanitizedExistingVisibleText = visibleAssistantText(from: existingVisibleText)
        let trimmedExistingVisibleText = sanitizedExistingVisibleText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedExistingVisibleText.isEmpty {
            return sanitizedExistingVisibleText
        }

        let fallbackVisibleText = finalizeVisibleAssistantText(
            fallbackText,
            toolCalls: toolCalls
        )
        let trimmedFallbackVisibleText = fallbackVisibleText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallbackVisibleText.isEmpty {
            return fallbackVisibleText
        }

        return sanitizedExistingVisibleText
    }

    private func scrubEmbeddedToolArtifactsWithoutDispatch(
        in text: String,
        messageIndex: Int?,
        maxPasses: Int = 4
    ) async -> String {
        var cleaned = text
        var pass = 0
        while pass < maxPasses,
              let result = await interceptEmbeddedToolCallIfPresent(
                in: cleaned,
                messageIndex: messageIndex,
                chatVM: self,
                handlingMode: .scrubOnly
              ) {
            cleaned = result.cleanedText
            pass += 1
        }
        return visibleAssistantText(from: cleaned)
    }

    func postToolContinuationNudge(toolName: String?, originalQuestion: String) -> String {
        let trimmedQuestion = originalQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToolName = toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        var lines = [
            "Use the latest tool result to answer the user's original question directly.",
            "Only call another tool if the current result is empty, malformed, or clearly insufficient."
        ]

        if normalizedToolName.contains("python") {
            lines.insert("The Python result is authoritative for the computation that was run.", at: 1)
        }

        if !trimmedQuestion.isEmpty {
            lines.append("Original question: \(trimmedQuestion)")
        }

        return lines.joined(separator: "\n")
    }

    /// Custom prompt template loaded from model configuration
    var promptTemplate: String?
    var promptTemplateSourceLabel: String = PromptTemplateSource.defaultTemplate.rawValue
    var inferenceBackendSummary: String?
    
    /// Rolling thought view models for active thinking boxes
    @Published var rollingThoughtViewModels: [String: RollingThoughtViewModel] = [:]

    @AppStorage("systemPreset") private var systemPresetRaw = SystemPreset.general.rawValue

    // Expose whether current model supports tool calling
    public var currentModelFormat: ModelFormat? { loadedFormat }
    public var isSLMModel: Bool { loadedFormat == .et }
    var supportsToolsFlag: Bool {
        UserDefaults.standard.object(forKey: "currentModelSupportsFunctionCalling") as? Bool ?? false
    }
    private var pendingAFMToolSummary: AFMToolExecutionSummary?
    private var pendingAFMRouteInfo: AFMTurnRouteInfo?
    /// Live AFM client while an `.afm` model is loaded; consulted by the
    /// context preflight so PCC's larger window lifts the local 4K/8K limit.
    private var activeAFMClient: AFMLLMClient?
    private var activeTurnScratchpadSnapshot: String?

    private func applyPendingAFMRouteInfo(to messageIndex: Int) {
        guard let info = pendingAFMRouteInfo else { return }
        pendingAFMRouteInfo = nil
        guard streamMsgs.indices.contains(messageIndex) else { return }
        if info.route == .privateCloudCompute {
            streamMsgs[messageIndex].ranOnPrivateCloudCompute = true
        } else if info.fellBackToOnDevice {
            // Stayed (or finished) on-device; the accurate Local Only badge
            // already applies. Just leave a trace for diagnostics.
            print("[AFM][Route] PCC requested but turn fell back on-device (escalated=\(info.escalatedMidTurn))")
        }
    }

    private func applyPendingAFMToolSummary(to messageIndex: Int) {
        guard streamMsgs.indices.contains(messageIndex) else {
            pendingAFMToolSummary = nil
            return
        }
        guard let summary = pendingAFMToolSummary, !summary.isEmpty else { return }

        let resolved = AFMToolExecutionMapper.resolve(summary)
        let mappedCalls = resolved.calls.map { call in
            Msg.ToolCall(
                toolName: call.toolName,
                displayName: call.displayName,
                iconName: call.iconName,
                requestParams: call.requestParams,
                phase: .completed,
                result: call.result,
                error: call.error,
                timestamp: call.timestamp
            )
        }
        streamMsgs[messageIndex].toolCalls = (streamMsgs[messageIndex].toolCalls ?? []) + mappedCalls
        if resolved.usedWebSearch {
            streamMsgs[messageIndex].usedWebSearch = true
            streamMsgs[messageIndex].webHits = chatWebHits(from: resolved.webHits)
            streamMsgs[messageIndex].webError = resolved.webError
            ReviewPrompter.shared.noteWebSearchUsed()
            ReviewPrompter.shared.safeMaybePromptIfEligible(chatVM: self)
        }
        pendingAFMToolSummary = nil
    }

    private func chatWebHits(from hits: [WebHit]?) -> [Msg.WebHit]? {
        guard let hits, !hits.isEmpty else { return nil }
        return hits.enumerated().map { index, hit in
            let engine = hit.engine.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedEngine = engine.isEmpty ? "searxng" : engine
            return Msg.WebHit(
                id: String(index + 1),
                title: hit.title,
                snippet: hit.snippet,
                url: hit.url,
                engine: resolvedEngine,
                score: hit.score ?? 0
            )
        }
    }

    private func normalizedDatasetID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func datasetID(for session: Session) -> String? {
        if session.datasetID != nil {
            // Session-level setting is authoritative; empty string means explicitly disabled.
            return normalizedDatasetID(session.datasetID)
        }
        if let inherited = session.messages.reversed().first(where: {
            let role = $0.role.lowercased()
            return role == "user" || role == "🧑‍💻"
        })?.datasetID {
            return normalizedDatasetID(inherited)
        }
        return nil
    }

    private func resolvedDataset(for datasetID: String?) -> LocalDataset? {
        guard let datasetID else { return nil }
        if let ds = datasetManager?.datasets.first(where: { $0.datasetID == datasetID }) {
            return ds
        }
        if let ds = modelManager?.downloadedDatasets.first(where: { $0.datasetID == datasetID }) {
            return ds
        }
        return nil
    }

    private func datasetForSession(_ session: Session) -> LocalDataset? {
        resolvedDataset(for: datasetID(for: session))
    }

    private var activeSessionDatasetAny: LocalDataset? {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return nil }
        return datasetForSession(sessions[idx])
    }

    var activeSessionDataset: LocalDataset? {
        activeSessionDatasetAny
    }

    private var activeSessionIndexedDataset: LocalDataset? {
        guard let ds = activeSessionDatasetAny,
              ds.isIndexed else { return nil }
        return ds
    }

    private var activeSessionRetrievalDataset: LocalDataset? {
        guard activeToolPermissions.datasetRetrieval else { return nil }
        return activeSessionIndexedDataset
    }

    private var effectiveEditableSystemPromptIntro: String? {
        let globalIntro = SystemPreset.resolvedEditableIntro(from: customSystemPromptIntro)
        guard let loadedSettings else { return globalIntro }

        switch loadedSettings.systemPromptMode {
        case .inheritGlobal:
            return globalIntro
        case .override:
            return SystemPreset.trimmedEditableIntro(from: loadedSettings.systemPromptOverride) ?? globalIntro
        case .excludeGlobal:
            return nil
        }
    }

    private func renderSystemPromptText(
        using dataset: LocalDataset?,
        toolAvailability: ToolAvailability,
        includeThinkRestriction: Bool,
        memorySnapshot: String?,
        scratchpadSnapshot: String?,
        editableIntro: String?
    ) -> String {
        // If a dataset is active (RAG), prefer the RAG preset and exclude tool guidance.
        if let ds = dataset {
            // Ensure no accidental anti-reasoning directives like "/nothink" are present.
            var base = SystemPreset.ragText(editableIntro: editableIntro)
            base = sanitizeSystemPrompt(base)
            let rawDocumentTitle = ds.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ds.datasetID : ds.name
            let documentTitle = rawDocumentTitle
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            base += "\n\nRAG context for this turn: you were given retrieved passages from \"\(documentTitle)\". If the user asks what document you currently have access to, answer with this title: \"\(documentTitle)\"."
            // Vision guard: when using a vision-capable model without any attached images,
            // explicitly instruct the model to behave as text-only to avoid hallucinated visuals.
            if supportsImageInput && pendingImageURLs.isEmpty {
                base += "\n\nIMPORTANT: No image is provided unless explicitly attached. Answer as a text-only assistant. Do not infer, imagine, or describe any images."
            } else if supportsImageInput && !pendingImageURLs.isEmpty {
                let n = pendingImageURLs.count
                let plural = n == 1 ? "image" : "images"
                base += "\n\nVision: \(n) \(plural) attached. Use them to answer the question. Describe only what is actually present. If unsure, say you are unsure. Do not invent details."
            }
            SystemPromptResolver.appendToolGuidance(
                to: &base,
                availability: toolAvailability,
                includeThinkRestriction: includeThinkRestriction,
                memorySnapshot: memorySnapshot
            )
            appendChatBehaviorGuidance(to: &base)
            appendScratchpadGuidance(to: &base, scratchpadSnapshot: scratchpadSnapshot)
            return base
        }
        let attachedCount = supportsImageInput ? pendingImageURLs.count : 0
        let hasAttachedImages = supportsImageInput && attachedCount > 0
        var base = SystemPromptResolver.general(
            currentFormat: loadedFormat,
            isVisionCapable: supportsImageInput,
            hasAttachedImages: hasAttachedImages,
            attachedImageCount: hasAttachedImages ? attachedCount : nil,
            includeThinkRestriction: includeThinkRestriction,
            toolAvailabilityOverride: toolAvailability,
            memorySnapshot: memorySnapshot,
            editableIntro: editableIntro
        )
        appendChatBehaviorGuidance(to: &base)
        appendScratchpadGuidance(to: &base, scratchpadSnapshot: scratchpadSnapshot)
        return base
    }

    private func appendChatBehaviorGuidance(to prompt: inout String) {
        if let guidance = activeChatMode.promptGuidance {
            prompt += "\n\n\(guidance)"
        }
        if let guidance = activeAnswerStyle.promptGuidance {
            prompt += "\n\n\(guidance)"
        }
        let instructions = activeChatInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            prompt += "\n\nPer-chat instructions: \(instructions)"
        }
    }

    private func appendScratchpadGuidance(to prompt: inout String, scratchpadSnapshot: String?) {
        guard let scratchpadSnapshot = scratchpadSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scratchpadSnapshot.isEmpty else { return }
        prompt += """

        Referenced private scratchpad and pinned results:
        The user explicitly referenced saved, pinned, bookmarked, or scratchpad context for this turn. Use the following local chat notes as context. Do not mention this section unless it helps answer the user.

        \(scratchpadSnapshot)
        """
    }

    private func referencedScratchpadSnapshot(for userInput: String) -> String? {
        let snapshot = activeScratchpad.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshot.isEmpty else { return nil }
        let normalized = userInput.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let referenceTerms = [
            "scratchpad",
            "pinned",
            "saved note",
            "saved result",
            "bookmark",
            "bookmarked",
            "that result",
            "the result you saved"
        ]
        guard referenceTerms.contains(where: { normalized.contains($0) }) else { return nil }
        return snapshot
    }

    private func resolveMemoryPromptBudget(
        using dataset: LocalDataset?,
        history: [Msg]?,
        toolAvailability: ToolAvailability,
        includeThinkRestriction: Bool
    ) -> MemoryPromptBudgetPlan {
        let isActive = toolAvailability.memory && hasActiveChatModel
        let allEntries = MemoryStore.shared.entries
        guard isActive else { return MemoryPromptBudgetPlan(entries: [], status: .inactive) }

        let effectiveHistory = history ?? msgs
        let basePrompt = renderSystemPromptText(
            using: dataset,
            toolAvailability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction,
            memorySnapshot: nil,
            scratchpadSnapshot: activeTurnScratchpadSnapshot,
            editableIntro: effectiveEditableSystemPromptIntro
        )
        let basePromptTokens = estimatedPromptTokens(
            for: effectiveHistory,
            systemPrompt: basePrompt
        )
        let promptLimit = contextSoftLimitTokens()

        return MemoryPromptBudgeter.plan(
            entries: allEntries,
            isActive: true,
            promptTokenLimit: promptLimit,
            basePromptTokens: basePromptTokens
        ) { candidateEntries in
            let snapshot = MemoryStore.promptSnapshot(entries: candidateEntries)
            let prompt = renderSystemPromptText(
                using: dataset,
                toolAvailability: toolAvailability,
                includeThinkRestriction: includeThinkRestriction,
                memorySnapshot: snapshot,
                scratchpadSnapshot: activeTurnScratchpadSnapshot,
                editableIntro: effectiveEditableSystemPromptIntro
            )
            return estimatedPromptTokens(for: effectiveHistory, systemPrompt: prompt)
        }
    }

    private func resolvedSystemPromptContext(
        using dataset: LocalDataset?,
        history: [Msg]? = nil
    ) -> (text: String, memoryPlan: MemoryPromptBudgetPlan) {
        let rawToolAvailability = systemPromptToolAvailabilityOverride ?? ToolAvailability.current(currentFormat: loadedFormat)
        let toolAvailability = activeToolPermissions.filtered(rawToolAvailability)
        let includeThinkRestriction = activeRemoteBackendID == nil
        let memoryPlan = resolveMemoryPromptBudget(
            using: dataset,
            history: history,
            toolAvailability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction
        )
        let text = renderSystemPromptText(
            using: dataset,
            toolAvailability: toolAvailability,
            includeThinkRestriction: includeThinkRestriction,
            memorySnapshot: memoryPlan.snapshot,
            scratchpadSnapshot: activeTurnScratchpadSnapshot,
            editableIntro: effectiveEditableSystemPromptIntro
        )
        return (text: text, memoryPlan: memoryPlan)
    }

    private func makeSystemPromptText(using dataset: LocalDataset?, history: [Msg]? = nil) -> String {
        resolvedSystemPromptContext(using: dataset, history: history).text
    }

    /// Returns the active system prompt text based on user settings.
    var systemPromptText: String {
        makeSystemPromptText(using: activeSessionRetrievalDataset)
    }

    private var baselineSystemPromptText: String {
        makeSystemPromptText(using: nil)
    }

    /// Removes any accidental anti-reasoning directives such as "/nothink" from the system prompt
    /// while preserving the intended guidance (we rely on <think> tags to contain reasoning).
    private func sanitizeSystemPrompt(_ s: String) -> String {
        var t = s
        // Remove common variants of nothink flags if present
        let patterns = ["/nothink", "\\bnothink\\b", "no-think", "no think"]
        for p in patterns {
            if let rx = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: (t as NSString).length)
                t = rx.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: "")
            } else {
                t = t.replacingOccurrences(of: p, with: "", options: .caseInsensitive)
            }
        }
        // Normalize whitespace after removals
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private(set) var currentKind: ModelKind = .other
    private var usePrompt = true

    private var gemmaAutoTemplated = false
    private var runCounter = 0
    private var activeRunID = 0
    // Persist the same Leap Conversation across tool calls; no reset flags
    private var currentStreamTask: Task<Void, Never>?
    private var currentContextTask: Task<ResolvedRAGContext?, Never>?
    private var titleTask: Task<Void, Never>?
    private var currentContinuationTask: Task<Void, Never>?
    private var stopAfterParagraphBaselineCharacterCount: Int?
    private var lastTitledMessageID: UUID?
    private var lastTitledHash: Int?
    private var loadedURL: URL?
    private var loadedSettings: ModelSettings? {
        didSet {
            refreshSystemPromptForActiveSession()
        }
    }
    private var loadedFormat: ModelFormat? {
        didSet {
            refreshSystemPromptForActiveSession()
        }
    }

    var loadedModelURL: URL? { loadedURL }
    var loadedModelSettings: ModelSettings? { loadedSettings }
    var loadedModelFormat: ModelFormat? { loadedFormat }
    private var currentInjectedTokenOverhead: Int = 0

    func setLoadedStateForTesting(
        modelLoaded: Bool? = nil,
        loadedURL: URL? = nil,
        loadedFormat: ModelFormat? = nil,
        loadedSettings: ModelSettings? = nil
    ) {
        if let modelLoaded {
            self.modelLoaded = modelLoaded
        }
        self.loadedURL = loadedURL
        self.loadedFormat = loadedFormat
        if let loadedSettings {
            self.loadedSettings = loadedSettings.normalizedSystemPromptSettings()
        }
    }

    func setClientForTesting(
        _ client: AnyLLMClient?,
        modelLoaded: Bool? = nil,
        loadedURL: URL? = nil,
        loadedFormat: ModelFormat? = nil,
        loadedSettings: ModelSettings? = nil
    ) {
        self.client = client
        if let modelLoaded {
            self.modelLoaded = modelLoaded
        }
        self.loadedURL = loadedURL
        self.loadedFormat = loadedFormat
        if let loadedSettings {
            self.loadedSettings = loadedSettings.normalizedSystemPromptSettings()
        }
    }

    func setStreamSessionIndexForTesting(_ index: Int?) {
        streamSessionIndex = index
    }

    func syncActiveLocalModelPromptSettingsIfNeeded(model: LocalModel, settings: ModelSettings) {
        guard activeRemoteBackendID == nil,
              let loadedURL,
              let loadedFormat else { return }

        let normalizedLoadedURL = InstalledModelsStore.canonicalURL(for: loadedURL, format: loadedFormat)
        let normalizedModelURL = InstalledModelsStore.canonicalURL(for: model.url, format: model.format)
        guard normalizedLoadedURL == normalizedModelURL else { return }

        applyActivePromptSettings(settings)
    }

    func syncActiveRemoteModelPromptSettingsIfNeeded(
        backendID: RemoteBackend.ID,
        modelID: String,
        settings: ModelSettings
    ) {
        let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard activeRemoteBackendID == backendID,
              activeRemoteModelID == normalizedModelID else { return }

        applyActivePromptSettings(settings)
    }

    private func applyActivePromptSettings(_ settings: ModelSettings) {
        let normalized = settings.normalizedSystemPromptSettings()
        var updatedSettings = loadedSettings ?? normalized
        updatedSettings.systemPromptMode = normalized.systemPromptMode
        updatedSettings.systemPromptOverride = normalized.systemPromptOverride
        loadedSettings = updatedSettings

        guard let client,
              loadedFormat == .et || loadedFormat == .ane || loadedFormat == .afm else {
            return
        }

        let prompt = systemPromptText
        Task {
            await client.syncSystemPrompt(prompt)
        }
    }

    /// Reference to the global model manager so the chat view model can access
    /// the currently selected dataset for RAG lookups.
    weak var modelManager: AppModelManager? {
        didSet {
            syncModelManagerDatasetForActiveSession()
        }
    }
    /// Dataset manager used to track indexing status while performing
    /// retrieval or injection. Held weakly since it is owned by the
    /// main view hierarchy.
    weak var datasetManager: DatasetManager?

    private var client: AnyLLMClient?
    private var remoteService: RemoteChatService?
    private var activeRemoteBackendID: RemoteBackend.ID?
    private var activeRemoteModelID: String?
    private var remoteLoadingPending = false
    private var toolSpecsCache: [ToolSpec] = []
    private var systemPromptToolAvailabilityOverride: ToolAvailability?
    private var promptRefreshCancellables: Set<AnyCancellable> = []
#if canImport(AVFoundation)
    private var audioRecorder: AVAudioRecorder?
    private var audioRecordingURL: URL?
    private var audioRecordingFriendlyName: String?
    private var audioRecordingMeterTask: Task<Void, Never>?
#endif
    private var mediaTranscriptionTasks: [ChatMediaAttachment.ID: Task<Void, Never>] = [:]
    
    @AppStorage("verboseLogging") private var verboseLogging = false
    @AppStorage("ragMaxChunks") private var ragMaxChunks = 5
    @AppStorage("ragMinScore") private var ragMinScore = 0.5
    @AppStorage("ragRetrievalMode") private var ragRetrievalModeRaw = DatasetRetrievalMode.defaultValue.rawValue
    @AppStorage("contextOverflowStrategy") private var contextOverflowStrategyRaw = ContextOverflowStrategy.defaultValue.rawValue
    @AppStorage(ChatAttachmentCleanupPolicy.storageKey) private var attachmentCleanupPolicyRaw = ChatAttachmentCleanupPolicy.defaultValue.rawValue
    @AppStorage(SystemPreset.customSystemPromptIntroKey) private var customSystemPromptIntro = SystemPreset.defaultEditableIntro

    private var fullDatasetContentCache: [String: String] = [:]
    private var lastResolvedSystemPromptIntro = SystemPreset.resolvedEditableIntro(userDefaults: .standard)

    init() {
        if let data = try? Data(contentsOf: Self.sessionsURL()),
           let decoded = try? JSONDecoder().decode([Session].self, from: data),
           !decoded.isEmpty {
            sessions = decoded
            activeSessionID = decoded.first?.id
        } else {
            let system = Msg(role: "system", text: systemPromptText, timestamp: Date())
            let first = Session(title: "New chat", messages: [system], date: Date(), datasetID: "")
            sessions = [first]
            activeSessionID = first.id
        }
        if migrateLegacyAttachmentPathsIfNeeded() {
            saveSessions()
        }
        _ = garbageCollectAttachmentFilesIfNeeded(force: false)
        // Recreate rolling thought view models for loaded sessions
        recreateRollingThoughtViewModels()
        syncModelManagerDatasetForActiveSession()
        refreshSystemPromptForActiveSession()
        scheduleSpotlightChatTitleIndex()
        // Ensure tools are registered early so calls are executable during the first run
        initializeToolSystem()
        NotificationCenter.default.publisher(for: .memoryStoreDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.toolSpecsCache = []
                    if let remoteService = self.remoteService {
                        let specs = await self.fetchEnabledToolSpecs()
                        self.systemPromptToolAvailabilityOverride = self.toolAvailability(from: specs)
                        await remoteService.updateToolSpecs(specs)
                    } else {
                        self.systemPromptToolAvailabilityOverride = nil
                    }
                    self.refreshSystemPromptForActiveSession()
                    if let client = self.client,
                       self.loadedFormat == .et || self.loadedFormat == .ane || self.loadedFormat == .afm {
                        await client.syncSystemPrompt(self.systemPromptText)
                    }
                }
            }
            .store(in: &promptRefreshCancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let resolvedIntro = SystemPreset.resolvedEditableIntro(from: self.customSystemPromptIntro)
                    guard resolvedIntro != self.lastResolvedSystemPromptIntro else { return }
                    self.lastResolvedSystemPromptIntro = resolvedIntro
                    self.refreshSystemPromptForActiveSession()
                    if let client = self.client,
                       self.loadedFormat == .et || self.loadedFormat == .ane || self.loadedFormat == .afm {
                        await client.syncSystemPrompt(self.systemPromptText)
                    }
                }
            }
            .store(in: &promptRefreshCancellables)
    }

    private static func sessionsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions.json")
    }

    private static let attachmentCleanupLastRunKey = "chatAttachmentCleanupLastRun"

    private static func attachmentStorageDirectory() -> URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChatAttachments", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func legacyTemporaryAttachmentDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("noema_images", isDirectory: true)
    }

    @discardableResult
    private func migrateLegacyAttachmentPathsIfNeeded() -> Bool {
        let fm = FileManager.default
        let legacyDir = Self.legacyTemporaryAttachmentDirectory().standardizedFileURL.path
        let persistentDirURL = Self.attachmentStorageDirectory().standardizedFileURL
        let legacyPrefix = legacyDir.hasSuffix("/") ? legacyDir : (legacyDir + "/")

        var updatedSessions = sessions
        var changed = false

        for sIdx in updatedSessions.indices {
            for mIdx in updatedSessions[sIdx].messages.indices {
                guard var paths = updatedSessions[sIdx].messages[mIdx].imagePaths, !paths.isEmpty else { continue }
                var messageChanged = false

                for pIdx in paths.indices {
                    let sourceURL = URL(fileURLWithPath: paths[pIdx]).standardizedFileURL
                    let sourcePath = sourceURL.path
                    guard sourcePath == legacyDir || sourcePath.hasPrefix(legacyPrefix) else { continue }

                    let destinationURL = persistentDirURL.appendingPathComponent(sourceURL.lastPathComponent)
                    let destinationPath = destinationURL.path
                    guard sourcePath != destinationPath else { continue }

                    if fm.fileExists(atPath: sourcePath) {
                        if !fm.fileExists(atPath: destinationPath) {
                            do {
                                try fm.copyItem(at: sourceURL, to: destinationURL)
                            } catch {
                                continue
                            }
                        }
                        paths[pIdx] = destinationPath
                        messageChanged = true
                    } else if fm.fileExists(atPath: destinationPath) {
                        paths[pIdx] = destinationPath
                        messageChanged = true
                    }
                }

                if messageChanged {
                    updatedSessions[sIdx].messages[mIdx].imagePaths = paths
                    changed = true
                }
            }
        }

        guard changed else { return false }
        sessions = updatedSessions
        return true
    }

    private var attachmentCleanupPolicy: ChatAttachmentCleanupPolicy {
        ChatAttachmentCleanupPolicy.from(attachmentCleanupPolicyRaw)
    }

    private static func normalizedAttachmentPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isPath(_ path: String, inside directory: URL) -> Bool {
        let normalizedPath = normalizedAttachmentPath(path)
        let normalizedDirectory = directory.standardizedFileURL.path
        let prefix = normalizedDirectory.hasSuffix("/") ? normalizedDirectory : (normalizedDirectory + "/")
        return normalizedPath == normalizedDirectory || normalizedPath.hasPrefix(prefix)
    }

    private static func isManagedAttachmentPath(_ path: String) -> Bool {
        isPath(path, inside: attachmentStorageDirectory()) || isPath(path, inside: legacyTemporaryAttachmentDirectory())
    }

    private func referencedAttachmentPaths(excludingSessionID: Session.ID? = nil) -> Set<String> {
        var refs = Set<String>()
        for session in sessions {
            if let excludingSessionID, session.id == excludingSessionID { continue }
            for message in session.messages {
                for path in message.imagePaths ?? [] {
                    refs.insert(Self.normalizedAttachmentPath(path))
                }
                for attachment in message.mediaAttachments ?? [] {
                    refs.insert(Self.normalizedAttachmentPath(attachment.storedPath))
                    if let sidecar = attachment.transcriptSidecarPath {
                        refs.insert(Self.normalizedAttachmentPath(sidecar))
                    }
                }
            }
        }
        return refs
    }

    @discardableResult
    private func deleteAttachmentFiles(atPaths paths: Set<String>, reason: String) -> Int {
        let fm = FileManager.default
        var removed = 0

        for rawPath in paths {
            let path = Self.normalizedAttachmentPath(rawPath)
            guard Self.isManagedAttachmentPath(path) else { continue }
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: path) else { continue }
            do {
                try fm.removeItem(at: url)
                pendingImageURLs.removeAll { Self.normalizedAttachmentPath($0.path) == path }
                pendingMediaAttachments.removeAll { attachment in
                    Self.normalizedAttachmentPath(attachment.storedPath) == path
                        || attachment.transcriptSidecarPath.map { Self.normalizedAttachmentPath($0) == path } == true
                }
                pendingThumbnails = pendingThumbnails.filter { Self.normalizedAttachmentPath($0.key.path) != path }
                ImageThumbnailCache.shared.clear(for: path)
                removed += 1
            } catch {
                continue
            }
        }

        if removed > 0 {
            Task { await logger.log("[Images][Cleanup] removed=\(removed) reason=\(reason)") }
        }
        return removed
    }

    private func periodicAttachmentCleanupInterval(for policy: ChatAttachmentCleanupPolicy) -> TimeInterval? {
        switch policy {
        case .immediate, .daily:
            return 60 * 60 * 24
        case .weekly:
            return 60 * 60 * 24 * 7
        case .never:
            return nil
        }
    }

    @discardableResult
    private func garbageCollectAttachmentFilesIfNeeded(force: Bool) -> Int {
        let policy = attachmentCleanupPolicy
        guard force || policy != .never else { return 0 }

        if !force {
            guard let interval = periodicAttachmentCleanupInterval(for: policy) else { return 0 }
            if let lastRun = UserDefaults.standard.object(forKey: Self.attachmentCleanupLastRunKey) as? Date,
               Date().timeIntervalSince(lastRun) < interval {
                return 0
            }
        }

        let fm = FileManager.default
        let referenced = referencedAttachmentPaths()
        let directories = [Self.attachmentStorageDirectory(), Self.legacyTemporaryAttachmentDirectory()]
        var candidates = Set<String>()

        for directory in directories {
            guard fm.fileExists(atPath: directory.path) else { continue }
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files {
                let isRegular = (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? true
                guard isRegular else { continue }
                let path = Self.normalizedAttachmentPath(file.path)
                if !referenced.contains(path) {
                    candidates.insert(path)
                }
            }
        }

        let removed = deleteAttachmentFiles(atPaths: candidates, reason: "periodic-gc:\(policy.rawValue)")
        UserDefaults.standard.set(Date(), forKey: Self.attachmentCleanupLastRunKey)
        return removed
    }

    func runAttachmentGarbageCollectionNow() {
        _ = garbageCollectAttachmentFilesIfNeeded(force: true)
    }

    private func saveSessions() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: Self.sessionsURL())
        }
        scheduleSpotlightChatTitleIndex()
    }

    private func scheduleSpotlightChatTitleIndex() {
        let records = sessions.map { session in
            let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = trimmedTitle.isEmpty ? String(localized: "New chat") : trimmedTitle
            return NoemaSpotlightIndexRecord(
                uniqueIdentifier: NoemaSpotlightIndexingService.chatIdentifier(for: session.id),
                title: title,
                contentDescription: String(localized: "Noema chat"),
                keywords: ["Noema", "chat"]
            )
        }
        NoemaSpotlightIndexingService.shared.scheduleChatTitleIndex(records: records)
    }

    private func syncModelManagerDatasetForActiveSession() {
        guard let modelManager else { return }
        let target = activeSessionDatasetAny
        if modelManager.activeDataset?.datasetID == target?.datasetID { return }
        modelManager.setActiveDataset(target)
    }

    private func refreshSystemPromptForActiveSession(historyOverride: [Msg]? = nil) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else {
            memoryPromptBudgetStatus = .inactive
            return
        }
        let context = resolvedSystemPromptContext(
            using: activeSessionRetrievalDataset,
            history: historyOverride ?? sessions[idx].messages
        )
        memoryPromptBudgetStatus = context.memoryPlan.status
        if let firstSystemIndex = sessions[idx].messages.firstIndex(where: { $0.role.lowercased() == "system" }) {
            sessions[idx].messages[firstSystemIndex].text = context.text
        } else {
            sessions[idx].messages.insert(Msg(role: "system", text: context.text, timestamp: Date()), at: 0)
        }
    }

    func setDatasetForActiveSession(_ ds: LocalDataset?) {
        modelManager?.setActiveDataset(ds)
        if let idx = activeIndex, sessions.indices.contains(idx) {
            sessions[idx].datasetID = ds?.datasetID ?? ""
        }
        if ds == nil {
            currentInjectedTokenOverhead = 0
        }
        refreshSystemPromptForActiveSession()
    }

    private static func defaultTitle(date: Date = .now) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
    private var activeIndex: Int? {
        guard let id = activeSessionID else { return nil }
        return sessions.firstIndex { $0.id == id }
    }

    var activeToolPermissions: ChatToolPermissions {
        guard let idx = activeIndex, sessions.indices.contains(idx) else {
            return .allEnabled
        }
        return sessions[idx].toolPermissions ?? .allEnabled
    }

    var activeScratchpad: String {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return "" }
        return sessions[idx].scratchpad ?? ""
    }

    var activeChatInstructions: String {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return "" }
        return sessions[idx].chatInstructions ?? ""
    }

    var activeChatMode: ChatMode {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return .general }
        return sessions[idx].chatMode ?? .general
    }

    var activeAnswerStyle: AnswerStyle {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return .natural }
        return sessions[idx].answerStyle ?? .natural
    }

    func setScratchpadForActiveSession(_ text: String) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].scratchpad = trimmed.isEmpty ? nil : text
    }

    func pinMessageTextToActiveScratchpad(_ text: String, role: String, timestamp: Date) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let roleTitle: String
        if role == "🧑‍💻" || role.lowercased() == "user" {
            roleTitle = String(localized: "User")
        } else if role == "🤖" || role.lowercased() == "assistant" {
            roleTitle = String(localized: "Assistant")
        } else {
            roleTitle = String(localized: "Message")
        }
        let title = String.localizedStringWithFormat(String(localized: "Pinned %@ message"), roleTitle)
        let date = DateFormatter.localizedString(from: timestamp, dateStyle: .medium, timeStyle: .short)
        let block = "### \(title) - \(date)\n\(trimmed)"
        let existing = (sessions[idx].scratchpad ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].scratchpad = existing.isEmpty ? block : existing + "\n\n" + block
    }

    func pinToolCallToActiveScratchpad(_ toolCall: Msg.ToolCall) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }

        let resultText = toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines)
        let errorText = toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard resultText?.isEmpty == false || errorText?.isEmpty == false else { return }

        let title = String.localizedStringWithFormat(String(localized: "Pinned %@ result"), toolCall.displayName)
        let date = DateFormatter.localizedString(from: toolCall.timestamp, dateStyle: .medium, timeStyle: .short)
        var sections = [
            "### \(title) - \(date)",
            "\(String(localized: "Tool")): \(toolCall.toolName)"
        ]
        if let resultText, !resultText.isEmpty {
            sections.append("\(String(localized: "Result")):\n\(ToolCallViewSupport.formatRawResult(resultText))")
        }
        if let errorText, !errorText.isEmpty {
            sections.append("\(String(localized: "Error")):\n\(errorText)")
        }
        let block = sections.joined(separator: "\n\n")
        let existing = (sessions[idx].scratchpad ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].scratchpad = existing.isEmpty ? block : existing + "\n\n" + block
    }

    func requestToolCallRepair(_ toolCall: Msg.ToolCall) async {
        guard canAcceptChatInput else { return }
        guard !isStreamingInAnotherSession else {
            crossSessionSendBlocked = true
            return
        }

        var details = [
            "\(String(localized: "Tool")): \(toolCall.toolName)"
        ]
        if !toolCall.requestParams.isEmpty {
            let params = toolCall.requestParams.keys.sorted().map { key in
                "\(key): \(ToolCallViewSupport.formatParameterValue(toolCall.requestParams[key]?.value))"
            }.joined(separator: "\n")
            details.append("\(String(localized: "Request Parameters")):\n\(params)")
        }
        if let error = toolCall.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            details.append("\(String(localized: "Error")):\n\(error)")
        }
        if let result = toolCall.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
            details.append("\(String(localized: "Raw Response")):\n\(ToolCallViewSupport.formatRawResult(result))")
        }

        let prompt = String.localizedStringWithFormat(
            String(localized: "Repair this failed tool call. Explain what likely went wrong, propose corrected arguments, and rerun the tool only if it is safe and useful.\n\n%@"),
            details.joined(separator: "\n\n")
        )
        await sendMessage(prompt)
    }

    func setChatInstructionsForActiveSession(_ text: String) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].chatInstructions = trimmed.isEmpty ? nil : text
        refreshSystemPromptForActiveSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.client, self.modelLoaded {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    func setChatModeForActiveSession(_ mode: ChatMode) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        sessions[idx].chatMode = mode == .general ? nil : mode
        refreshSystemPromptForActiveSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.client, self.modelLoaded {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    func setAnswerStyleForActiveSession(_ style: AnswerStyle) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        sessions[idx].answerStyle = style == .natural ? nil : style
        refreshSystemPromptForActiveSession()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let client = self.client, self.modelLoaded {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    func setToolPermissionForActiveSession(_ kind: ChatToolPermissionKind, enabled: Bool) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        var permissions = sessions[idx].toolPermissions ?? .allEnabled
        switch kind {
        case .webSearch:
            permissions.webSearch = enabled
        case .python:
            permissions.python = enabled
        case .memory:
            permissions.memory = enabled
        case .datasetRetrieval:
            permissions.datasetRetrieval = enabled
        }
        applyToolPermissionsToActiveSession(permissions)
    }

    func setAllToolPermissionsForActiveSession(enabled: Bool) {
        applyToolPermissionsToActiveSession(enabled ? .allEnabled : .allDisabled)
    }

    private func applyToolPermissionsToActiveSession(_ permissions: ChatToolPermissions) {
        guard let idx = activeIndex, sessions.indices.contains(idx) else { return }
        sessions[idx].toolPermissions = permissions
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.toolSpecsCache = []
            self.systemPromptToolAvailabilityOverride = nil
            if let remoteService = self.remoteService {
                let specs = await self.fetchEnabledToolSpecs()
                await remoteService.updateToolSpecs(specs)
                let availability = self.toolAvailability(from: specs)
                self.systemPromptToolAvailabilityOverride = availability.any ? availability : nil
            }
            self.refreshSystemPromptForActiveSession()
            if let client = self.client,
               self.loadedFormat == .et || self.loadedFormat == .ane || self.loadedFormat == .afm {
                await client.syncSystemPrompt(self.systemPromptText)
            }
        }
    }

    private var streamSessionIndex: Int?

    /// Live text of the in-flight assistant message. Token updates flow here instead of
    /// into `sessions` so they don't force every observer of `ChatVM` to re-render.
    /// Held as a plain `let` so updates don't trip `ChatVM.objectWillChange`.
    let streamingStore = StreamingMessageStore()

    var streamMsgs: [Msg] {
        get {
            if let idx = streamSessionIndex, sessions.indices.contains(idx) {
                return sessions[idx].messages
            }
            return msgs
        }
        set {
            if let idx = streamSessionIndex, sessions.indices.contains(idx) {
                sessions[idx].messages = newValue
            } else {
                msgs = newValue
            }
        }
    }

    var msgs: [Msg] {
        get { activeIndex.flatMap { sessions[$0].messages } ?? [] }
        set {
            if let idx = activeIndex { sessions[idx].messages = newValue }
        }
    }

    func toggleBookmark(messageID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { session in
            session.messages.contains(where: { $0.id == messageID })
        }),
        let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        sessions[sessionIndex].messages[messageIndex].isBookmarked.toggle()
    }

    func regenerateAssistantResponse(messageID: UUID) async {
        guard !isStreamingInAnotherSession else {
            crossSessionSendBlocked = true
            return
        }
        guard let sessionIndex = activeIndex,
              sessions.indices.contains(sessionIndex),
              let assistantIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }

        let message = sessions[sessionIndex].messages[assistantIndex]
        guard message.role == "🤖" || message.role.lowercased() == "assistant" else { return }
        guard let userIndex = sessions[sessionIndex].messages[..<assistantIndex].lastIndex(where: { candidate in
            candidate.role == "🧑‍💻" || candidate.role.lowercased() == "user"
        }) else { return }

        let userMessage = sessions[sessionIndex].messages[userIndex]
        let text = userMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        currentStreamTask?.cancel()
        currentContinuationTask?.cancel()
        streamSessionIndex = nil
        sessions[sessionIndex].messages = Array(sessions[sessionIndex].messages.prefix(userIndex))
        refreshSystemPromptForActiveSession()
        await sendMessage(text)
    }

    @discardableResult
    func prepareAskSamePromptWithAnotherModel(messageID: UUID) -> Bool {
        guard let sourceIndex = activeIndex,
              sessions.indices.contains(sourceIndex),
              let assistantIndex = sessions[sourceIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return false
        }

        let message = sessions[sourceIndex].messages[assistantIndex]
        guard message.role == "🤖" || message.role.lowercased() == "assistant" else { return false }
        guard let userIndex = sessions[sourceIndex].messages[..<assistantIndex].lastIndex(where: { candidate in
            candidate.role == "🧑‍💻" || candidate.role.lowercased() == "user"
        }) else { return false }

        let userMessage = sessions[sourceIndex].messages[userIndex]
        let text = userMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }

        let source = sessions[sourceIndex]
        var branchedMessages = Array(source.messages.prefix(userIndex))
        if !branchedMessages.contains(where: { $0.role.lowercased() == "system" }) {
            branchedMessages.insert(Msg(role: "system", text: baselineSystemPromptText, timestamp: Date()), at: 0)
        }

        let sourceTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = Self.defaultTitle()
        let branchTitle = String.localizedStringWithFormat(
            String(localized: "Compare: %@"),
            sourceTitle.isEmpty ? fallbackTitle : sourceTitle
        )
        let branch = Session(
            title: branchTitle,
            messages: branchedMessages,
            date: Date(),
            datasetID: source.datasetID,
            toolPermissions: source.toolPermissions,
            scratchpad: source.scratchpad,
            chatMode: source.chatMode,
            answerStyle: source.answerStyle,
            chatInstructions: source.chatInstructions
        )

        sessions.insert(branch, at: 0)
        activeSessionID = branch.id
        prompt = text
        injectionStage = .none
        injectionMethod = nil
        refreshSystemPromptForActiveSession()
        return true
    }

    var isStreaming: Bool { msgs.last?.streaming == true }

    var isStreamingInAnotherSession: Bool {
        guard let streamIdx = streamSessionIndex else { return false }
        if let activeIdx = activeIndex, streamIdx == activeIdx { return false }
        guard sessions.indices.contains(streamIdx) else { return false }
        return sessions[streamIdx].messages.last?.streaming == true
    }

    var totalTokens: Int {
        let base = msgs.compactMap { $0.perf?.tokenCount }.reduce(0, +)
        var extra = 0
        // Include injected dataset token overhead
        extra += max(0, currentInjectedTokenOverhead)
        // Include system prompt tokens (fast sync estimate)
        extra += estimateTokensSync(systemPromptText)
        // Include all user prompt tokens (fast sync estimate)
        let userText = msgs.filter { $0.role == "🧑‍💻" || $0.role.lowercased() == "user" }.map { $0.text }.joined(separator: "\n")
        extra += estimateTokensSync(userText)
        // Include web/tool result tokens (reinjected into prompt as <tool_response> blocks)
        let toolText = msgs.last?.toolCalls?
            .compactMap { $0.result }
            .joined(separator: "\n") ?? ""
        extra += estimateTokensSync(toolText)
        // Include dataset RAG injected context tokens only when not already counted via full injection overhead
        if currentInjectedTokenOverhead == 0, let ctx = msgs.last?.retrievedContext, !ctx.isEmpty {
            extra += estimateTokensSync(ctx)
        }
        return base + extra
    }

    private func estimateTokensSync(_ text: String) -> Int {
        // Conservative chars-per-token estimate (~3.5). Observed ratios are 4.4–4.9
        // for English text with chat templates, so this intentionally overestimates
        // to ensure preflight trimming catches context overflow before the server rejects.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return max(1, Int(ceil(Double(trimmed.utf8.count) / 3.5)))
    }

    /// Exact token count via the loopback server's `/tokenize` endpoint.
    /// Returns nil when the server is not running or the call fails.
    private func tokenCountViaServer(_ text: String) async -> Int? {
        let port = Int(LlamaServerBridge.port())
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/tokenize") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 5
        let body: [String: Any] = ["content": text, "add_special": true, "parse_special": true]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData
        guard !NetworkKillSwitch.shouldBlock(request: req) else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [AnyHashable: Any]()
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [Any] else { return nil }
        return tokens.count
    }

    var contextLimit: Double { loadedSettings?.contextLength ?? 4096 }
    private var contextOverflowStrategy: ContextOverflowStrategy {
        ContextOverflowStrategy.from(contextOverflowStrategyRaw)
    }

    var contextOverflowAlertBody: String {
        guard let banner = contextOverflowBanner else {
            return String(localized: "The model context window was exceeded.")
        }
        var lines: [String] = [NSLocalizedString(banner.strategy.overflowActionKey, comment: "")]
        if let promptTokens = banner.promptTokens, let contextTokens = banner.contextTokens {
            let promptString = NumberFormatter.localizedString(from: NSNumber(value: promptTokens), number: .decimal)
            let contextString = NumberFormatter.localizedString(from: NSNumber(value: contextTokens), number: .decimal)
            let tokenLine = String.localizedStringWithFormat(
                String(localized: "Prompt tokens: %@ • Context limit: %@."),
                promptString,
                contextString
            )
            lines.append(tokenLine)
        } else if let contextTokens = banner.contextTokens {
            let contextString = NumberFormatter.localizedString(from: NSNumber(value: contextTokens), number: .decimal)
            let tokenLine = String.localizedStringWithFormat(
                String(localized: "Context limit: %@ tokens."),
                contextString
            )
            lines.append(tokenLine)
        }
        lines.append(NSLocalizedString(banner.strategy.overflowDeteriorationKey, comment: ""))
        return lines.joined(separator: "\n\n")
    }

    func contextOverflowBanner(for sessionID: Session.ID) -> ContextOverflowBannerState? {
        contextOverflowBanners[sessionID]
    }

    func registerContextOverflowForTesting(
        strategy: ContextOverflowStrategy = .stopAtLimit,
        promptTokens: Int? = nil,
        contextTokens: Int? = nil,
        rawMessage: String = "test-overflow"
    ) {
        let details = ContextOverflowDetails(
            promptTokens: promptTokens,
            contextTokens: contextTokens,
            rawMessage: rawMessage
        )
        registerContextOverflow(strategy: strategy, details: details)
    }

    private var currentStreamOrActiveSessionID: Session.ID? {
        if let streamSessionIndex, sessions.indices.contains(streamSessionIndex) {
            return sessions[streamSessionIndex].id
        }
        return activeSessionID
    }

    private func registerContextOverflow(strategy: ContextOverflowStrategy, details: ContextOverflowDetails?) {
        guard let sessionID = currentStreamOrActiveSessionID else { return }
        let fallbackContext = currentPromptBudget().usablePromptTokens
        var banners = contextOverflowBanners
        banners[sessionID] = ContextOverflowBannerState(
            strategy: strategy,
            promptTokens: details?.promptTokens,
            contextTokens: details?.contextTokens ?? fallbackContext,
            timestamp: Date()
        )
        contextOverflowBanners = banners
    }

    /// Drop the overflow pill once a turn fits within the budget again, so it
    /// always reflects the most recent send rather than sticking forever.
    private func clearContextOverflowForCurrentStream() {
        guard let sessionID = currentStreamOrActiveSessionID,
              contextOverflowBanners[sessionID] != nil else { return }
        var banners = contextOverflowBanners
        banners.removeValue(forKey: sessionID)
        contextOverflowBanners = banners
    }

    /// User-initiated dismissal from the status pill.
    func dismissActiveContextOverflowBanner() {
        guard let sessionID = activeSessionID,
              contextOverflowBanners[sessionID] != nil else { return }
        var banners = contextOverflowBanners
        banners.removeValue(forKey: sessionID)
        contextOverflowBanners = banners
    }

    private func contextStopMessage(details: ContextOverflowDetails?) -> String {
        if let promptTokens = details?.promptTokens, let contextTokens = details?.contextTokens {
            let promptString = NumberFormatter.localizedString(from: NSNumber(value: promptTokens), number: .decimal)
            let contextString = NumberFormatter.localizedString(from: NSNumber(value: contextTokens), number: .decimal)
            return String.localizedStringWithFormat(
                String(localized: "Context Length Exceeded (%@ > %@ tokens). Stop at Limit is enabled, so this turn was not sent."),
                promptString,
                contextString
            )
        }
        return String(localized: "Context Length Exceeded. Stop at Limit is enabled, so this turn was not sent.")
    }

    private func contextFallbackMessage(for strategy: ContextOverflowStrategy) -> String {
        switch strategy {
        case .truncateMiddle:
            return String(localized: "Context Length Exceeded. Middle turns were trimmed, but the prompt is still too large. Increase context length or shorten this chat.")
        case .rollingWindow:
            return String(localized: "Context Length Exceeded. Older turns were trimmed, but the prompt is still too large. Increase context length or shorten this chat.")
        case .stopAtLimit:
            return String(localized: "Context Length Exceeded. Stop at Limit is enabled, so generation was halted before sending.")
        }
    }

    private func extractFirstInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else { return nil }
        let tokenRange = match.range(at: 1)
        guard tokenRange.location != NSNotFound else { return nil }
        return Int(nsText.substring(with: tokenRange))
    }

    private func parseContextOverflowDetails(from message: String) -> ContextOverflowDetails? {
        let lower = message.lowercased()
        let looksLikeOverflow = lower.contains("exceed_context_size_error")
            || (lower.contains("context") && lower.contains("exceed"))
            || lower.contains("available context size")
            // Multimodal prompt overflow: "input (N tokens) is larger than the max context size (M tokens)"
            || lower.contains("larger than the max context size")
        guard looksLikeOverflow else { return nil }

        let promptTokens =
            extractFirstInt(in: message, pattern: #""n_prompt_tokens"\s*:\s*(\d+)"#)
            ?? extractFirstInt(in: message, pattern: #"request\s*\((\d+)\s*tokens\)"#)
            ?? extractFirstInt(in: message, pattern: #"input\s*\((\d+)\s*tokens\)"#)
        let contextTokens =
            extractFirstInt(in: message, pattern: #""n_ctx"\s*:\s*(\d+)"#)
            ?? extractFirstInt(in: message, pattern: #"context size\s*\((\d+)\s*tokens\)"#)

        return ContextOverflowDetails(promptTokens: promptTokens, contextTokens: contextTokens, rawMessage: message)
    }

    private func renderedPromptForEstimation(history: [Msg], systemPrompt: String) -> String {
        if loadedFormat == .et {
            let latestUser = history.reversed().first(where: { role in
                let normalized = role.role.lowercased()
                return normalized == "user" || normalized == "🧑‍💻"
            })?.text ?? ""
            return systemPrompt + "\n" + latestUser
        }

        // Match the reconstructed tool messages used when actually building the
        // request so the token estimate doesn't undercount the replayed results.
        let rendered = prepareForGeneration(
            messages: historyWithReconstructedToolMessages(history),
            system: systemPrompt
        )
        switch rendered {
        case .plain(let prompt):
            return prompt
        case .messages(let arr):
            let msgs: [ChatVM.Msg] = arr.map { ChatVM.Msg(role: $0.role, text: $0.content) }
            let (prompt, _, _) = PromptBuilder.build(template: promptTemplate, family: currentKind, messages: msgs)
            return prompt
        }
    }

    private func estimatedPromptTokens(for history: [Msg]) -> Int {
        estimateTokensSync(renderedPromptForEstimation(history: history, systemPrompt: systemPromptText))
    }

    private func estimatedPromptTokens(for history: [Msg], systemPrompt: String) -> Int {
        estimateTokensSync(renderedPromptForEstimation(history: history, systemPrompt: systemPrompt))
    }

    private func contextSoftLimitTokens() -> Int {
        currentPromptBudget().usablePromptTokens
    }

    static func afmPreflight(history: [Msg], estimateTokens: ([Msg]) -> Int, contextLimit: Int = 4096) -> AFMContextPreflight {
        let budget = promptBudget(for: Double(contextLimit))
        let promptTokens = estimateTokens(history)
        let stopMessage: String? = promptTokens > budget.usablePromptTokens
            ? "AFM context limit reached (\(budget.usablePromptTokens) tokens). Start a new chat or shorten the conversation."
            : nil
        return AFMContextPreflight(
            history: history,
            promptTokens: promptTokens,
            contextLimit: budget.usablePromptTokens,
            stopMessage: stopMessage
        )
    }

    private func removableHistoryIndices(for history: [Msg]) -> [Int] {
        guard history.count > 3 else { return [] }
        let newestUserIndex = history.lastIndex(where: { msg in
            let role = msg.role.lowercased()
            return role == "user" || role == "🧑‍💻"
        })
        let assistantPlaceholderIndex = history.lastIndex(where: { msg in
            msg.role == "🤖" && msg.streaming
        })

        return history.indices.filter { idx in
            if idx == 0 { return false } // Always keep the first system message.
            if let newestUserIndex, idx == newestUserIndex { return false }
            if let assistantPlaceholderIndex, idx == assistantPlaceholderIndex { return false }
            if history[idx].role.lowercased() == "system" { return false }
            return true
        }
    }

    /// Last-resort trim when no whole message can be removed (e.g. a single
    /// pasted document larger than the context window): shrink the largest
    /// trimmable message body in place, honoring the strategy — rolling window
    /// keeps the tail, truncate-middle keeps head + tail. Returns false when
    /// nothing useful can be shrunk further.
    private func shrinkOversizedMessageForContext(
        _ history: inout [Msg],
        strategy: ContextOverflowStrategy,
        promptTokens: Int,
        tokenLimit: Int
    ) -> Bool {
        guard promptTokens > tokenLimit else { return false }
        let shrinkableIndices = history.indices.filter { idx in
            let role = history[idx].role.lowercased()
            if role == "system" { return false }
            if history[idx].role == "🤖" && history[idx].streaming { return false }
            return !history[idx].text.isEmpty
        }
        guard let idx = shrinkableIndices.max(by: { history[$0].text.count < history[$1].text.count }) else {
            return false
        }
        let text = history[idx].text
        // Scale the text down proportionally to the overage, with a safety margin.
        let ratio = max(0.05, min(0.85, (Double(tokenLimit) / Double(promptTokens)) * 0.85))
        let targetCount = Int(Double(text.count) * ratio)
        // Below this size shrinking just destroys the message without fixing anything.
        guard targetCount >= 160, targetCount < text.count else { return false }
        let marker = "\n[… trimmed to fit the context window …]\n"
        switch strategy {
        case .rollingWindow:
            history[idx].text = marker + String(text.suffix(targetCount))
        case .truncateMiddle, .stopAtLimit:
            let head = targetCount / 2
            let tail = targetCount - head
            history[idx].text = String(text.prefix(head)) + marker + String(text.suffix(tail))
        }
        return true
    }

    private func planHistoryForContextOverflow(history: [Msg]) -> ContextHistoryPlan {
        let limit = contextSoftLimitTokens()
        let strategy = contextOverflowStrategy
        let initialEstimate = estimatedPromptTokens(for: history)

        guard initialEstimate > limit else {
            return ContextHistoryPlan(
                history: history,
                initialEstimate: initialEstimate,
                finalEstimate: initialEstimate,
                trimmed: false,
                requiresStop: false
            )
        }

        if strategy == .stopAtLimit {
            return ContextHistoryPlan(
                history: history,
                initialEstimate: initialEstimate,
                finalEstimate: initialEstimate,
                trimmed: false,
                requiresStop: true
            )
        }

        var working = history
        var finalEstimate = initialEstimate
        var trimmed = false
        var iterations = 0
        while finalEstimate > limit, iterations < 256 {
            let candidates = removableHistoryIndices(for: working)
            if !candidates.isEmpty {
                let removalIndex: Int
                switch strategy {
                case .truncateMiddle:
                    removalIndex = candidates[candidates.count / 2]
                case .rollingWindow:
                    removalIndex = candidates[0]
                case .stopAtLimit:
                    removalIndex = candidates[0]
                }
                working.remove(at: removalIndex)
            } else if !shrinkOversizedMessageForContext(
                &working,
                strategy: strategy,
                promptTokens: finalEstimate,
                tokenLimit: limit
            ) {
                break
            }
            trimmed = true
            finalEstimate = estimatedPromptTokens(for: working)
            iterations += 1
        }

        return ContextHistoryPlan(
            history: working,
            initialEstimate: initialEstimate,
            finalEstimate: finalEstimate,
            trimmed: trimmed,
            requiresStop: finalEstimate > limit
        )
    }

    func select(_ session: Session) {
        activeSessionID = session.id
    }

    func focus(onMessageWithID id: UUID) {
        spotlightMessageID = id
    }

    @discardableResult
    func branchSession(fromMessageID messageID: UUID) -> Session? {
        guard let sourceIndex = activeIndex,
              sessions.indices.contains(sourceIndex),
              let messageIndex = sessions[sourceIndex].messages.firstIndex(where: { $0.id == messageID }) else {
            return nil
        }

        currentStreamTask?.cancel()
        gemmaAutoTemplated = false

        let source = sessions[sourceIndex]
        var branchedMessages = Array(source.messages.prefix(messageIndex + 1))
        if !branchedMessages.contains(where: { $0.role.lowercased() == "system" }) {
            branchedMessages.insert(Msg(role: "system", text: baselineSystemPromptText, timestamp: Date()), at: 0)
        }
        for index in branchedMessages.indices {
            branchedMessages[index].streaming = false
            branchedMessages[index].promptProcessing = nil
            branchedMessages[index].postToolWaiting = false
        }

        let sourceTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackTitle = Self.defaultTitle()
        let branchTitle = String.localizedStringWithFormat(
            String(localized: "Branch: %@"),
            sourceTitle.isEmpty ? fallbackTitle : sourceTitle
        )
        let branch = Session(
            title: branchTitle,
            messages: branchedMessages,
            date: Date(),
            datasetID: source.datasetID,
            toolPermissions: source.toolPermissions,
            scratchpad: source.scratchpad,
            chatMode: source.chatMode,
            answerStyle: source.answerStyle,
            chatInstructions: source.chatInstructions
        )

        sessions.insert(branch, at: 0)
        activeSessionID = branch.id
        injectionStage = .none
        injectionMethod = nil
        refreshSystemPromptForActiveSession()
        return branch
    }

    func startNewSession() {
        currentStreamTask?.cancel()
        gemmaAutoTemplated = false
        let system = Msg(role: "system", text: baselineSystemPromptText, timestamp: Date())
        let new = Session(title: "New chat", messages: [system], date: Date(), datasetID: "")
        sessions.insert(new, at: 0)
        activeSessionID = new.id
        injectionStage = .none
        injectionMethod = nil
        
        // Randomize seed per session without persisting unless user set it
        if let model = modelManager?.loadedModel {
            let settings = modelManager?.settings(for: model) ?? ModelSettings.default(for: model.format)
            if modelLoaded {
                if let explicitSeed = settings.seed, explicitSeed != 0 {
                    // Respect user-provided seed
                    setenv("LLAMA_SEED", String(explicitSeed), 1)
                } else {
                    // Use a random seed for this session only (do not persist)
                    setenv("LLAMA_SEED", String(Int.random(in: 1...999_999)), 1)
                }
            }
        }
    }

    func delete(_ session: Session) {
        currentStreamTask?.cancel()
        let deletedSessionPaths: Set<String> = Set(
            session.messages
                .compactMap(\.imagePaths)
                .flatMap { $0.map(Self.normalizedAttachmentPath) }
        )
        sessions.removeAll { $0.id == session.id }
        var banners = contextOverflowBanners
        banners.removeValue(forKey: session.id)
        contextOverflowBanners = banners
        if attachmentCleanupPolicy == .immediate {
            let stillReferenced = referencedAttachmentPaths()
            let orphaned = deletedSessionPaths.subtracting(stillReferenced)
            _ = deleteAttachmentFiles(atPaths: orphaned, reason: "chat-delete")
        }
        _ = garbageCollectAttachmentFilesIfNeeded(force: false)
        if activeSessionID == session.id {
            activeSessionID = sessions.first?.id
        }
    }

    func clearChatHistory() {
        currentStreamTask?.cancel()
        let existing = sessions
        for session in existing {
            delete(session)
        }
        if sessions.isEmpty {
            startNewSession()
        }
    }

    func toggleFavorite(_ session: Session) {
        guard let idx = sessions.firstIndex(of: session) else { return }
        sessions[idx].isFavorite.toggle()
    }

    @MainActor
    func resolveLoadURL(for model: LocalModel) -> URL {
        resolveLoadURL(for: model.url, explicitFormat: model.format, modelHint: model).url
    }

    struct PreparedModelLoad {
        let url: URL
        let format: ModelFormat
        let settings: ModelSettings?
        let promptTemplateSource: String?
    }

    @MainActor
    private func displayLoadName(for originalURL: URL, format: ModelFormat?) -> String {
        let resolved = resolveLoadURL(for: originalURL, explicitFormat: format)
        let canonicalURL: URL = {
            switch resolved.format {
            case .gguf:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .gguf)
            case .mlx:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .mlx)
            case .et:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .et)
            case .ane:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .ane)
            case .afm:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .afm)
            case .coreai:
                return InstalledModelsStore.canonicalURL(for: resolved.url, format: .coreai)
            }
        }()

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: canonicalURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return canonicalURL.lastPathComponent
        }

        return canonicalURL.deletingPathExtension().lastPathComponent
    }

    @MainActor
    func resolveLoadURL(
        for originalURL: URL,
        explicitFormat: ModelFormat?,
        modelHint: LocalModel? = nil
    ) -> (url: URL, format: ModelFormat) {
        let detectedFmt = explicitFormat ?? ModelFormat.detect(from: originalURL)
        var loadURL = originalURL

        if detectedFmt == .gguf {
            let quantLabel = QuantExtractor.shortLabel(from: originalURL.lastPathComponent, format: .gguf).lowercased()
            if quantLabel.starts(with: "q") {
                setenv("LLAMA_METAL_KQUANTS", quantLabel, 1)
            } else {
                setenv("LLAMA_METAL_KQUANTS", "", 1)
            }

            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue, let alt = InstalledModelsStore.firstGGUF(in: loadURL) {
                loadURL = alt
            }

            var effectiveIsDir: ObjCBool = false
            let effectiveExists = FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &effectiveIsDir)
            let isValid = effectiveExists && (effectiveIsDir.boolValue || InstalledModelsStore.isValidGGUF(at: loadURL))
            if !isValid {
                let managerModel = modelManager?.downloadedModels.first(where: { candidate in
                    candidate.url == originalURL
                        || candidate.url == loadURL
                        || candidate.url.deletingLastPathComponent() == originalURL
                        || candidate.url.deletingLastPathComponent() == loadURL
                })
                let modelID = modelHint?.modelID
                    ?? managerModel?.modelID
                    ?? inferRepoID(from: loadURL)
                    ?? loadURL.deletingLastPathComponent().lastPathComponent
                let base = InstalledModelsStore.baseDir(for: .gguf, modelID: modelID)
                if let alt = InstalledModelsStore.firstGGUF(in: base) {
                    loadURL = alt
                }
            }
        } else {
            setenv("LLAMA_METAL_KQUANTS", "", 1)
        }

        return (loadURL, detectedFmt)
    }


    @MainActor
    func prepareLoad(
        for originalURL: URL,
        settings: ModelSettings?,
        format: ModelFormat?,
        modelHint: LocalModel? = nil
    ) async throws -> PreparedModelLoad {
        let resolution = resolveLoadURL(for: originalURL, explicitFormat: format, modelHint: modelHint)
        var loadURL = resolution.url
        let detectedFmt = resolution.format

        if detectedFmt != .afm {
            guard FileManager.default.fileExists(atPath: loadURL.path) else {
                throw NSError(domain: "Noema", code: 404, userInfo: [NSLocalizedDescriptionKey: "Model not downloaded"])
            }
        }

        var finalSettings = settings
        var promptTemplateSource = PromptTemplateSource.defaultTemplate.rawValue

        if detectedFmt == .mlx {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir)
            if !isDir.boolValue {
                let dir = loadURL.deletingLastPathComponent()
                var dirIsDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: dir.path, isDirectory: &dirIsDir), dirIsDir.boolValue {
                    loadURL = dir
                    if verboseLogging { print("[ChatVM] Adjusted MLX URL to directory: \(dir.path)") }
                } else {
                    throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "MLX model directory missing"])
                }
            }

            if (finalSettings?.tokenizerPath ?? "").isEmpty {
                let possibleTokenizers = ["tokenizer.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
                let existing = possibleTokenizers
                    .map { loadURL.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                if let existing {
                    var s = finalSettings ?? ModelSettings.default(for: .mlx)
                    s.tokenizerPath = existing.path
                    finalSettings = s
                }
            }

            do {
                let cfg = loadURL.appendingPathComponent("config.json")
                let data = try Data(contentsOf: cfg)
                _ = try JSONSerialization.jsonObject(with: data)
            } catch {
                throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid or missing config.json in MLX model directory"])
            }

            let possibleTokenizers = ["tokenizer.json", "tokenizer.model", "spiece.model", "sentencepiece.bpe.model"]
            func isGitLFSPointer(_ url: URL) -> Bool {
                guard let d = try? Data(contentsOf: url), d.count < 4096,
                      let s = String(data: d, encoding: .utf8) else { return false }
                let lower = s.lowercased()
                return lower.contains("git-lfs") || lower.contains("oid sha256:")
            }
            var hasTokenizerAsset = possibleTokenizers.contains { name in
                let u = loadURL.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) {
                    if name == "tokenizer.json" && isGitLFSPointer(u) { return false }
                    return true
                }
                return false
            }
            if !hasTokenizerAsset {
                var repoHint: String? = nil
                if let mm = modelManager {
                    if let m = mm.downloadedModels.first(where: { $0.url == loadURL || $0.url.deletingLastPathComponent() == loadURL }) {
                        repoHint = m.modelID
                    }
                }
                let repoID = repoHint ?? inferRepoID(from: loadURL)
                if let repoID {
                    if verboseLogging { print("[ChatVM] Attempting to fetch tokenizer.json for repo: \(repoID)") }
                    await fetchTokenizer(into: loadURL, repoID: repoID)
                    hasTokenizerAsset = possibleTokenizers.contains { name in
                        let u = loadURL.appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: u.path) {
                            if name == "tokenizer.json" && isGitLFSPointer(u) { return false }
                            return true
                        }
                        return false
                    }
                }
            }
            if !hasTokenizerAsset {
                throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "Missing tokenizer assets in MLX model directory"])
            }
            if (finalSettings?.tokenizerPath ?? "").isEmpty {
                if let first = possibleTokenizers
                    .map({ loadURL.appendingPathComponent($0) })
                    .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                    var s = finalSettings ?? ModelSettings.default(for: .mlx)
                    s.tokenizerPath = first.path
                    finalSettings = s
                }
            }
            let contents = (try? FileManager.default.contentsOfDirectory(at: loadURL, includingPropertiesForKeys: nil)) ?? []
            let hasWeights = contents.contains { url in
                let ext = url.pathExtension.lowercased()
                return ext == "safetensors" || ext == "npz"
            }
            if !hasWeights {
                throw NSError(domain: "Noema", code: 400, userInfo: [NSLocalizedDescriptionKey: "No weight files (.safetensors or .npz) found in MLX model directory"])
            }
        }

        if detectedFmt == .ane {
            var isDir: ObjCBool = false
            let managerModel = modelManager?.downloadedModels.first(where: { candidate in
                candidate.url == originalURL
                    || candidate.url == loadURL
                    || candidate.url.deletingLastPathComponent() == originalURL
                    || candidate.url.deletingLastPathComponent() == loadURL
            })
            let modelID = modelHint?.modelID
                ?? managerModel?.modelID
                ?? inferRepoID(from: loadURL)
                ?? loadURL.deletingLastPathComponent().lastPathComponent

            if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                if !isDir.boolValue {
                    loadURL = loadURL.deletingLastPathComponent()
                }
            } else {
                loadURL = InstalledModelsStore.baseDir(for: .ane, modelID: modelID)
            }

            loadURL = InstalledModelsStore.canonicalURL(for: loadURL, format: .ane)
            guard InstalledModelsStore.firstANEArtifact(in: loadURL) != nil else {
                throw NSError(
                    domain: "Noema",
                    code: 400,
                    userInfo: [
                        NSLocalizedDescriptionKey: "No Core ML artifact found (.mlmodelc, .mlpackage, or .mlmodel)."
                    ]
                )
            }

            let resolvedSettings = ModelSettings.resolvedANEModelSettings(modelID: modelID, modelURL: loadURL)
            promptTemplateSource = resolvedSettings.promptTemplateSource.rawValue
            if finalSettings == nil {
                finalSettings = resolvedSettings.settings
            }
        }

        if detectedFmt == .afm {
            let state = AppleFoundationModelAvailability.current
            guard state.isSupportedDevice else {
                throw NSError(
                    domain: "Noema",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: AppleFoundationModelUnavailableReason.unsupportedDevice.message]
                )
            }
            if let reason = state.unavailableReason, !state.isAvailableNow {
                throw NSError(
                    domain: "Noema",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: reason.message]
                )
            }
            let modelID = modelHint?.modelID ?? AppleFoundationModelRegistry.modelID
            loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: modelID)
            try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
            loadURL = InstalledModelsStore.canonicalURL(for: loadURL, format: .afm)
        }

        if let fmt = format {
            switch fmt {
            case .mlx:
                finalSettings?.gpuLayers = 0
            case .gguf:
                if var s = finalSettings {
                    let layers = ModelScanner.layerCount(for: loadURL, format: .gguf)
                    let ctxMax = GGUFMetadata.contextLength(at: loadURL) ?? Int.max
                    if s.gpuLayers >= 0, layers > 0 {
                        // Only clamp when layer count is known; otherwise trust the user's value
                        s.gpuLayers = min(max(0, s.gpuLayers), layers)
                    }
                    s.contextLength = min(s.contextLength, Double(ctxMax))
                    if (s.tokenizerPath ?? "").isEmpty {
                        var isDir: ObjCBool = false
                        var modelDir = loadURL.deletingLastPathComponent()
                        if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir), isDir.boolValue {
                            modelDir = loadURL
                        }
                        let tok = modelDir.appendingPathComponent("tokenizer.json")
                        if FileManager.default.fileExists(atPath: tok.path) {
                            s.tokenizerPath = tok.path
                        }
                    }
                    finalSettings = s
                }
            case .et, .ane, .afm, .coreai:
                break
            }
        }

        if let s = finalSettings, detectedFmt == .gguf {
            applyEnvironmentVariables(from: s)
        }

        return PreparedModelLoad(
            url: loadURL,
            format: detectedFmt,
            settings: finalSettings,
            promptTemplateSource: detectedFmt == .ane ? promptTemplateSource : nil
        )
    }

    private func resolveETLoadArtifacts(url: URL, settings: ModelSettings?) throws -> ETModelResolver.LoadArtifacts {
        try ETModelResolver.resolveLoadArtifacts(for: url, settings: settings)
    }

    private func etRepairCandidate(for attemptedURL: URL, diagnostic: ETModelResolver.ArtifactDiagnostic) -> ETRepairCandidate? {
        guard diagnostic.isRepairable else { return nil }
        let modelDirectory = diagnostic.modelDirectory
        let model = modelManager?.downloadedModels.first(where: { candidate in
            candidate.format == .et && (
                candidate.url == attemptedURL
                || candidate.url == modelDirectory
                || candidate.url.deletingLastPathComponent() == modelDirectory
                || ETModelResolver.modelDirectory(for: candidate.url) == modelDirectory
            )
        })

        return ETRepairCandidate(
            modelID: model?.modelID ?? inferRepoID(from: modelDirectory) ?? "",
            quantLabel: model?.quant ?? "",
            modelURL: model?.url ?? modelDirectory,
            sourceRepoID: diagnostic.sourceRepoID
        )
    }

    private func catalogETSourceRepoID(modelID: String, quantLabel: String) async -> String? {
        guard !modelID.isEmpty else { return nil }
        guard let details = try? await ManualModelRegistry().details(for: modelID) else { return nil }
        let matching = details.quants.first { quant in
            quant.format == .et && (
                quant.label.caseInsensitiveCompare(quantLabel) == .orderedSame
                || quantLabel.isEmpty
            )
        } ?? details.quants.first(where: { $0.format == .et })
        guard let url = matching?.downloadURL else { return nil }
        return huggingFaceRepoID(from: url)
    }

    private func huggingFaceRepoID(from url: URL) -> String? {
        guard let host = url.host, host.contains("huggingface.co") else { return nil }
        var parts = url.path.split(separator: "/").filter { !$0.isEmpty }.map(String.init)
        let prefixes: Set<String> = ["repos", "api", "models"]
        while parts.count > 2, let first = parts.first, prefixes.contains(first) {
            parts.removeFirst()
        }
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    func repairPendingETArtifacts() async {
        guard let candidate = pendingETRepairCandidate else { return }
        let sourceRepo: String?
        if let existing = candidate.sourceRepoID {
            sourceRepo = existing
        } else {
            sourceRepo = await catalogETSourceRepoID(modelID: candidate.modelID, quantLabel: candidate.quantLabel)
        }
        guard sourceRepo != nil || !candidate.modelID.isEmpty else {
            loadError = String(localized: "Repair is unavailable for this ET model. Reinstall it from Explore.")
            return
        }

        loading = true
        stillLoading = false
        defer { loading = false; stillLoading = false }

        do {
            try await ModelDownloadManager().repairETArtifacts(
                modelID: candidate.modelID,
                modelURL: candidate.modelURL,
                sourceRepoID: sourceRepo
            )
            modelManager?.refresh()
            pendingETRepairCandidate = nil
            loadError = String(localized: "Repair finished. Load the ET model again.")
        } catch let diagnostic as ETModelResolver.ArtifactDiagnostic {
            pendingETRepairCandidate = etRepairCandidate(for: candidate.modelURL, diagnostic: diagnostic)
            loadError = diagnostic.userFacingMessage
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func startGGUFLoopbackServer(
        modelURL: URL,
        settings: ModelSettings,
        explicitMMProj: String?
    ) async throws -> (port: Int32, effectiveSettings: ModelSettings) {
        let mtpPath = settings.speculativeDecoding.mtpEnabled ? MtpLocator.mtpPath(alongside: modelURL) : nil
        let hasMTP = mtpPath != nil || GGUFMetadata.hasMTP(at: modelURL)
        let mtpEnabled = settings.speculativeDecoding.mtpEnabled && hasMTP
        let primaryConfiguration = TemplateDrivenModelSupport.loopbackStartConfiguration(
            modelURL: modelURL,
            ggufPath: modelURL.path,
            mmprojPath: explicitMMProj,
            mtpPath: mtpPath,
            speculativeType: mtpEnabled ? "draft-mtp" : nil,
            specDraftNMax: mtpEnabled ? Int32(settings.speculativeDecoding.resolvedMTPDraftNMax) : nil,
            specDraftNMin: mtpEnabled ? Int32(settings.speculativeDecoding.resolvedMTPDraftNMin) : nil,
            specDraftPMin: mtpEnabled ? settings.speculativeDecoding.resolvedMTPDraftPMin : nil
        )

        func start(_ configuration: LlamaServerBridge.StartConfiguration) async -> Int32 {
            await Task.detached { @Sendable () -> Int32 in
                LlamaServerBridge.stop()
                return LlamaServerBridge.start(configuration)
            }.value
        }

        let primaryPort = await start(primaryConfiguration)
        if primaryPort > 0 {
            logLastLoopbackStartOptions(prefix: "[Loopback][StartOptions][Load]")
            return (primaryPort, settings)
        }

        let diagnostics = LlamaServerBridge.lastStartDiagnostics()
        let reason = diagnostics?.message.isEmpty == false
            ? diagnostics!.message
            : (diagnostics?.code ?? "startup_failed")
        Task {
            await logger.log(
                "[Loopback] start.failed reason=\(reason) settings_unchanged=true"
            )
        }

        throw NSError(
            domain: "Noema",
            code: 2001,
            userInfo: [
                NSLocalizedDescriptionKey: LoopbackStartupPlanner.formatFailureMessage(diagnostics)
            ]
        )
    }

    private func ensureClient(
        url: URL,
        settings: ModelSettings?,
        format: ModelFormat?,
        forceReload: Bool
    ) async throws {
        if client != nil {
            guard forceReload else { return }
            // Fully unload the existing runner before starting a new load to avoid
            // llama.cpp/Metal races on iOS when models are reloaded back‑to‑back.
            await unload()
        }
        // Reset any prior loopback server and vision override. The newly selected model
        // will explicitly re-enable and restart the server if needed.
        LlamaServerBridge.stop()
        // Reset loopback vision override; the new selection will explicitly re-enable it if needed.
        LoopbackVisionState.setEnabled(false)
        let requestedFormat = format ?? ModelFormat.detect(from: url)
        loadingProgressTracker.startLoading(for: requestedFormat)
        loadingProgressTracker.reportBackendProgress(0.02)
        loading = true
        stillLoading = false
        loadError = nil
        pendingETRepairCandidate = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.loading == true { self?.stillLoading = true }
        }
        defer { loading = false; stillLoading = false }

        let prepared = try await prepareLoad(for: url, settings: settings, format: format)
        var loadURL = prepared.url
        let detectedFmt = prepared.format
        var finalSettings = prepared.settings
        if let settings = finalSettings {
            let powerDecision = GenerationPowerPolicy.adjustedSettings(settings, format: detectedFmt)
            finalSettings = powerDecision.settings
            lastGenerationPowerPolicy = powerDecision
            if powerDecision.adapted {
                Task {
                    await logger.log(
                        "[GenerationPower] adapted=true format=\(detectedFmt.rawValue) threads=\(powerDecision.originalThreadCount)->\(powerDecision.appliedThreadCount) context=\(powerDecision.originalContextLength)->\(powerDecision.appliedContextLength) reasons=\(powerDecision.reasons.map(\.rawValue).joined(separator: ","))"
                    )
                }
            }
        } else {
            lastGenerationPowerPolicy = nil
        }
        let preparedPromptTemplateSource = prepared.promptTemplateSource ?? PromptTemplateSource.defaultTemplate.rawValue
        inferenceBackendSummary = nil
        loadingProgressTracker.reportBackendProgress(0.08)

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? UInt64 {
            let sizeGB = Double(size) / 1_073_741_824.0
            let text = DeviceRAMInfo.current().limit
            if let num = Double(text.replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)),
               sizeGB > num {
                loadError = "Model may exceed available RAM (\(String(format: "%.1f", sizeGB)) GB > \(text))"
            }
        }
        if let s = finalSettings {
            if verboseLogging { print("[ChatVM] loading \(loadURL.lastPathComponent) with context \(Int(s.contextLength))") }
        } else {
            if verboseLogging {
                let kind: String = {
                    switch detectedFmt {
                    case .gguf: return "GGUF"
                    case .mlx: return "MLX"
                    case .et: return "ET"
                    case .ane: return ModelFormat.ane.displayName
                    case .afm: return "AFM"
                    case .coreai: return "Core AI"
                    }
                }()
                print("[ChatVM] loading \(kind) from \(loadURL.lastPathComponent)…")
            }
        }
        if verboseLogging { print("MODEL_LOAD_START \(Date().timeIntervalSince1970)") }

        let llamaOptions = LlamaOptions(extraEOSTokens: ["<|im_end|>", "<end_of_turn>"], verbose: true)
        // Resolve projector info next to the model (if any). Always start the
        // in‑process HTTP server bound to 127.0.0.1 for GGUF models so all GGUF
        // inference routes through the loopback server (single execution path).
        let explicitMMProj: String? = ProjectorLocator.projectorPath(alongside: loadURL)
        let hasMergedProjector: Bool = (detectedFmt == .gguf) ? GGUFMetadata.hasMultimodalProjector(at: loadURL) : false
        if detectedFmt == .gguf {
            loadingProgressTracker.reportBackendProgress(0.15)
            if finalSettings == nil {
                finalSettings = ModelSettings.default(for: .gguf)
            }
            if let effectiveSettings = finalSettings {
                applyEnvironmentVariables(from: effectiveSettings)
            }
            loadingProgressTracker.reportBackendProgress(0.22)
            let outcome = try await startGGUFLoopbackServer(
                modelURL: loadURL,
                settings: finalSettings ?? ModelSettings.default(for: .gguf),
                explicitMMProj: explicitMMProj
            )
            finalSettings = outcome.effectiveSettings
            let p = outcome.port

            if p > 0 {
                // This flag previously meant "vision is enabled via loopback".
                // GGUF inference now always routes through loopback, so treat it as
                // "loopback enabled" (UI image support is gated separately).
                LoopbackVisionState.setEnabled(true)
                let projName = explicitMMProj.map { URL(fileURLWithPath: $0).lastPathComponent } ?? (hasMergedProjector ? "merged" : "none")
                let templateLabel = TemplateDrivenModelSupport.templateLabel(modelURL: loadURL)
                if verboseLogging { print("[ChatVM] Started loopback llama.cpp server on 127.0.0.1:\(p) mmproj=\(projName)") }
                Task { await logger.log("[Loopback] start host=127.0.0.1 port=\(p) gguf=\(loadURL.lastPathComponent) mmproj=\(projName) template=\(templateLabel)") }
                loadingProgressTracker.reportBackendProgress(0.96)
            }
        }
        let contextOverride = finalSettings.map { settings -> Int in
            let clamped = max(1.0, min(settings.contextLength, Double(Int32.max)))
            return Int(clamped)
        }
        let threadOverride = finalSettings.map { settings -> Int in
            let requested = settings.cpuThreads > 0 ? settings.cpuThreads : ModelSettings.recommendedInferenceThreadCount
            // Hard-clamp so inference always leaves a core free for the UI.
            return min(max(1, requested), ModelSettings.maxInferenceThreadCount)
        }
        let llamaParameter = LlamaParameter(
            options: llamaOptions,
            contextLength: contextOverride,
            threadCount: threadOverride,
            mmproj: explicitMMProj
        )

        if let f = format {
            switch f {
            case .mlx:
                print("[ChatVM] MLX load start: \(loadURL.path)")
                SettingsStore.shared.webSearchArmed = false
                loadingProgressTracker.reportBackendProgress(0.2)
                // Choose VLM vs Text based on model contents
                if MLXBridge.isVLMModel(at: loadURL) {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeVLMClient(url: loadURL, settings: finalSettings)
                } else {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeTextClient(url: loadURL, settings: finalSettings)
                }
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .mlx
            case .gguf:
                loadingProgressTracker.reportBackendProgress(0.35)
                client = try await AnyLLMClient(
                    NoemaLlamaClient.llama(
                        url: loadURL,
                        parameter: llamaParameter
                    )
                )
                loadingProgressTracker.reportBackendProgress(0.96)
                loadedFormat = .gguf
            case .et:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "ET models are not supported on this platform.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.12)
                let artifacts = try resolveETLoadArtifacts(url: loadURL, settings: finalSettings)
                loadURL = artifacts.pteURL
                var etSettings = finalSettings ?? ModelSettings.default(for: .et)
                etSettings.etBackend = ETBackendDetector.effectiveBackend(userSelected: etSettings.etBackend, detected: nil)
                let likelyVision = artifacts.pteURL.lastPathComponent.lowercased().contains("vision")
                    || artifacts.pteURL.deletingLastPathComponent().lastPathComponent.lowercased().contains("vision")
                let etClient = ExecuTorchLLMClient(
                    modelPath: artifacts.pteURL.path,
                    tokenizerPath: artifacts.tokenizerURL.path,
                    isVision: likelyVision,
                    settings: etSettings
                )
                await etClient.syncSystemPrompt(systemPromptText)
                try await etClient.load()
                client = AnyLLMClient(etClient)
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .et
            case .ane:
                #if os(iOS) || os(visionOS)
                guard #available(iOS 18.0, visionOS 2.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "CML models require iOS 18 or visionOS 2.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try ANEModelResolver.resolve(modelURL: loadURL)
                let aneSettings = finalSettings ?? ModelSettings.default(for: .ane)
                let aneClient = try CoreMLLLMClient(resolvedModel: resolved, settings: aneSettings)
                await aneClient.syncSystemPrompt(systemPromptText)
                try await aneClient.load()
                let cmlLoadSummary = await aneClient.loadDiagnosticsSummary().map { " \($0)" } ?? ""
                let trimmedCMLLoadSummary = cmlLoadSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                inferenceBackendSummary = trimmedCMLLoadSummary.isEmpty ? nil : trimmedCMLLoadSummary
                Task {
                    await logger.log("[ChatVM][Load][CML] flavor=\(resolved.flavor.rawValue) source=\(resolved.sourceModelURL.lastPathComponent) compiled=\(resolved.compiledModelURL.lastPathComponent) templateSource=\(preparedPromptTemplateSource)\(cmlLoadSummary)")
                }
                client = AnyLLMClient(aneClient)
                loadURL = resolved.modelRoot
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .ane
                #else
                throw NSError(
                    domain: "Noema",
                    code: -2,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "CML models are supported only on iOS and visionOS.",
                            locale: LocalizationManager.preferredLocale()
                        )
                    ]
                )
                #endif
            case .afm:
                let afmClient = AFMLLMClient(
                    guardrailsMode: AFMLLMClient.resolvedGuardrailsMode(from: finalSettings),
                    privateCloudComputeMode: AFMLLMClient.resolvedPrivateCloudComputeMode(from: finalSettings),
                    onToolSummary: { [weak self] summary in
                        await MainActor.run {
                            self?.pendingAFMToolSummary = summary
                        }
                    },
                    onRouteInfo: { [weak self] info in
                        await MainActor.run {
                            self?.pendingAFMRouteInfo = info
                        }
                    }
                )
                activeAFMClient = afmClient
                await afmClient.syncSystemPrompt(systemPromptText)
                try await afmClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await afmClient.textStream(from: input)
                    },
                    cancel: nil,
                    unload: { afmClient.unload() },
                    syncSystemPrompt: { prompt in
                        await afmClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .afm
            case .coreai:
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try CoreAIModelResolver.resolve(modelURL: loadURL)
                let coreaiClient = CoreAILLMClient(
                    resolved: resolved,
                    settings: finalSettings ?? .default(for: .coreai)
                )
                await coreaiClient.syncSystemPrompt(systemPromptText)
                try await coreaiClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await coreaiClient.textStream(from: input)
                    },
                    textStreamWithProgress: { input, onPromptProgress in
                        try await coreaiClient.textStream(from: input, onPromptProgress: onPromptProgress)
                    },
                    cancel: nil,
                    unload: { coreaiClient.unload() },
                    syncSystemPrompt: { prompt in
                        await coreaiClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .coreai
            }
        } else {
            // Auto-detect format and load via appropriate client
            let detected = ModelFormat.detect(from: loadURL)
            switch detected {
            case .mlx:
                print("[ChatVM] MLX load start: \(loadURL.path)")
                SettingsStore.shared.webSearchArmed = false
                loadingProgressTracker.reportBackendProgress(0.2)
                if MLXBridge.isVLMModel(at: loadURL) {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeVLMClient(url: loadURL, settings: finalSettings)
                } else {
                    loadingProgressTracker.reportBackendProgress(0.34)
                    client = try await MLXBridge.makeTextClient(url: loadURL, settings: finalSettings)
                }
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .mlx
            case .gguf:
                loadingProgressTracker.reportBackendProgress(0.35)
                client = try await AnyLLMClient(
                    NoemaLlamaClient.llama(
                        url: loadURL,
                        parameter: llamaParameter
                    )
                )
                loadingProgressTracker.reportBackendProgress(0.96)
                loadedFormat = .gguf
            case .et:
                guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "ET models are not supported on this platform.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.12)
                let artifacts = try resolveETLoadArtifacts(url: loadURL, settings: finalSettings)
                loadURL = artifacts.pteURL
                var etSettings = finalSettings ?? ModelSettings.default(for: .et)
                etSettings.etBackend = ETBackendDetector.effectiveBackend(userSelected: etSettings.etBackend, detected: nil)
                let likelyVision = artifacts.pteURL.lastPathComponent.lowercased().contains("vision")
                    || artifacts.pteURL.deletingLastPathComponent().lastPathComponent.lowercased().contains("vision")
                let etClient = ExecuTorchLLMClient(
                    modelPath: artifacts.pteURL.path,
                    tokenizerPath: artifacts.tokenizerURL.path,
                    isVision: likelyVision,
                    settings: etSettings
                )
                await etClient.syncSystemPrompt(systemPromptText)
                try await etClient.load()
                client = AnyLLMClient(etClient)
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .et
            case .ane:
                #if os(iOS) || os(visionOS)
                guard #available(iOS 18.0, visionOS 2.0, *) else {
                    throw NSError(
                        domain: "Noema",
                        code: -2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                localized: "CML models require iOS 18 or visionOS 2.",
                                locale: LocalizationManager.preferredLocale()
                            )
                        ]
                    )
                }
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try ANEModelResolver.resolve(modelURL: loadURL)
                let aneSettings = finalSettings ?? ModelSettings.default(for: .ane)
                let aneClient = try CoreMLLLMClient(resolvedModel: resolved, settings: aneSettings)
                await aneClient.syncSystemPrompt(systemPromptText)
                try await aneClient.load()
                let cmlLoadSummary = await aneClient.loadDiagnosticsSummary().map { " \($0)" } ?? ""
                let trimmedCMLLoadSummary = cmlLoadSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                inferenceBackendSummary = trimmedCMLLoadSummary.isEmpty ? nil : trimmedCMLLoadSummary
                Task {
                    await logger.log("[ChatVM][Load][CML] flavor=\(resolved.flavor.rawValue) source=\(resolved.sourceModelURL.lastPathComponent) compiled=\(resolved.compiledModelURL.lastPathComponent) templateSource=\(preparedPromptTemplateSource)\(cmlLoadSummary)")
                }
                client = AnyLLMClient(aneClient)
                loadURL = resolved.modelRoot
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .ane
                #else
                throw NSError(
                    domain: "Noema",
                    code: -2,
                    userInfo: [
                        NSLocalizedDescriptionKey: String(
                            localized: "CML models are supported only on iOS and visionOS.",
                            locale: LocalizationManager.preferredLocale()
                        )
                    ]
                )
                #endif
            case .afm:
                let afmClient = AFMLLMClient(
                    guardrailsMode: AFMLLMClient.resolvedGuardrailsMode(from: finalSettings),
                    privateCloudComputeMode: AFMLLMClient.resolvedPrivateCloudComputeMode(from: finalSettings),
                    onToolSummary: { [weak self] summary in
                        await MainActor.run {
                            self?.pendingAFMToolSummary = summary
                        }
                    },
                    onRouteInfo: { [weak self] info in
                        await MainActor.run {
                            self?.pendingAFMRouteInfo = info
                        }
                    }
                )
                activeAFMClient = afmClient
                await afmClient.syncSystemPrompt(systemPromptText)
                try await afmClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await afmClient.textStream(from: input)
                    },
                    cancel: nil,
                    unload: { afmClient.unload() },
                    syncSystemPrompt: { prompt in
                        await afmClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .afm
            case .coreai:
                loadingProgressTracker.reportBackendProgress(0.14)
                let resolved = try CoreAIModelResolver.resolve(modelURL: loadURL)
                let coreaiClient = CoreAILLMClient(
                    resolved: resolved,
                    settings: finalSettings ?? .default(for: .coreai)
                )
                await coreaiClient.syncSystemPrompt(systemPromptText)
                try await coreaiClient.load()
                client = AnyLLMClient(
                    textStream: { input in
                        try await coreaiClient.textStream(from: input)
                    },
                    textStreamWithProgress: { input, onPromptProgress in
                        try await coreaiClient.textStream(from: input, onPromptProgress: onPromptProgress)
                    },
                    cancel: nil,
                    unload: { coreaiClient.unload() },
                    syncSystemPrompt: { prompt in
                        await coreaiClient.syncSystemPrompt(prompt)
                    }
                )
                loadingProgressTracker.reportBackendProgress(0.95)
                loadedFormat = .coreai
            }
        }

        currentKind = ModelKind.detect(id: url.lastPathComponent)
        usePrompt = true
        gemmaAutoTemplated = false
        loadedURL = loadURL
        loadedSettings = finalSettings ?? ModelSettings.default(for: loadedFormat ?? .gguf)
        promptTemplateSourceLabel = prepared.promptTemplateSource
            ?? ((loadedSettings?.promptTemplate?.isEmpty == false) ? "custom" : PromptTemplateSource.defaultTemplate.rawValue)

        modelLoaded = true
        AccessibilityAnnouncer.announceLocalized("Model loaded.")

        // Update image-input capability from stored metadata.
        // Only advertise image input when we *know* the selected model is vision-capable.
        var imageDetectNotes: [String] = []
        if let loadedModel = modelManager?.downloadedModels.first(where: { $0.url == loadURL }) {
            let storedVision = loadedModel.isMultimodal
            imageDetectNotes.append("store.isMultimodal=\(storedVision)")
            if storedVision {
                if loadedFormat == .gguf {
                    // For GGUF VLMs, require a projector either merged in the GGUF or present as a sibling file.
                    let hasProj = (ProjectorLocator.projectorPath(alongside: loadURL) != nil) || GGUFMetadata.hasMultimodalProjector(at: loadURL)
                    supportsImageInput = hasProj
                    imageDetectNotes.append("gguf.projector=\(hasProj)")
                } else {
                    supportsImageInput = true
                }
            } else if loadedFormat == .et {
                let inferredVision = LeapCatalogService.isVisionQuantizationSlug(loadedModel.modelID) || LeapCatalogService.bundleLikelyVision(at: loadURL)
                supportsImageInput = inferredVision
                imageDetectNotes.append("slm.heuristic=\(inferredVision)")
                if inferredVision {
                    modelManager?.setCapabilities(
                        modelID: loadedModel.modelID,
                        quant: loadedModel.quant,
                        isMultimodal: true,
                        isToolCapable: true
                    )
                }
            } else {
                supportsImageInput = false
            }
        } else {
            if loadedFormat == .et {
                let slug = loadURL.deletingPathExtension().lastPathComponent
                supportsImageInput = LeapCatalogService.isVisionQuantizationSlug(slug) || LeapCatalogService.bundleLikelyVision(at: loadURL)
                imageDetectNotes.append("store.missing+slm.heuristic=\(supportsImageInput)")
            } else {
                supportsImageInput = false
                imageDetectNotes.append("store.missing")
            }
        }
        // Apple Foundation Model gained on-device multimodal prompting on iOS 27.
        if loadedFormat == .afm {
            #if NOEMA_ENABLE_XCODE27_APIS
            if #available(iOS 27.0, macOS 27.0, visionOS 27.0, *) {
                supportsImageInput = true
                imageDetectNotes.append("afm.vision=ios27")
            } else {
                supportsImageInput = false
                imageDetectNotes.append("afm.vision=unavailable")
            }
            #else
            supportsImageInput = false
            imageDetectNotes.append("afm.vision=sdk<27")
            #endif
        }
        Task { await logger.log("[Images][Capability] format=\(String(describing: loadedFormat)) supports=\(supportsImageInput) notes=\(imageDetectNotes.joined(separator: ","))") }

        // Persist current model format and function-calling capability for tool gating (e.g., web search)
        do {
            let d = UserDefaults.standard
            if let fmt = loadedFormat { d.set(fmt.rawValue, forKey: "currentModelFormat") }
            d.set(false, forKey: "currentModelIsRemote")
            var supportsToolCalls = false
            if let manager = modelManager, let u = loadedURL, let m = manager.downloadedModels.first(where: { $0.url == u }) {
                supportsToolCalls = m.isToolCapable
                if supportsToolCalls == false {
                    let heuristic = await ToolCapabilityDetector.isToolCapableCachedOrHeuristic(repoId: m.modelID)
                    supportsToolCalls = heuristic
                }
            }
            if loadedFormat == .et || loadedFormat == .afm { supportsToolCalls = true }
            d.set(supportsToolCalls, forKey: "currentModelSupportsFunctionCalling")
        }

        if verboseLogging { print("MODEL_LOAD_READY \(Date().timeIntervalSince1970)") }
        if verboseLogging { print("[ChatVM] client ready ✅") }
        if loadedFormat == .mlx { print("[ChatVM] MLX client ready ✅") }

        // Explicit Save/Load actions own durable settings changes; failed startup
        // handling must not rewrite the user's saved model settings.
    }

    func applyEnvironmentVariables(from s: ModelSettings) {
        setenv("LLAMA_CONTEXT_SIZE", String(Int(s.contextLength)), 1)
        // Mid-generation overflow behavior (read at server start): trimming
        // strategies let the server shift the KV cache and keep generating;
        // Stop at Limit disables shifting so generation halts at n_ctx.
        setenv("LLAMA_CONTEXT_SHIFT", contextOverflowStrategy == .stopAtLimit ? "0" : "1", 1)
        let supportsOffload = DeviceGPUInfo.supportsGPUOffload
        // If sentinel (-1): request all available GPU layers by using a large value (clamped by backend)
        let resolvedGpuLayers: Int = {
            guard supportsOffload else { return 0 }
            if s.gpuLayers < 0 { return 1_000_000 }
            return max(0, s.gpuLayers)
        }()
        setenv("LLAMA_N_GPU_LAYERS", String(resolvedGpuLayers), 1)
        let threadCount = s.cpuThreads > 0 ? s.cpuThreads : ModelSettings.recommendedInferenceThreadCount
        // Hard-clamp so inference always leaves a core free for the UI.
        let clampedThreads = min(max(1, threadCount), ModelSettings.maxInferenceThreadCount)
        setenv("LLAMA_THREADS", String(clampedThreads), 1)
        setenv("LLAMA_THREADS_BATCH", String(clampedThreads), 1)
        // Some llama/ggml builds still honor GGML_* env names – set both for safety
        setenv("GGML_NUM_THREADS", String(clampedThreads), 1)
        setenv("GGML_NUM_THREADS_BATCH", String(clampedThreads), 1)
        let kvOffloadEnabled = supportsOffload && resolvedGpuLayers > 0 && s.kvCacheOffload
        setenv("LLAMA_KV_OFFLOAD", kvOffloadEnabled ? "1" : "0", 1)
        setenv("LLAMA_MMAP", s.useMmap ? "1" : "0", 1)
        setenv("LLAMA_KEEP", s.keepInMemory ? "1" : "0", 1)
        if s.disableWarmup {
            setenv("LLAMA_WARMUP", "0", 1)
        } else {
            unsetenv("LLAMA_WARMUP")
        }
        if let seed = s.seed {
            setenv("LLAMA_SEED", String(seed), 1)
        } else {
            // Do not set a persistent seed here; session start will set a random seed per session
            unsetenv("LLAMA_SEED")
        }
        if s.flashAttention {
            setenv("LLAMA_FLASH_ATTENTION", "1", 1)
            setenv("LLAMA_V_QUANT", s.vCacheQuant.rawValue, 1)
        } else {
            setenv("LLAMA_FLASH_ATTENTION", "0", 1)
            unsetenv("LLAMA_V_QUANT")
        }
        setenv("LLAMA_K_QUANT", s.kCacheQuant.rawValue, 1)
        if let tok = s.tokenizerPath { setenv("LLAMA_TOKENIZER_PATH", tok, 1) }
        if let experts = s.moeActiveExperts, experts > 0 {
            setenv("LLAMA_MOE_EXPERTS", String(experts), 1)
        } else {
            unsetenv("LLAMA_MOE_EXPERTS")
        }
        setenv("NOEMA_TEMPERATURE", String(format: "%.3f", s.temperature), 1)
        setenv("NOEMA_TOP_K", String(max(1, s.topK)), 1)
        setenv("NOEMA_TOP_P", String(format: "%.3f", s.topP), 1)
        setenv("NOEMA_MIN_P", String(format: "%.3f", s.minP), 1)
        setenv("NOEMA_REPEAT_PENALTY", String(format: "%.3f", s.repetitionPenalty), 1)
        setenv("NOEMA_REPEAT_LAST_N", String(max(0, s.repeatLastN)), 1)
        setenv("NOEMA_PRESENCE_PENALTY", String(format: "%.3f", s.presencePenalty), 1)
        setenv("NOEMA_FREQUENCY_PENALTY", String(format: "%.3f", s.frequencyPenalty), 1)
        if let rope = s.ropeScaling {
            setenv("NOEMA_ROPE_SCALING", "yarn", 1)
            setenv("NOEMA_ROPE_FACTOR", String(format: "%.3f", rope.factor), 1)
            setenv("NOEMA_ROPE_BASE", String(rope.originalContext), 1)
            setenv("NOEMA_ROPE_LOW_FREQ", String(format: "%.3f", rope.lowFrequency), 1)
            setenv("NOEMA_ROPE_HIGH_FREQ", String(format: "%.3f", rope.highFrequency), 1)
        } else {
            unsetenv("NOEMA_ROPE_SCALING")
            unsetenv("NOEMA_ROPE_FACTOR")
            unsetenv("NOEMA_ROPE_BASE")
            unsetenv("NOEMA_ROPE_LOW_FREQ")
            unsetenv("NOEMA_ROPE_HIGH_FREQ")
        }
        if !s.logitBias.isEmpty,
           let data = try? JSONEncoder().encode(s.logitBias),
           let json = String(data: data, encoding: .utf8) {
            setenv("NOEMA_LOGIT_BIAS", json, 1)
        } else {
            unsetenv("NOEMA_LOGIT_BIAS")
        }
        if s.promptCacheEnabled {
            setenv("NOEMA_PROMPT_CACHE", s.promptCachePath, 1)
            setenv("NOEMA_PROMPT_CACHE_ALL", s.promptCacheAll ? "1" : "0", 1)
        } else {
            unsetenv("NOEMA_PROMPT_CACHE")
            unsetenv("NOEMA_PROMPT_CACHE_ALL")
        }
        if let overrideValue = s.tensorOverride.overrideValue {
            setenv("NOEMA_OVERRIDE_TENSOR", overrideValue, 1)
        } else {
            unsetenv("NOEMA_OVERRIDE_TENSOR")
        }
        if s.speculativeDecoding.mtpEnabled {
            setenv("NOEMA_MTP_ENABLED", "1", 1)
            setenv("NOEMA_MTP_DRAFT_N_MAX", String(s.speculativeDecoding.resolvedMTPDraftNMax), 1)
            setenv("NOEMA_MTP_DRAFT_N_MIN", String(s.speculativeDecoding.resolvedMTPDraftNMin), 1)
            setenv("NOEMA_MTP_DRAFT_P_MIN", String(s.speculativeDecoding.resolvedMTPDraftPMin), 1)
        } else {
            unsetenv("NOEMA_MTP_ENABLED")
            unsetenv("NOEMA_MTP_DRAFT_N_MAX")
            unsetenv("NOEMA_MTP_DRAFT_N_MIN")
            unsetenv("NOEMA_MTP_DRAFT_P_MIN")
        }
        // Speculative decoding environment variables are not applied on macOS.
        #if !os(macOS)
        if s.speculativeDecoding.selection == .helperDraftModel,
           let helper = s.speculativeDecoding.helperModelID,
           !helper.isEmpty {
            setenv("NOEMA_DRAFT_MODEL", helper, 1)
            let mode = s.speculativeDecoding.mode == .tokens ? "tokens" : "max"
            setenv("NOEMA_DRAFT_MODE", mode, 1)
            setenv("NOEMA_DRAFT_VALUE", String(max(1, s.speculativeDecoding.value)), 1)
            if let manager = modelManager,
               let candidate = manager.downloadedModels.first(where: { $0.modelID == helper }) {
                setenv("NOEMA_DRAFT_PATH", candidate.url.path, 1)
            } else {
                unsetenv("NOEMA_DRAFT_PATH")
            }
        } else {
            unsetenv("NOEMA_DRAFT_MODEL")
            unsetenv("NOEMA_DRAFT_MODE")
            unsetenv("NOEMA_DRAFT_VALUE")
            unsetenv("NOEMA_DRAFT_PATH")
        }
        #else
        unsetenv("NOEMA_DRAFT_MODEL")
        unsetenv("NOEMA_DRAFT_MODE")
        unsetenv("NOEMA_DRAFT_VALUE")
        unsetenv("NOEMA_DRAFT_PATH")
        #endif
    }

    func load(
        url: URL,
        settings: ModelSettings? = nil,
        format: ModelFormat? = nil,
        forceReload: Bool = false
    ) async -> Bool {
#if os(macOS)
        if RelayManagementViewModel.shared.relayHasLocalOwnership {
            loadError = String(
                localized: "Relay currently owns local model runtime. Unload Relay's local model before loading one in chat.",
                locale: LocalizationManager.preferredLocale()
            )
            return false
        }
#endif
        var fmt = format
        if fmt == nil {
            fmt = ModelFormat.detect(from: url)
        }
        // Enforce repository policy: GGUF files must always run through our
        // compiled llama.cpp loopback backend, never Leap SDK.
        if url.pathExtension.lowercased() == "gguf" {
            fmt = .gguf
        }
        if fmt == .et, ETModelResolver.pteURL(for: url) == nil, url.pathExtension.lowercased() == "gguf" {
            fmt = .gguf
        }

        // Noema Teams policy: block disallowed formats and disallowed specific models
        // here, at the single local-model load choke point.
        if EnterprisePolicyGate.isActive {
            let policyMessage = String(
                localized: "Blocked by your organization's policy.",
                locale: LocalizationManager.preferredLocale()
            )
            if let fmt, !EnterprisePolicyGate.allowsModelFormat(fmt) {
                loadError = policyMessage
                Task { await logger.log("[ChatVM][Load] blocked_by_policy format=\(fmt.rawValue)") }
                return false
            }
            let resolvedModelID = modelManager?.downloadedModels.first(where: {
                $0.url == url || url.path.hasPrefix($0.url.path)
            })?.modelID
            if !EnterprisePolicyGate.allowsModel(modelID: resolvedModelID) {
                loadError = policyMessage
                Task { await logger.log("[ChatVM][Load] blocked_by_policy modelID=\(resolvedModelID ?? "<unknown>")") }
                return false
            }
        }

        // Set the loading model name for the notification
        let modelName = displayLoadName(for: url, format: fmt)
        await MainActor.run {
            modelManager?.loadingModelName = modelName
            lastUnloadVerification = nil
            lastGenerationPowerPolicy = nil
        }
        Task {
            await logger.log("[ChatVM][Load] begin model=\(modelName) format=\(fmt?.displayName ?? "<auto>") forceReload=\(forceReload)")
        }

        do {
            try await ensureClient(url: url, settings: settings, format: fmt, forceReload: forceReload)
            let readinessTimeout: TimeInterval = (fmt == .gguf) ? 5.0 : 2.0
            guard await waitForChatInputReadiness(timeout: readinessTimeout) else {
                let message = "Model finished loading backend resources but never reached chat-ready state."
                loadError = message
                Task {
                    await logger.log("[ChatVM][Load] failed_ready model=\(modelName) timeout_s=\(String(format: "%.1f", readinessTimeout))")
                }
                await MainActor.run {
                    modelManager?.loadingModelName = nil
                }
                return false
            }
            self.promptTemplate = self.loadedSettings?.promptTemplate
            Haptics.success()
            AppSoundPlayer.play(.loadSuccess)
            Task {
                await logger.log("[ChatVM][Load] success model=\(modelName)")
            }

            // Clear the loading model name on success
            await MainActor.run {
                modelManager?.loadingModelName = nil
            }

            return true
        } catch {
            // Surface the error to the UI so the user knows what failed.
            if let diagnostic = error as? ETModelResolver.ArtifactDiagnostic {
                pendingETRepairCandidate = etRepairCandidate(for: url, diagnostic: diagnostic)
                loadError = diagnostic.userFacingMessage
            } else {
                pendingETRepairCandidate = nil
                loadError = error.localizedDescription
            }
            if verboseLogging { print("[ChatVM] ❌ \(error.localizedDescription)") }
            Task {
                await logger.log("[ChatVM][Load] failed model=\(modelName) error=\(error.localizedDescription)")
            }

            // Clear the loading model name on failure
            await MainActor.run {
                modelManager?.loadingModelName = nil
            }

            return false
        }
    }

    private func waitForChatInputReadiness(timeout: TimeInterval) async -> Bool {
        if canAcceptChatInput {
            return true
        }
        let started = Date()
        let deadline = started.addingTimeInterval(max(0.5, timeout))
        while Date() < deadline {
            if canAcceptChatInput {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return canAcceptChatInput
    }

    func activeClientForBenchmark() throws -> AnyLLMClient {
        guard let client else {
            throw NSError(domain: "Noema", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model client is not ready"])
        }
        return client
    }

    func makeBenchmarkInput(from rawPrompt: String) -> LLMInput {
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if loadedFormat == .et {
            let userMessage = ChatMessage(role: "user", content: prompt)
            return LLMInput(.messages([userMessage]))
        }

        let history: [Msg] = [Msg(role: "🧑‍💻", text: prompt, timestamp: Date())]
        let systemPrompt = systemPromptText
        Task {
            await logger.log(Self.systemPromptMetadataSummary(systemPrompt))
        }
        let rendered = prepareForGeneration(messages: history, system: systemPrompt)
        switch rendered {
        case .messages(let messages):
            let chatMessages = messages.map { ChatMessage(role: $0.role, content: $0.content) }
            return LLMInput(.messages(chatMessages))
        case .plain(let text):
            return LLMInput(.plain(text))
        }
    }

    nonisolated static func guessLlamaVisionModel(from url: URL) -> Bool {
        ModelVisionDetector.guessLlamaVisionModel(from: url)
    }

    @discardableResult
    private func detachClientAndUnloadResources() -> AnyLLMClient? {
        // Ensure any in-flight loading HUD stops immediately when unloading/ejecting
        if loading {
            loading = false
        } else {
            loadingProgressTracker.completeLoading()
        }
        stillLoading = false

        // Ensure all async work stops before releasing the client to avoid leaks.
        currentContextTask?.cancel()
        currentContextTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        titleTask?.cancel()
        titleTask = nil

        // Preserve rolling thought boxes across unloads. Finish any in-flight streams
        // so boxes transition to a completed state, and persist their state.
        for viewModel in rollingThoughtViewModels.values {
            if viewModel.phase != .complete { viewModel.finish() }
        }
        do {
            let keys = Array(rollingThoughtViewModels.keys)
            UserDefaults.standard.set(keys, forKey: "RollingThought.Keys")
            for (key, vm) in rollingThoughtViewModels {
                vm.saveState(forKey: "RollingThought." + key)
            }
        }

        if let service = remoteService {
            Task {
                await service.setTransportObserver(nil)
#if os(iOS) || os(visionOS)
                await service.setLANRefreshHandler(nil)
#endif
                await service.cancelActiveStream()
            }
        }
        remoteService = nil
        systemPromptToolAvailabilityOverride = nil
        if activeRemoteBackendID != nil {
            modelManager?.activeRemoteSession = nil
        }
        activeRemoteBackendID = nil
        activeRemoteModelID = nil
        remoteLoadingPending = false
        UserDefaults.standard.set(false, forKey: "currentModelIsRemote")

        let detachedClient = client
        client = nil
        modelLoaded = false
        loadedURL = nil
        loadedSettings = nil
        loadedFormat = nil
        promptTemplateSourceLabel = PromptTemplateSource.defaultTemplate.rawValue
        inferenceBackendSummary = nil
        return detachedClient
    }

    private static func unloadDetachedClient(_ client: AnyLLMClient?) async {
        guard let client else { return }
        await client.unloadAndWait()
    }

    private static func beginDetachedClientUnload(_ client: AnyLLMClient?) {
        guard let client else { return }
        Task {
            await client.unloadAndWait()
        }
    }

    private func fetchToolSpecs() async -> [ToolSpec] {
        if !toolSpecsCache.isEmpty { return toolSpecsCache }
        await ToolRegistrar.shared.initializeTools()
        let specs = await MainActor.run { () -> [ToolSpec] in
            (try? ToolRegistry.shared.generateToolSpecs()) ?? []
        }
        toolSpecsCache = specs
        return specs
    }

    private func fetchEnabledToolSpecs() async -> [ToolSpec] {
        let specs = await fetchToolSpecs()
        let availableNames = Set(await ToolManager.shared.availableTools)
        let permissions = activeToolPermissions
        return specs.filter {
            availableNames.contains($0.function.name)
                && permissions.allows(toolName: $0.function.name)
        }
    }

    private func toolAvailability(from specs: [ToolSpec]) -> ToolAvailability {
        let names = Set(specs.map(\.function.name))
        return ToolAvailability(
            webSearch: names.contains("noema.web.retrieve"),
            python: names.contains("noema.python.execute"),
            memory: names.contains("noema.memory"),
            calculator: names.contains("noema.math.calculate"),
            unitConverter: names.contains("noema.units.convert")
        )
    }

    nonisolated func unload() async {
        let before = LiveMemoryPressureSnapshot.current()
        // Capture the current client so we can await a full teardown off the main actor.
        let clientToUnload: AnyLLMClient? = await MainActor.run { () -> AnyLLMClient? in
            self.detachClientAndUnloadResources()
        }
        await Self.unloadDetachedClient(clientToUnload)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = LiveMemoryPressureSnapshot.current()
        let result = ModelUnloadVerifier.evaluate(before: before, after: after)
        await MainActor.run {
            self.lastUnloadVerification = result
        }
        Task {
            await logger.log("[ModelUnloadVerification] \(result.logSummary)")
        }
    }

    #if canImport(LeapSDK)
    @preconcurrency
    func activate(runner: any ModelRunner, url: URL, settings: ModelSettings? = nil) {
#if os(macOS)
        if RelayManagementViewModel.shared.relayHasLocalOwnership {
            loadError = String(
                localized: "Relay currently owns local model runtime. Unload Relay's local model before loading one in chat.",
                locale: LocalizationManager.preferredLocale()
            )
            return
        }
#endif
        let modelName = url.deletingPathExtension().lastPathComponent
        Task { await logger.log("[ChatVM][Load] begin model=\(modelName) format=ET forceReload=true") }
        Self.beginDetachedClientUnload(detachClientAndUnloadResources())
        do {
            let ident = url.deletingPathExtension().lastPathComponent
            client = try AnyLLMClient(
                LeapLLMClient.make(
                    runner: runner,
                    systemPrompt: systemPromptText,
                    modelIdentifier: ident
                )
            )
            loadedFormat = .et
            let resolvedSettings: ModelSettings = {
                if let settings { return settings }
                if let manager = modelManager,
                   let model = manager.downloadedModels.first(where: { $0.url == url }) {
                    return manager.settings(for: model)
                }
                return ModelSettings.default(for: .et)
            }()
            loadedSettings = resolvedSettings
            loadedURL = url
            if let model = modelManager?.downloadedModels.first(where: { $0.url == url }) {
                let inferredVision = model.isMultimodal
                    || LeapCatalogService.isVisionQuantizationSlug(model.modelID)
                    || LeapCatalogService.bundleLikelyVision(at: url)
                supportsImageInput = inferredVision
                if inferredVision && !model.isMultimodal {
                    modelManager?.setCapabilities(
                        modelID: model.modelID,
                        quant: model.quant,
                        isMultimodal: true,
                        isToolCapable: true
                    )
                }
            } else {
                supportsImageInput = LeapCatalogService.isVisionQuantizationSlug(ident) || LeapCatalogService.bundleLikelyVision(at: url)
            }
            let defaults = UserDefaults.standard
            defaults.set(ModelFormat.et.rawValue, forKey: "currentModelFormat")
            defaults.set(false, forKey: "currentModelIsRemote")
            defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
            modelLoaded = true
            Haptics.success()
            AppSoundPlayer.play(.loadSuccess)
            AccessibilityAnnouncer.announceLocalized("Model loaded.")
            Task { await logger.log("[ChatVM][Load] success model=\(modelName)") }
        } catch {
            client = nil
            supportsImageInput = false
            modelLoaded = false
            loadError = error.localizedDescription
            Task { await logger.log("[ChatVM][Load] failed model=\(modelName) error=\(error.localizedDescription)") }
        }
    }
#endif

    func activateRemoteSession(backend: RemoteBackend, model: RemoteModel, settings: ModelSettings? = nil) async throws {
        // Noema Teams policy: every remote chat session is created here, so this is the
        // single choke point for remote-inference and backend allowlists.
        guard EnterprisePolicyGate.remoteInferenceAllowed else {
            throw RemoteBackendError.validationFailed(String(
                localized: "Remote inference is disabled by your organization's policy.",
                locale: LocalizationManager.preferredLocale()
            ))
        }
        guard EnterprisePolicyGate.allowsRemoteBackend(id: backend.id, endpointType: backend.endpointType) else {
            throw RemoteBackendError.validationFailed(String(
                localized: "This remote backend is not allowed by your organization's policy.",
                locale: LocalizationManager.preferredLocale()
            ))
        }
        if !backend.isCloudRelay {
            guard backend.chatEndpointURL != nil else {
                throw RemoteBackendError.invalidEndpoint
            }
        }
        let modelIdentifier = model.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelIdentifier.isEmpty else {
            throw RemoteBackendError.validationFailed("Model identifier missing.")
        }

        let resolvedSettings: ModelSettings = {
            if let settings {
                if let manager = modelManager {
                    return manager.clampedRemoteSettings(settings, maxContextLength: model.maxContextLength)
                }
                return settings
            }
            if let manager = modelManager {
                return manager.remoteSettings(for: backend.id, model: model)
            }
            return ModelSettings.default(for: model.compatibilityFormat ?? .gguf)
        }()

        systemPromptToolAvailabilityOverride = nil
        lastGenerationPowerPolicy = nil

        await Self.unloadDetachedClient(detachClientAndUnloadResources())

        // Do NOT clear active dataset when switching to a remote session.
        // RAG injection works with remote backends; keep the user's selection.

        // Preload LM Studio models on "Use" so first chat token doesn't wait on model load.
        // Skip if the selected model is already reported as loaded by the server.
        if backend.endpointType == .lmStudio && !model.isLoadedOnBackend {
            try await RemoteBackendAPI.requestLoad(for: backend, modelID: modelIdentifier, settings: resolvedSettings)
        }

        let defaults = UserDefaults.standard
        let pendingRemoteFormat = model.compatibilityFormat ?? .gguf
        defaults.set(pendingRemoteFormat.rawValue, forKey: "currentModelFormat")
        defaults.set(true, forKey: "currentModelIsRemote")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")

        let specs = await fetchEnabledToolSpecs()

        let service = RemoteChatService(backend: backend, modelID: modelIdentifier, toolSpecs: specs)
        remoteService = service
        let backendID = backend.id
        await service.setTransportObserver { [weak self] transport, streaming in
            await MainActor.run {
                guard let self else { return }
                self.updateActiveRemoteTransport(for: backendID, transport: transport, streaming: streaming)
            }
        }
#if os(iOS) || os(visionOS)
        await service.setLANRefreshHandler { [weak self] in
            guard let self else { return nil }
            return await self.refreshRelayBackend(backendID: backendID)
        }
#endif
        // Preflight LAN adoption (iOS/visionOS) before establishing UI session state
        var initialLANSSID: String? = nil
#if os(iOS) || os(visionOS)
        initialLANSSID = await service.preflightLANAdoption()
#endif

        activeRemoteBackendID = backend.id
        activeRemoteModelID = modelIdentifier

        do {
        if backend.endpointType == .noemaRelay {
            let containerID = backend.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !containerID.isEmpty else {
                throw RemoteBackendError.validationFailed("Missing CloudKit container identifier for relay.")
            }
            guard let hostDeviceID = backend.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines), !hostDeviceID.isEmpty else {
                throw RemoteBackendError.validationFailed("Missing host device ID for relay.")
            }
            let recordName: String
            if let relayRecord = model.relayRecordName, !relayRecord.isEmpty {
                recordName = relayRecord
            } else if modelIdentifier.hasPrefix("model-") {
                recordName = modelIdentifier
            } else {
                recordName = "model-\(modelIdentifier)"
            }
            let payload: [String: Any] = [
                "modelRef": recordName,
                "ensure": "loaded"
            ]
            let body = try JSONSerialization.data(withJSONObject: payload, options: [])
            let command = try await RelayCatalogClient.shared.createCommand(
                containerIdentifier: containerID,
                hostDeviceID: hostDeviceID,
                verb: "POST",
                path: "/models/activate",
                body: body
            )
            let result = try await RelayCatalogClient.shared.waitForCommand(
                containerIdentifier: containerID,
                commandID: command.recordID,
                // Don't block the UI for minutes. Wait briefly and then
                // allow streaming to proceed; the Mac can finish activation
                // in the background.
                timeout: 25
            )
            if result.state != .succeeded {
                if let data = result.result,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let message = json["error"] as? String {
                    throw RemoteBackendError.validationFailed(message)
                }
                throw RemoteBackendError.validationFailed("Relay activation failed.")
            }
        } } catch let relayError as RelayError {
            if case .timeout = relayError {
                // Continue without failing; first message will proceed once the
                // Mac finishes activation. This avoids indefinite spinners.
                await logger.log("[RemoteBackendAPI] ⚠️ Relay activation timed out; continuing without blocking UI.")
            } else {
                throw relayError
            }
        }

        await service.updateConversationID(activeSessionID)
        if backend.endpointType == .noemaRelay {
            await service.updateRelayContainerID(backend.baseURLString)
        } else if backend.endpointType == .cloudRelay {
            let containerID = RelayConfiguration.containerIdentifier
            await service.updateRelayContainerID(containerID)
        } else {
            await service.updateRelayContainerID(nil)
        }

        let textStream: @Sendable (LLMInput) async throws -> AsyncThrowingStream<String, Error> = { [weak self] input in
            guard let self else { return AsyncThrowingStream { continuation in continuation.finish() } }
            guard let remote = await self.remoteService else {
                return AsyncThrowingStream { continuation in continuation.finish() }
            }
            return await remote.stream(for: input)
        }

        client = AnyLLMClient(
            textStream: textStream,
            cancel: { [weak self] in
                Task { await self?.remoteService?.cancelActiveStream() }
            }
        )

        await service.updateToolSpecs(specs)

        loadedFormat = model.compatibilityFormat ?? .gguf
        supportsImageInput = false
        promptTemplate = nil
        promptTemplateSourceLabel = PromptTemplateSource.defaultTemplate.rawValue
        inferenceBackendSummary = nil
        loadError = nil
        loadedURL = nil
        loadedSettings = resolvedSettings
        modelLoaded = true
        AccessibilityAnnouncer.announceLocalized("Model loaded.")
        currentKind = ModelKind.detect(id: modelIdentifier)
        modelManager?.loadedModel = nil
        let defaultTransport: RemoteSessionTransport
        let defaultStreaming: Bool
        switch backend.endpointType {
        case .noemaRelay:
            #if os(iOS) || os(visionOS)
            if let _ = initialLANSSID {
                defaultTransport = .lan(ssid: initialLANSSID ?? "")
            } else {
                defaultTransport = .cloudRelay
            }
            #else
            defaultTransport = .cloudRelay
            #endif
            defaultStreaming = false
        case .cloudRelay:
            defaultTransport = .cloudRelay
            defaultStreaming = false
        default:
            defaultTransport = .direct
            defaultStreaming = true
        }
        modelManager?.activeRemoteSession = ActiveRemoteSession(
            backendID: backend.id,
            backendName: backend.name,
            modelID: modelIdentifier,
            modelName: model.name,
            endpointType: backend.endpointType,
            transport: defaultTransport,
            streamingEnabled: defaultStreaming
        )

        if let fmt = loadedFormat { defaults.set(fmt.rawValue, forKey: "currentModelFormat") }
        defaults.set(true, forKey: "currentModelIsRemote")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")

        systemPromptToolAvailabilityOverride = toolAvailability(from: specs)

        // Record remote usage for review milestone tracking (prompting happens after a success moment).
        ReviewPrompter.shared.noteRemoteUsed()
    }

    func refreshActiveRemoteBackendIfNeeded(updatedBackendID: RemoteBackend.ID, activeModelID: String) async throws {
        guard let service = remoteService,
              let currentBackendID = activeRemoteBackendID,
              currentBackendID == updatedBackendID,
              let backend = modelManager?.remoteBackend(withID: updatedBackendID) else {
            return
        }
        await service.updateBackend(backend)
        await service.updateModelID(activeModelID)
        activeRemoteModelID = activeModelID
        let specs = await fetchEnabledToolSpecs()
        await service.updateToolSpecs(specs)
        systemPromptToolAvailabilityOverride = toolAvailability(from: specs)
#if os(iOS) || os(visionOS)
        requestImmediateLANCheck(reason: "active-backend-refresh")
#endif
    }

#if os(iOS) || os(visionOS)
    func requestImmediateLANCheck(reason: String) {
        Task {
            guard let service = await self.remoteService else { return }
            await service.forceLANRefresh(reason: reason)
        }
    }

    func forceLANOverride(reason: String) {
        Task {
            guard let service = await self.remoteService else { return }
            await service.setLANManualOverride(true, reason: reason)
        }
    }

    private func refreshRelayBackend(backendID: RemoteBackend.ID) async -> RemoteBackend? {
        guard let manager = modelManager else { return nil }
        await manager.fetchRemoteModels(for: backendID)
        return manager.remoteBackend(withID: backendID)
    }
#endif

    private func updateActiveRemoteTransport(for backendID: RemoteBackend.ID,
                                             transport: RemoteSessionTransport,
                                             streaming: Bool) {
        guard let session = modelManager?.activeRemoteSession,
              session.backendID == backendID else {
            return
        }
        modelManager?.activeRemoteSession = ActiveRemoteSession(
            backendID: session.backendID,
            backendName: session.backendName,
            modelID: session.modelID,
            modelName: session.modelName,
            endpointType: session.endpointType,
            transport: transport,
            streamingEnabled: streaming
        )
    }

    func deactivateRemoteSession() {
        let backendID = activeRemoteBackendID
        let modelID = activeRemoteModelID
        var relayContext: (containerID: String, hostDeviceID: String, recordName: String)? = nil
        if let backendID, let modelID,
           let backend = modelManager?.remoteBackend(withID: backendID),
           backend.endpointType == .noemaRelay,
           backend.relayEjectsOnDisconnect {
            let containerID = backend.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
            let hostID = backend.relayHostDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !containerID.isEmpty, !hostID.isEmpty {
                let recordName = modelID.hasPrefix("model-") ? modelID : "model-\(modelID)"
                relayContext = (containerID, hostID, recordName)
            }
        }
        if let context = relayContext {
            Task {
                await sendRelayDeactivateCommand(containerID: context.containerID,
                                                 hostDeviceID: context.hostDeviceID,
                                                 recordName: context.recordName)
            }
        }
        Self.beginDetachedClientUnload(detachClientAndUnloadResources())
    }

    private func sendRelayDeactivateCommand(containerID: String, hostDeviceID: String, recordName: String) async {
        let payload: [String: Any] = [
            "modelRef": recordName,
            "ensure": "unloaded"
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        do {
            let command = try await RelayCatalogClient.shared.createCommand(
                containerIdentifier: containerID,
                hostDeviceID: hostDeviceID,
                verb: "POST",
                path: "/models/deactivate",
                body: body
            )
            let result = try await RelayCatalogClient.shared.waitForCommand(
                containerIdentifier: containerID,
                commandID: command.recordID,
                timeout: 60
            )
            if result.state != .succeeded {
                await logger.log("[RemoteBackendAPI] ⚠️ Relay eject returned state=\(result.state.rawValue)")
            }
        } catch {
            await logger.log("[RemoteBackendAPI] ❌ Failed to request relay eject: \(error.localizedDescription)")
        }
    }


    func stop() {
        // Proactively cancel backend generation (llama.cpp) and any in-flight tool calls
        stopAfterParagraphRequested = false
        stopAfterParagraphBaselineCharacterCount = nil
        client?.cancelActive()
        currentContextTask?.cancel()
        currentContextTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        currentContinuationTask?.cancel()
        currentContinuationTask = nil
        titleTask?.cancel()
        titleTask = nil
        
        // Do not remove rolling thought boxes when stopping; finalize their state instead
        for viewModel in rollingThoughtViewModels.values {
            if viewModel.isLogicallyComplete {
                viewModel.finish()
            } else {
                viewModel.markInterrupted()
            }
        }
        do {
            let keys = Array(rollingThoughtViewModels.keys)
            UserDefaults.standard.set(keys, forKey: "RollingThought.Keys")
            for (key, vm) in rollingThoughtViewModels {
                vm.saveState(forKey: "RollingThought." + key)
            }
        }
        
        if let activeIdx = activeIndex, sessions.indices.contains(activeIdx) {
            var activeMessages = sessions[activeIdx].messages
            if let idx = activeMessages.indices.last {
                activeMessages[idx].streaming = false
                activeMessages[idx].promptProcessing = nil
            }
            sessions[activeIdx].messages = Self.removingCancelledAssistantPlaceholder(from: activeMessages)
        }
        // Also clear streaming flag in the session that was actually streaming
        // (may differ from the active session if the user switched tabs).
        if let sIdx = streamSessionIndex,
           sessions.indices.contains(sIdx) {
            var streamedMessages = sessions[sIdx].messages
            if let idx = streamedMessages.indices.last {
                streamedMessages[idx].streaming = false
                streamedMessages[idx].promptProcessing = nil
            }
            sessions[sIdx].messages = Self.removingCancelledAssistantPlaceholder(from: streamedMessages)
        }
        injectionStage = .none
        injectionMethod = nil
        streamSessionIndex = nil
    }

    func requestStopAfterParagraph() {
        guard isStreaming else { return }
        stopAfterParagraphRequested = true
        let visibleText = msgs.last?.text ?? ""
        stopAfterParagraphBaselineCharacterCount = visibleText.count
    }

    private func clearStopAfterParagraphRequest() {
        stopAfterParagraphRequested = false
        stopAfterParagraphBaselineCharacterCount = nil
    }

    private func shouldStopAtRequestedParagraphBoundary(in visibleText: String) -> Bool {
        guard stopAfterParagraphRequested else { return false }
        let baseline = min(stopAfterParagraphBaselineCharacterCount ?? 0, visibleText.count)
        let suffix = String(visibleText.dropFirst(baseline))
        guard suffix.trimmingCharacters(in: .whitespacesAndNewlines).count >= 24 else { return false }
        return suffix.range(of: #"\n\s*\n"#, options: .regularExpression) != nil
    }

    private func markRollingThoughtsInterrupted(forMessageAt index: Int) {
        guard streamMsgs.indices.contains(index) else { return }
        let messageID = streamMsgs[index].id.uuidString
        let prefix = "message-\(messageID)-think-"
        for (key, viewModel) in rollingThoughtViewModels where key.hasPrefix(prefix) {
            if !viewModel.isLogicallyComplete && !viewModel.isPendingCompletion {
                viewModel.markInterrupted()
            }
        }
    }

    private func resetSession() async {
        currentContextTask?.cancel()
        currentContextTask = nil
        currentStreamTask?.cancel()
        currentStreamTask = nil
        titleTask?.cancel()
        titleTask = nil
        client = nil
        modelLoaded = false
        guard let url = loadedURL else { return }
        try? await ensureClient(url: url, settings: loadedSettings, format: loadedFormat, forceReload: false)
        streamSessionIndex = nil
    }
    
    private func appendUser(_ text: String, purpose: RunPurpose) {
        precondition(purpose == .chat, "appendUser used for non-chat run")
        var m = msgs
        let datasetSnapshot: (id: String, name: String)? = {
            guard let ds = activeSessionRetrievalDataset else { return nil }
            return (ds.datasetID, ds.name)
        }()
        m.append(.init(role: "🧑‍💻",
                       text: text,
                       timestamp: Date(),
                       datasetID: datasetSnapshot?.id,
                       datasetName: datasetSnapshot?.name))
        msgs = m
    }

    private func appendAssistantPlaceholder(purpose: RunPurpose) -> Int {
        precondition(purpose == .chat, "appendAssistant used for non-chat run")
        var m = msgs
        let remoteSession = modelManager?.activeRemoteSession
        m.append(
            .init(
                role: "🤖",
                text: "",
                timestamp: Date(),
                streaming: true,
                promptProcessing: self.supportsPromptProcessingCard ? .init(progress: 0) : nil,
                usedRemoteBackend: remoteSession != nil,
                remoteBackendName: remoteSession?.backendName,
                remoteModelName: remoteSession?.modelName
            )
        )
        msgs = m
        return msgs.index(before: msgs.endIndex)
    }

    // UI callback (legacy) – forwards to sendMessage with captured prompt
    func send() async {
        await sendMessage(prompt)
    }

    /// New send variant that avoids races with UI clearing the prompt by accepting the text explicitly.
    func sendMessage(_ rawInput: String) async {
        clearStopAfterParagraphRequest()
        let visibleInput = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let completedMediaAttachments = pendingMediaAttachments.filter(\.hasCompletedTranscript)
        guard !visibleInput.isEmpty || !completedMediaAttachments.isEmpty else { return }
        let input = visibleInput.isEmpty ? String(localized: "Transcribed media attached.") : visibleInput
        let modelInput = Self.promptText(
            userText: visibleInput,
            mediaAttachments: completedMediaAttachments
        )

        await logger.log("[ChatVM][SendAttempt] \(modelInput)")

        if isStreamingInAnotherSession {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = input
            }
            crossSessionSendBlocked = true
            await logger.log("[ChatVM] Blocking send: another chat is still generating")
            return
        }

        if loading || stillLoading {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = input
            }
            await logger.log("[ChatVM] Blocking send: model still loading")
            return
        }

        prompt = ""
        activeTurnScratchpadSnapshot = referencedScratchpadSnapshot(for: input)

        let datasetSnapshot: (id: String, name: String)? = {
            guard let ds = activeSessionRetrievalDataset else { return nil }
            return (ds.datasetID, ds.name)
        }()

        if verboseLogging { print("[ChatVM] USER ▶︎ \(input)") }
        await logger.log("[ChatVM] USER ▶︎ \(input)")

        titleTask?.cancel()
        titleTask = nil

        currentStreamTask?.cancel()
        runCounter += 1
        let myID = runCounter
        activeRunID = myID

        guard let sIdx = self.activeIndex else { return }
        streamSessionIndex = sIdx
#if os(iOS)
        Haptics.impact(.light)
#endif
        AccessibilityAnnouncer.announceLocalized("Prompt submitted.")
        var didLaunchStreamTask = false
        defer {
            if !didLaunchStreamTask { streamSessionIndex = nil }
        }
        var m = self.streamMsgs
        m.append(.init(role: "🧑‍💻",
                       text: input,
                       timestamp: Date(),
                       datasetID: datasetSnapshot?.id,
                       datasetName: datasetSnapshot?.name))
        self.streamMsgs = m
        // Snapshot attachments at send time so UI can clear the input tray immediately
        // Track which image file paths this specific run uses, so prior/next runs
        // cannot accidentally clear attachments they don't own.
        var usedImagePathsForThisRun: [String] = []
        let attachments = pendingImageURLs.map { $0.path }
        if !attachments.isEmpty {
            m = self.streamMsgs
            let idx = m.index(before: m.endIndex)
            m[idx].imagePaths = attachments
            self.streamMsgs = m
            // Mark these specific paths as the attachments for this run
            usedImagePathsForThisRun = attachments
            // Immediately remove used attachments from the input tray to avoid
            // showing them while generation is in progress. The sent images remain
            // visible on the user message via msg.imagePaths.
            for path in attachments {
                let url = URL(fileURLWithPath: path)
                if let i = pendingImageURLs.firstIndex(of: url) { pendingImageURLs.remove(at: i) }
                pendingThumbnails.removeValue(forKey: url)
            }
        }
        if !completedMediaAttachments.isEmpty {
            m = self.streamMsgs
            let idx = m.index(before: m.endIndex)
            m[idx].mediaAttachments = completedMediaAttachments
            self.streamMsgs = m
            let sentIDs = Set(completedMediaAttachments.map(\.id))
            pendingMediaAttachments.removeAll { sentIDs.contains($0.id) }
        }
        m = self.streamMsgs
        let remoteSession = modelManager?.activeRemoteSession
        m.append(
            .init(
                role: "🤖",
                text: "",
                timestamp: Date(),
                streaming: true,
                promptProcessing: self.supportsPromptProcessingCard ? .init(progress: 0) : nil,
                usedRemoteBackend: remoteSession != nil,
                remoteBackendName: remoteSession?.backendName,
                remoteModelName: remoteSession?.modelName
            )
        )
        self.streamMsgs = m
        let outIdx = self.streamMsgs.index(before: self.streamMsgs.endIndex)
        self.pendingAFMToolSummary = nil
        self.pendingAFMRouteInfo = nil
        let fullHistory = self.streamMsgs
        let modelHistory = Self.modelFacingHistory(visibleHistory: fullHistory, modelInput: modelInput)
        let messageID = self.streamMsgs[outIdx].id
        // Begin streaming into the narrow store; the live bubble renders from it so token
        // updates don't republish ChatVM (and thus every tab) on every token.
        self.streamingStore.begin(id: messageID)
        var history = modelHistory
        refreshSystemPromptForActiveSession(historyOverride: fullHistory)
        if loadedFormat == .afm {
            let afmPreflight = Self.afmPreflight(
                history: modelHistory,
                estimateTokens: { [weak self] history in
                    self?.estimatedPromptTokens(for: history) ?? 0
                },
                contextLimit: activeAFMClient?.effectiveContextLimit() ?? 4096
            )
            if let stopMessage = afmPreflight.stopMessage {
                await MainActor.run {
                    guard self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].text = "⚠️ " + stopMessage
                    self.streamMsgs[outIdx].streaming = false
                    self.streamMsgs[outIdx].promptProcessing = nil
                    self.streamingStore.finish()
                    self.injectionStage = .none
                    self.injectionMethod = nil
                }
                return
            }
        } else {
            let contextPlan = planHistoryForContextOverflow(history: modelHistory)
            history = contextPlan.history
            // Context overflow handling:
            // - stopAtLimit: show error and return (intentional user choice)
            // - truncateMiddle / rollingWindow: register the informational banner
            //   (liquid glass popup) but keep going — the server-verified trim loop
            //   will do precise fitting with /tokenize before streaming.
            if contextPlan.requiresStop && contextOverflowStrategy == .stopAtLimit {
                let details = ContextOverflowDetails(
                    promptTokens: contextPlan.initialEstimate,
                    contextTokens: currentPromptBudget().usablePromptTokens,
                    rawMessage: "preflight-stop"
                )
                registerContextOverflow(strategy: contextOverflowStrategy, details: details)
                let message = contextStopMessage(details: details)
                await MainActor.run {
                    guard self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].text = "⚠️ " + message
                    self.streamMsgs[outIdx].streaming = false
                    self.streamMsgs[outIdx].promptProcessing = nil
                    self.streamingStore.finish()
                    self.injectionStage = .none
                    self.injectionMethod = nil
                }
                return
            }
            if contextPlan.initialEstimate > contextSoftLimitTokens() {
                let details = ContextOverflowDetails(
                    promptTokens: contextPlan.initialEstimate,
                    contextTokens: currentPromptBudget().usablePromptTokens,
                    rawMessage: contextPlan.requiresStop ? "preflight-overflow" : "preflight-trimmed"
                )
                registerContextOverflow(strategy: contextOverflowStrategy, details: details)
            } else {
                // This turn fits again — retire any stale overflow pill so it
                // always describes the most recent send.
                clearContextOverflowForCurrentStream()
            }
        }

        systemPromptToolAvailabilityOverride = nil
        var remoteToolsAllowedOverride = ToolAvailability.none
        if let remoteService = self.remoteService {
            let specs = await self.fetchEnabledToolSpecs()
            await remoteService.updateToolSpecs(specs)
            remoteToolsAllowedOverride = self.toolAvailability(from: specs)
        }
        systemPromptToolAvailabilityOverride = remoteToolsAllowedOverride.any ? remoteToolsAllowedOverride : nil
        refreshSystemPromptForActiveSession(historyOverride: history)

        // Use local backends only.
        if (loadedFormat == .et || loadedFormat == .ane || loadedFormat == .afm || loadedFormat == .coreai), let client = self.client {
            await client.syncSystemPrompt(systemPromptText)
        }

        var promptStr: String
        var stops: [String]
        var llmInput: LLMInput
        
        if loadedFormat == .et {
            promptStr = modelInput
            stops = loadedSettings?.stopSequences ?? []
            let userMessage = ChatMessage(role: "user", content: modelInput)
            llmInput = LLMInput(.messages([userMessage]))
        } else {
            let (basePrompt, s, _) = self.buildPrompt(kind: currentKind, history: history)
            promptStr = basePrompt
            var mergedStops = s
            if mergedStops.isEmpty {
                if let overrideStops = (loadedSettings?.stopSequences ?? nil), !overrideStops.isEmpty {
                    mergedStops = overrideStops
                }
            }
            stops = mergedStops
            llmInput = LLMInput(.plain("") ) // will assign after final prompt computed
        }
        let isMLXFormat = (self.loadedFormat == .mlx)
        // Log prompt summary to the app log for diagnostics
        do {
            let templateSource = self.promptTemplateSourceLabel
            let promptMetadata = Self.promptMetadataSummary(
                prompt: promptStr,
                stops: stops,
                format: self.loadedFormat,
                kind: self.currentKind,
                hasTemplate: self.promptTemplate != nil
            )
            Task {
                await logger.log("[Prompt][Template] source=\(templateSource)")
                await logger.log("[ChatVM] Prompt built " + promptMetadata)
            }
        }

        // If a dataset is active decide whether to inject the full content or
        // fall back to RAG lookups and prepend the resulting context to the
        // prompt before sending it to the model.
        if let ds = activeSessionRetrievalDataset {
            let requestedMaxChunks = max(1, ragMaxChunks)
            let datasetDisplayName = ds.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ds.datasetID : ds.name
            let promptBudget = Self.promptBudget(for: contextLimit)
            let promptTemplateKind = templateKind()
            let currentKind = self.currentKind
            injectionStage = .deciding
            injectionMethod = nil
            clearRAGInjectionArtifacts(messageIndex: outIdx)
            let decidingInfo = Msg.RAGInjectionInfo(
                datasetName: datasetDisplayName,
                stage: .deciding,
                method: nil,
                requestedMaxChunks: requestedMaxChunks,
                retrievedChunkCount: 0,
                injectedChunkCount: 0,
                trimmedChunkCount: 0,
                partialChunkInjected: false,
                fullContentEstimateTokens: nil,
                configuredContextTokens: promptBudget.configuredContextTokens,
                reservedResponseTokens: promptBudget.reservedResponseTokens,
                contextBudgetTokens: promptBudget.usablePromptTokens,
                injectedContextTokens: 0,
                decisionReason: "Choosing between full document injection and smart retrieval."
            )
            updateRAGInjectionInfo(messageIndex: outIdx, decidingInfo)
            logRAGInjectionInfo(decidingInfo)
            currentContextTask = Task { [weak self, requestedMaxChunks, datasetDisplayName, promptBudget, promptTemplateKind, currentKind, promptStr, verboseLogging = self.verboseLogging, ragMinScore = self.ragMinScore, ragRetrievalModeRaw = self.ragRetrievalModeRaw] in
                guard let self else { return nil }
                let ragRetrievalMode = DatasetRetrievalMode.from(ragRetrievalModeRaw)

                func makeInfo(
                    stage: Msg.RAGInjectionInfo.Stage,
                    method: Msg.RAGInjectionInfo.Method?,
                    retrievedChunkCount: Int,
                    injectedChunkCount: Int,
                    trimmedChunkCount: Int,
                    partialChunkInjected: Bool,
                    fullContentEstimateTokens: Int?,
                    contextBudgetTokens: Int,
                    injectedContextTokens: Int,
                    decisionReason: String
                ) -> Msg.RAGInjectionInfo {
                    Msg.RAGInjectionInfo(
                        datasetName: datasetDisplayName,
                        stage: stage,
                        method: method,
                        requestedMaxChunks: requestedMaxChunks,
                        retrievedChunkCount: retrievedChunkCount,
                        injectedChunkCount: injectedChunkCount,
                        trimmedChunkCount: trimmedChunkCount,
                        partialChunkInjected: partialChunkInjected,
                        fullContentEstimateTokens: fullContentEstimateTokens,
                        configuredContextTokens: promptBudget.configuredContextTokens,
                        reservedResponseTokens: promptBudget.reservedResponseTokens,
                        contextBudgetTokens: contextBudgetTokens,
                        injectedContextTokens: injectedContextTokens,
                        decisionReason: decisionReason
                    )
                }

                func publish(
                    _ info: Msg.RAGInjectionInfo,
                    method: InjectionMethod?,
                    stage: InjectionStage
                ) async {
                    await MainActor.run {
                        self.injectionMethod = method
                        self.injectionStage = stage
                        self.updateRAGInjectionInfo(messageIndex: outIdx, info)
                    }
                    self.logRAGInjectionInfo(info)
                }

                let promptWithInjectedContext: @Sendable (String) -> String = { context in
                    Self.injectContextIntoPrompt(
                        original: promptStr,
                        context: context,
                        kind: currentKind,
                        templateKind: promptTemplateKind
                    )
                }

                func fetchDetailedContext() async -> [(text: String, source: String?, score: Float?)] {
                    await EmbeddingModel.shared.ensureModel()
                    if !(await EmbeddingModel.shared.isReady()) {
                        await EmbeddingModel.shared.warmUp()
                    }
                    if verboseLogging {
                        print("[ChatVM] Embed ready: \(await EmbeddingModel.shared.isReady())")
                    }
                    return await DatasetRetriever.shared.fetchContextDetailed(
                        for: input,
                        dataset: ds,
                        maxChunks: requestedMaxChunks,
                        minScore: Float(ragMinScore),
                        mode: ragRetrievalMode
                    ) { status in
                        Task { @MainActor in
                            self.datasetManager?.processingStatus[ds.datasetID] = status
                            if let dc = self.datasetManager?.downloadController {
                                dc.showOverlay = status.stage != .completed && status.stage != .failed
                            }
                        }
                    }
                }

                func resolvePackedRAGContext(
                    from detailed: [(text: String, source: String?, score: Float?)],
                    fullContentEstimateTokens: Int?,
                    baseReason: String
                ) async -> ResolvedRAGContext {
                    let packed = await Self.packRAGContext(
                        chunks: detailed,
                        requestedMaxChunks: requestedMaxChunks,
                        usablePromptTokens: promptBudget.usablePromptTokens,
                        promptTokenCounter: { text in
                            await self.estimatedPromptTokens(for: text)
                        },
                        promptBuilder: { context in
                            promptWithInjectedContext(context)
                        }
                    )
                    let finalReason: String = {
                        if packed.retrievedChunkCount == 0 {
                            return baseReason + " No chunks were retrieved."
                        }
                        if packed.injectedChunkCount == 0 {
                            return baseReason + " Retrieved passages did not fit in the prompt budget."
                        }
                        if packed.partialChunkInjected {
                            return baseReason + " Only a partial excerpt of the top chunk fit in the prompt budget."
                        }
                        if packed.injectedChunkCount < packed.retrievedChunkCount {
                            return baseReason + " \(packed.injectedChunkCount) of \(packed.retrievedChunkCount) chunks fit in the prompt budget."
                        }
                        return baseReason
                    }()
                    let injectedInfo = makeInfo(
                        stage: .injected,
                        method: .rag,
                        retrievedChunkCount: packed.retrievedChunkCount,
                        injectedChunkCount: packed.injectedChunkCount,
                        trimmedChunkCount: packed.trimmedChunkCount,
                        partialChunkInjected: packed.partialChunkInjected,
                        fullContentEstimateTokens: fullContentEstimateTokens,
                        contextBudgetTokens: packed.contextBudgetTokens,
                        injectedContextTokens: packed.contextTokenCount,
                        decisionReason: finalReason
                    )
                    await publish(injectedInfo, method: .rag, stage: .processing)
                    await MainActor.run {
                        self.currentInjectedTokenOverhead = 0
                    }
                    return ResolvedRAGContext(
                        injectedContext: packed.injectedContext,
                        citations: packed.injectedCitations,
                        info: injectedInfo
                    )
                }

                let fullContext = await self.cachedFullDatasetContent(for: ds)
                let trimmedFullContext = fullContext.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullContextDecision = await Self.evaluateFullContextInjection(
                    fullContext: fullContext,
                    contextLimit: Double(promptBudget.configuredContextTokens),
                    promptBuilder: { context in
                        promptWithInjectedContext(context)
                    },
                    promptTokenCounter: { text in
                        await self.estimatedPromptTokens(for: text)
                    }
                )
                if Task.isCancelled { return nil }

                if !trimmedFullContext.isEmpty, fullContextDecision.fits {
                    let chosenInfo = makeInfo(
                        stage: .chosen,
                        method: .fullContent,
                        retrievedChunkCount: 0,
                        injectedChunkCount: 0,
                        trimmedChunkCount: 0,
                        partialChunkInjected: false,
                        fullContentEstimateTokens: fullContextDecision.fullContextTokens,
                        contextBudgetTokens: promptBudget.usablePromptTokens,
                        injectedContextTokens: 0,
                        decisionReason: "Full document passed the initial budget check."
                    )
                    await publish(chosenInfo, method: .full, stage: .decided)
                    await MainActor.run {
                        self.currentInjectedTokenOverhead = fullContextDecision.fullContextTokens
                    }
                    let injectedInfo = makeInfo(
                        stage: .injected,
                        method: .fullContent,
                        retrievedChunkCount: 0,
                        injectedChunkCount: 0,
                        trimmedChunkCount: 0,
                        partialChunkInjected: false,
                        fullContentEstimateTokens: fullContextDecision.fullContextTokens,
                        contextBudgetTokens: promptBudget.usablePromptTokens,
                        injectedContextTokens: fullContextDecision.fullContextTokens,
                        decisionReason: "Using the full document. Retrieval previews are hidden because the model received the entire dataset."
                    )
                    await publish(injectedInfo, method: .full, stage: .decided)
                    return ResolvedRAGContext(
                        injectedContext: fullContext,
                        citations: [],
                        info: injectedInfo
                    )
                }

                await MainActor.run {
                    self.currentInjectedTokenOverhead = 0
                }
                let ragReason = trimmedFullContext.isEmpty
                    ? "Full document was empty, so smart retrieval was used."
                    : "Full document exceeded the final context budget, so smart retrieval was used instead."
                let chosenInfo = makeInfo(
                    stage: .chosen,
                    method: .rag,
                    retrievedChunkCount: 0,
                    injectedChunkCount: 0,
                    trimmedChunkCount: 0,
                    partialChunkInjected: false,
                    fullContentEstimateTokens: trimmedFullContext.isEmpty ? nil : fullContextDecision.fullContextTokens,
                    contextBudgetTokens: promptBudget.usablePromptTokens,
                    injectedContextTokens: 0,
                    decisionReason: ragReason
                )
                await publish(chosenInfo, method: .rag, stage: .processing)
                let detailed = await fetchDetailedContext()
                return await resolvePackedRAGContext(
                    from: detailed,
                    fullContentEstimateTokens: trimmedFullContext.isEmpty ? nil : fullContextDecision.fullContextTokens,
                    baseReason: ragReason
                )
            }
            let resolvedContext = await currentContextTask?.value
            currentContextTask = nil
            if let resolvedContext {
                self.streamMsgs[outIdx].retrievedContext = resolvedContext.injectedContext
                self.streamMsgs[outIdx].citations = resolvedContext.citations
                self.streamMsgs[outIdx].ragInjectionInfo = resolvedContext.info
                if !resolvedContext.injectedContext.isEmpty {
                    // Inject context inside the user section of the template to avoid breaking control tokens
                    promptStr = injectContextIntoPrompt(
                        original: promptStr,
                        context: resolvedContext.injectedContext,
                        kind: self.currentKind
                    )
                }
                if verboseLogging {
                    print("[ChatVM] Retrieved context (\(resolvedContext.injectedContext.count) chars): \(resolvedContext.injectedContext.prefix(200))...")
                }
                if !resolvedContext.injectedContext.isEmpty {
                    // Milestone: a RAG flow was used in chat (full or rag injection)
                    ReviewPrompter.shared.noteRAGUsed()
                    ReviewPrompter.shared.safeMaybePromptIfEligible(chatVM: self)
                }
            }
            if client == nil, let url = loadedURL {
                try? await ensureClient(url: url, settings: loadedSettings, format: loadedFormat, forceReload: false)
            }
        } else {
            injectionStage = .none
            injectionMethod = nil
            currentInjectedTokenOverhead = 0
            clearRAGInjectionArtifacts(messageIndex: outIdx)
        }

        let promptMetadata = Self.promptMetadataSummary(
            prompt: promptStr,
            stops: stops,
            format: self.loadedFormat,
            kind: self.currentKind,
            hasTemplate: self.promptTemplate != nil
        )
        Task { await logger.log("[Prompt] " + promptMetadata) }
        if injectionStage != .none {
            let methodStr: String = {
                switch injectionMethod {
                case .some(.full): return "full"
                case .some(.rag):  return "rag"
                case .none:        return "unknown"
                }
            }()
            let contextLength = self.streamMsgs.indices.contains(outIdx) ? (self.streamMsgs[outIdx].retrievedContext?.count ?? 0) : 0
            let ragMetadata = Self.ragMetadataSummary(
                method: methodStr,
                contextLength: contextLength,
                prompt: promptStr
            )
            Task {
                let message = "[Prompt][RAG] Context injected: " + ragMetadata
                await logger.log(message)
            }
        } else {
            Task { await logger.log("[Prompt][RAG] No context injected") }
        }
        Task { await logger.log("[Params] stops: \(stops)") }

        // Server-verified context trim: call /tokenize for exact token count and trim
        // history until the prompt fits within the shared usable prompt budget.
        if loadedFormat == .gguf, contextOverflowStrategy != .stopAtLimit {
            let tokenLimit = currentPromptBudget().usablePromptTokens
            var firstOverflowTokens: Int? = nil
            var lastVerifiedTokens: Int? = nil
            var trimIteration = 0
            while trimIteration < 64 {
                guard let tokenCount = await tokenCountViaServer(promptStr) else { break }
                lastVerifiedTokens = tokenCount
                guard tokenCount >= tokenLimit else { break }
                if firstOverflowTokens == nil { firstOverflowTokens = tokenCount }

                let candidates = removableHistoryIndices(for: history)
                if !candidates.isEmpty {
                    let removalIndex: Int
                    switch contextOverflowStrategy {
                    case .truncateMiddle: removalIndex = candidates[candidates.count / 2]
                    case .rollingWindow, .stopAtLimit: removalIndex = candidates[0]
                    }
                    history.remove(at: removalIndex)
                } else if !shrinkOversizedMessageForContext(
                    &history,
                    strategy: contextOverflowStrategy,
                    promptTokens: tokenCount,
                    tokenLimit: tokenLimit
                ) {
                    break
                }

                let (newPrompt, newStops, _) = buildPrompt(kind: currentKind, history: history)
                promptStr = newPrompt
                if !newStops.isEmpty { stops = newStops }

                if let safeCtx = self.streamMsgs[outIdx].retrievedContext, !safeCtx.isEmpty {
                    promptStr = injectContextIntoPrompt(original: promptStr, context: safeCtx, kind: self.currentKind)
                }

                Task { await logger.log("[ContextTrim] iteration=\(trimIteration) tokens=\(tokenCount) limit=\(tokenLimit) remaining_turns=\(history.count)") }
                trimIteration += 1
            }

            if let firstOverflowTokens {
                // The prompt genuinely overflowed; surface the pill even when the
                // cheap preflight estimate thought it would fit.
                registerContextOverflow(
                    strategy: contextOverflowStrategy,
                    details: ContextOverflowDetails(
                        promptTokens: firstOverflowTokens,
                        contextTokens: tokenLimit,
                        rawMessage: "verified-trim"
                    )
                )
            }
            if let lastVerifiedTokens, lastVerifiedTokens >= tokenLimit,
               ((await tokenCountViaServer(promptStr)) ?? lastVerifiedTokens) >= tokenLimit {
                // Even after exhausting every trim the prompt cannot fit; the server
                // would reject it with a 400, so stop here with a clear message.
                let message = contextFallbackMessage(for: contextOverflowStrategy)
                Task { await logger.log("[ContextTrim] giving up tokens=\(lastVerifiedTokens) limit=\(tokenLimit)") }
                await MainActor.run {
                    guard self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].text = "⚠️ " + message
                    self.streamMsgs[outIdx].streaming = false
                    self.streamMsgs[outIdx].promptProcessing = nil
                    self.streamingStore.finish()
                    self.injectionStage = .none
                    self.injectionMethod = nil
                }
                return
            }
        }

        didLaunchStreamTask = true
        let streamTask: Task<Void, Never> = Task(priority: nil) { [weak self, sessionIndex = sIdx, messageID] in
            guard let self else { return }
            await self.runInitialStreamTask(
                runID: myID,
                messageIndex: outIdx,
                promptStr: promptStr,
                stops: stops,
                history: history,
                input: input,
                initialLLMInput: llmInput,
                initialUsedImagePathsForThisRun: usedImagePathsForThisRun,
                remoteToolsAllowedOverride: remoteToolsAllowedOverride,
                sessionIndex: sessionIndex,
                messageID: messageID,
                isMLXFormat: isMLXFormat
            )
        }
        currentStreamTask = streamTask
        // Do not immediately clear the banner here; allow the delayed clear above
        currentInjectedTokenOverhead = 0
        // Only clear images actually used by THIS run to avoid races.
        var removedCount = 0
        if !usedImagePathsForThisRun.isEmpty {
            let usedSet = Set(usedImagePathsForThisRun)
            // Map paths to URLs and remove if still pending
            for path in usedSet {
                let url = URL(fileURLWithPath: path)
                if let idx = pendingImageURLs.firstIndex(of: url) {
                    pendingImageURLs.remove(at: idx)
                    pendingThumbnails.removeValue(forKey: url)
                    removedCount += 1
                }
            }
        }
        if removedCount > 0 {
            Task { await logger.log("[Images][Clear] cleared=\(removedCount)") }
        }
    }

    private func runInitialStreamTask(
        runID myID: Int,
        messageIndex outIdx: Int,
        promptStr: String,
        stops: [String],
        history: [Msg],
        input: String,
        initialLLMInput: LLMInput,
        initialUsedImagePathsForThisRun: [String],
        remoteToolsAllowedOverride: ToolAvailability,
        sessionIndex: Int,
        messageID: UUID,
        isMLXFormat: Bool
    ) async {
        var llmInput = initialLLMInput
        var usedImagePathsForThisRun = initialUsedImagePathsForThisRun

            defer {
                Task { @MainActor in
                    if self.currentContinuationTask == nil && self.streamSessionIndex == sessionIndex {
                        self.streamSessionIndex = nil
                    }
                }
            }
            // Give ET a brief moment after any cancellation to avoid
            // triggering an immediate prefill race on the next turn.
            if self.loadedFormat == .et {
                try? await Task.sleep(nanoseconds: 80_000_000) // ~80ms
            }
            if (!self.modelLoaded || self.client == nil), let url = self.loadedURL {
                do {
                    try await self.ensureClient(
                        url: url,
                        settings: self.loadedSettings,
                        format: self.loadedFormat,
                        forceReload: false
                    )
                } catch {
                    await MainActor.run {
                        guard myID == self.activeRunID,
                              self.streamMsgs.indices.contains(outIdx) else { return }
                        self.streamMsgs[outIdx].streaming = false
                        self.streamMsgs[outIdx].promptProcessing = nil
                        self.streamMsgs[outIdx].text = "⚠️ " + error.localizedDescription
                        self.streamingStore.finish()
                    }
                    await self.cancelPerfTracking(messageID: messageID)
                    return
                }
            }
            guard self.modelLoaded, let c = self.client else {
                await MainActor.run {
                    guard myID == self.activeRunID,
                          self.streamMsgs.indices.contains(outIdx) else { return }
                    self.streamMsgs[outIdx].streaming = false
                    self.streamMsgs[outIdx].promptProcessing = nil
                    self.streamMsgs[outIdx].text = "⚠️ Model is not ready. Please wait for loading to complete, then try again."
                    self.streamingStore.finish()
                }
                await self.cancelPerfTracking(messageID: messageID)
                return
            }
            AccessibilityAnnouncer.announceLocalized("Generating response…")
            let start = Date()
            await self.beginPerfTracking(messageID: messageID, start: start)
            var firstTok: Date?
            var count = 0
            var raw = ""
            var streamChunkMerger = StreamChunkMerger()
            var didProcessEmbeddedToolCall = false
            var pendingToolJSON: String? = nil
            var pendingAssistantText: String? = nil
            var didTriggerFinalAnswerStartHaptic = false
            // Coalesce UI updates: push the live bubble text into the narrow store at ~30 Hz,
            // and checkpoint into `sessions` (which republishes ChatVM) only ~10 Hz. This keeps
            // the whole app fluid during fast token generation while leaving the streamed text
            // current enough for copy/readbacks/finalize.
            var lastStoreFlush: ContinuousClock.Instant?
            var lastSessionFlush: ContinuousClock.Instant?
            let storeFlushInterval: Duration = .milliseconds(33)
            let sessionCheckpointInterval: Duration = .milliseconds(100)
            // Seed a visible <think> box for DeepSeek prompts that open a think section in the prompt
            if self.currentKind == .deepseek && promptStr.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("<think>") {
                raw = "<think>"
                await MainActor.run {
                    if self.streamMsgs.indices.contains(outIdx) {
                        self.streamingStore.update(visibleAssistantText(from: raw))
                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                    }
                }
                await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
            }

            var shouldRestartWithToolResult = false
            var didCancelInitialStreamForToolRestart = false
            do {
                // Build stop sequences. Avoid adding "Step N:" stops for CoT/ET models to not truncate reasoning-only streams.
                let isCotTemplate = (self.promptTemplate?.contains("<think>") == true)
                let defaultStopsBase = ["</s>", "<|im_end|>", "<|eot_id|>", "<end_of_turn>", "<eos>", "<｜User｜>", "<|User|>"]
                let defaultStops: [String] = {
                    if isCotTemplate || self.loadedFormat == .et || (self.activeSessionRetrievalDataset != nil) { return defaultStopsBase }
                    return defaultStopsBase + ["Step 1:", "Step 2:"]
                }()
                let stopSeqs = stops.isEmpty ? defaultStops : stops
                // Use the attachments snapshot from send time; do not consult
                // pendingImageURLs here because we clear them when the message is sent.
                let imagePaths = usedImagePathsForThisRun
                let useImages = self.supportsImageInput && !imagePaths.isEmpty && (self.loadedFormat == .mlx || self.loadedFormat == .gguf || self.loadedFormat == .et)
                // Preserve the snapshot if images are allowed; otherwise mark empty.
                usedImagePathsForThisRun = useImages ? imagePaths : []
                if !imagePaths.isEmpty {
                    if useImages {
                        let names = imagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                        Task { await logger.log("[Images][Use] yes format=\(String(describing: self.loadedFormat)) count=\(imagePaths.count) names=\(names.joined(separator: ", "))") }
                    } else {
                        var reasons: [String] = []
                        if !self.supportsImageInput { reasons.append("supportsImageInput=false") }
                        if !(self.loadedFormat == .mlx || self.loadedFormat == .gguf || self.loadedFormat == .et) {
                            reasons.append("format=\(String(describing: self.loadedFormat)) unsupported")
                        }
                        Task { await logger.log("[Images][Use] no reasons=\(reasons.joined(separator: ",")) count=\(imagePaths.count)") }
                    }
                }
                // If images are present and supported, inject image placeholders only for llama.cpp or MLX templates
                // For ET, do NOT inject placeholders; send raw text plus image binaries via multimodal
                let finalPrompt = promptStr
                let retrievedContext = self.streamMsgs.indices.contains(outIdx)
                    ? self.streamMsgs[outIdx].retrievedContext
                    : nil
                if self.loadedFormat == .et {
                    llmInput = useImages
                        ? LLMInput.multimodal(text: finalPrompt, imagePaths: imagePaths)
                        : LLMInput(.messages([ChatMessage(role: "user", content: finalPrompt)]))
                } else {
                    if useImages,
                       let structuredInput = self.structuredLoopbackMultimodalInput(
                            for: history,
                            imagePaths: imagePaths,
                            retrievedContext: retrievedContext
                       ) {
                        llmInput = structuredInput
                        Task {
                            await logger.log(
                                "[Loopback] structured_input=true multimodal=true qwen35=\(TemplateDrivenModelSupport.isQwen35(modelURL: self.loadedURL))"
                            )
                        }
                    } else if !useImages,
                              let structuredInput = self.structuredLoopbackInput(
                                for: history,
                                retrievedContext: retrievedContext
                              ) {
                        llmInput = structuredInput
                        Task {
                            await logger.log(
                                "[Loopback] structured_input=true multimodal=false qwen35=\(TemplateDrivenModelSupport.isQwen35(modelURL: self.loadedURL))"
                            )
                        }
                    } else {
                        llmInput = useImages
                            ? LLMInput.multimodal(text: finalPrompt, imagePaths: imagePaths)
                            : LLMInput(.plain(finalPrompt))
                    }
                }
                if let remoteService = self.remoteService {
                    let redactionResult = SensitiveDataDetector.redactedForRemote(
                        finalPrompt,
                        enabled: UserDefaults.standard.bool(forKey: "redactSensitiveDataForRemoteBackends")
                    )
                    let sensitiveSummary = redactionResult.summary
                    if !sensitiveSummary.isEmpty {
                        await logger.log(
                            "[Privacy][RemoteSensitivity] findings=\(sensitiveSummary.logSummary) total=\(sensitiveSummary.totalCount)"
                        )
                    }
                    if redactionResult.redacted {
                        await logger.log("[Privacy][RemoteRedaction] applied=true findings=\(sensitiveSummary.logSummary)")
                        llmInput = useImages
                            ? LLMInput.multimodal(text: redactionResult.text, imagePaths: imagePaths)
                            : LLMInput(.plain(redactionResult.text))
                    }
                    let allowTools = remoteToolsAllowedOverride.any
                    let activeRemoteSession = self.modelManager?.activeRemoteSession
                    let activeRemoteBackend = activeRemoteSession.flatMap { session in
                        self.modelManager?.remoteBackend(withID: session.backendID)
                    }
                    let hasExplicitRemoteSettings: Bool = {
                        guard let session = activeRemoteSession else { return false }
                        return self.modelManager?.hasSavedRemoteSettings(for: session.backendID, modelID: session.modelID) == true
                    }()
                    let isOpenRouterRemote = activeRemoteBackend?.isOpenRouter == true
                    let forwardedStops = isOpenRouterRemote ? [] : stopSeqs
                    let temperature = (isOpenRouterRemote && !hasExplicitRemoteSettings)
                        ? nil
                        : (self.loadedSettings?.temperature ?? 0.7)
                    let contextLength = self.loadedSettings?.contextLength
                    let topP = (isOpenRouterRemote && !hasExplicitRemoteSettings) ? nil : self.loadedSettings?.topP
                    let topK = (isOpenRouterRemote && !hasExplicitRemoteSettings) ? nil : self.loadedSettings?.topK
                    let minP = (isOpenRouterRemote && !hasExplicitRemoteSettings) ? nil : self.loadedSettings?.minP
                    let repeatPenalty = (isOpenRouterRemote && !hasExplicitRemoteSettings)
                        ? nil
                        : self.loadedSettings.map { Double($0.repetitionPenalty) }
                    await remoteService.updateOptions(
                        stops: forwardedStops,
                        temperature: temperature,
                        contextLength: contextLength,
                        topP: topP,
                        topK: topK,
                        minP: minP,
                        repeatPenalty: repeatPenalty,
                        includeTools: allowTools
                    )
                }
                // For remote sessions, show a brief loading indicator when starting
                // the first stream, instead of on model selection.
                if self.remoteService != nil && self.remoteLoadingPending == false {
                    self.remoteLoadingPending = true
                }
                if self.remoteLoadingPending {
                    await MainActor.run {
                        let format = self.loadedFormat ?? .gguf
                        self.loadingProgressTracker.startLoading(for: format)
                    }
                }
                // Emit a start log for this generation
                let inferenceSummary = self.inferenceBackendSummary
                Task {
                    let suffix = inferenceSummary.map { " inference=\($0)" } ?? ""
                    await logger.log("[ChatVM] ▶︎ Starting generation (format=\(String(describing: self.loadedFormat)), kind=\(self.currentKind), images=\(useImages ? imagePaths.count : 0))\(suffix)")
                    if let inferenceSummary, self.loadedFormat == .ane, inferenceSummary.contains("prefillMode=compat-single-query") {
                        await logger.log("[ChatVM][Perf][CML] note=stateful prefill is compat-single-query, so prompt tokens are processed one-by-one before the first generated token.")
                    }
                }
                let promptProgressHandler: (@Sendable (Double) -> Void)?
                if self.supportsPromptProcessingCard {
                    promptProgressHandler = { progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  myID == self.activeRunID,
                                  self.streamMsgs.indices.contains(outIdx) else { return }
                            self.updatePromptProcessingProgress(progress, messageIndex: outIdx)
                        }
                    }
                } else {
                    promptProgressHandler = nil
                }
                // Flip to Predicting when first token arrives
                for try await tok in try await c.textStream(from: llmInput, onPromptProgress: promptProgressHandler) {
                    let trimmedTok = tok.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Handle in-band tool calls emitted as tokens
                    if trimmedTok.hasPrefix("TOOL_CALL:") {
                        // Skip tool calls that occur inside <think> chain-of-thought
                        let inThink: Bool = {
                            if let open = raw.range(of: "<think>", options: .backwards) {
                                if let close = raw.range(of: "</think>", options: .backwards) { return open.lowerBound > close.lowerBound }
                                return true
                            }
                            return false
                        }()
                        if inThink && self.remoteService == nil { continue }
                        if let (handled, trailing) = await interceptToolCallIfPresent(trimmedTok, messageIndex: outIdx, chatVM: self) {
                            await MainActor.run {
                                // Surface web-search usage immediately.
                                if self.streamMsgs.indices.contains(outIdx) { self.streamMsgs[outIdx].usedWebSearch = true }
                            }
                            // Preserve the assistant text prior to the tool call so we can
                            // reinject it when continuing after tool execution.
                            let anchoredRaw = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: raw))
                            pendingAssistantText = anchoredRaw
                            raw = anchoredRaw
                            // Do not inject TOOL_RESULT payloads into visible transcript text.
                            // ToolCallView is driven by `msg.toolCalls` + `msg.webHits/webError`.
                            if let trailing, !trailing.isEmpty {
                                raw += trailing
                                await MainActor.run {
                                    if self.streamMsgs.indices.contains(outIdx) {
                                        self.streamingStore.update(visibleAssistantText(from: raw))
                                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                                    }
                                }
                            }
                            await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                            // Capture tool result and restart generation with it injected
                            let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            pendingToolJSON = json
                            didProcessEmbeddedToolCall = true
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            break
                        }
                    }
                    if Task.isCancelled { break }
                    // Intercept tool-calls emitted by the model and surface UI hints
                    if trimmedTok.hasPrefix("TOOL_RESULT:") || trimmedTok.hasPrefix("TOOL_CALL:") {
                        if trimmedTok.hasPrefix("TOOL_RESULT:") {
                            let json = trimmedTok.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await logger.log("[Tool][Stream] TOOL_RESULT raw: \(json)") }
                            if let data = json.data(using: .utf8) {
                                // Decode SearXNG-style [WebHit] payload
                                struct SimpleWebHit: Decodable {
                                    let title: String
                                    let url: String
                                    let snippet: String
                                    let engine: String?
                                    let score: Double?
                                }
                                if let hits = try? JSONDecoder().decode([SimpleWebHit].self, from: data) {
                                    await MainActor.run {
                                        if self.streamMsgs.indices.contains(outIdx) {
                                            self.streamMsgs[outIdx].usedWebSearch = true
                                            self.streamMsgs[outIdx].webError = nil
                                            self.streamMsgs[outIdx].webHits = hits.enumerated().map { (i, h) in
                                                let engine = h.engine?.trimmingCharacters(in: .whitespacesAndNewlines)
                                                let resolvedEngine = engine?.isEmpty == false ? engine! : "searxng"
                                                return .init(
                                                    id: String(i+1),
                                                    title: h.title,
                                                    snippet: h.snippet,
                                                    url: h.url,
                                                    engine: resolvedEngine,
                                                    score: h.score ?? 0
                                                )
                                            }
                                        }
                                    }
                                } else if let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    // Fallback: generic error payloads {"error":..} or {"code":..,"message":..}
                                    let err: String? = {
                                        if let e = any["error"] as? String { return e }
                                        if let msg = any["message"] as? String { return msg }
                                        if let code = any["code"] { return "Error: \(code)" }
                                        return nil
                                    }()
                                    if let err = err, !err.isEmpty {
                                        await MainActor.run {
                                            if self.streamMsgs.indices.contains(outIdx) {
                                                self.streamMsgs[outIdx].usedWebSearch = true
                                                self.streamMsgs[outIdx].webError = err
                                                self.streamMsgs[outIdx].webHits = nil
                                            }
                                        }
                                    }
                                }
                            }
                            // Store the tool result and restart to continue the thought even on error
                            let anchoredRaw = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: raw))
                            pendingAssistantText = anchoredRaw
                            raw = anchoredRaw
                            pendingToolJSON = json
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            break
                        } else if trimmedTok.hasPrefix("TOOL_CALL:") {
                            Task { await logger.log("[Tool][Stream] TOOL_CALL token: \(trimmedTok)") }
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                        }
                    }
                    if firstTok == nil {
                        firstTok = Date()
                        if self.remoteLoadingPending {
                            await MainActor.run {
                                self.loadingProgressTracker.completeLoading()
                            }
                            self.remoteLoadingPending = false
                        }
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                        }
                        if self.injectionStage != .none { self.injectionStage = .predicting }
                    }
                        if self.currentKind == .gemma && !self.gemmaAutoTemplated {
                            let t = trimmedTok
                            if !t.hasPrefix("<|") { self.gemmaAutoTemplated = true }
                        }
                        // Keep the decision banner visible until streaming completes to improve UX feedback
                        Task { await logger.log("[ChatVM] First token received") }
                    }
                    count += 1
                    await self.recordToken(messageID: messageID)
                    let appendChunk = streamChunkMerger.append(tok, to: &raw)
                    
                    // Handle rolling thoughts for <think> tags
                    if !appendChunk.isEmpty {
                        await handleRollingThoughts(raw: raw, messageIndex: outIdx)
                    }
                    
                    // Check for embedded <tool_call>…</tool_call> or bare JSON tool call once per call
                    if !didProcessEmbeddedToolCall {
                        if let result = await interceptEmbeddedToolCallIfPresent(in: raw, messageIndex: outIdx, chatVM: self),
                           let handled = result.token {
                            Task { await logger.log("[Tool][ChatVM] Embedded tool call detected and dispatched") }
                            // Preserve assistant text prior to tool result injection for prompt rebuilding
                            let anchoredCleaned = result.cleanedText
                            pendingAssistantText = anchoredCleaned
                            raw = anchoredCleaned
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                    self.streamingStore.update(visibleAssistantText(from: anchoredCleaned))
                                    self.streamMsgs[outIdx].text = visibleAssistantText(from: anchoredCleaned)
                                }
                            }
                            await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                            let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            pendingToolJSON = json
                            didProcessEmbeddedToolCall = true
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            Task { await logger.log("[Tool][ChatVM] Generation cancelled to resume after tool result") }
                            break
                        }
                    }
                    // Let the model run freely; rely on backend context limits
                    if self.currentKind == .gemma && !self.gemmaAutoTemplated, let r = raw.range(of: "<|im_end|>") {
                        raw = String(raw[..<r.lowerBound])
                        break
                    }
                    // Enforce stop sequences for all backends (including MLX) using suffix check.
                    // Do not apply stop if we are inside an open <think>…</think> block, so CoT isn't cut off.
                    if let sfx = stopSeqs.first(where: { raw.hasSuffix($0) }) {
                        let lastOpen = raw.range(of: "<think>", options: .backwards)
                        let lastClose = raw.range(of: "</think>", options: .backwards)
                        let insideThink = {
                            if let o = lastOpen {
                                if let c = lastClose { return o.lowerBound > c.lowerBound }
                                return true
                            }
                            return false
                        }()
                        if !insideThink {
                            raw = String(raw.dropLast(sfx.count))
                            break
                        }
                    }
                    let now = ContinuousClock().now
                    let shouldFlushStore = lastStoreFlush.map { now - $0 >= storeFlushInterval } ?? true
                    let shouldCheckpointSession = lastSessionFlush.map { now - $0 >= sessionCheckpointInterval } ?? true
                    if shouldFlushStore { lastStoreFlush = now }
                    if shouldFlushStore, shouldCheckpointSession { lastSessionFlush = now }
                    let streamUpdate: (triggerHaptic: Bool, stopAfterParagraph: Bool) = shouldFlushStore
                        ? await MainActor.run { () -> (triggerHaptic: Bool, stopAfterParagraph: Bool) in
                            guard myID == self.activeRunID,
                                  self.streamMsgs.indices.contains(outIdx),
                                  self.streamMsgs[outIdx].streaming else { return (false, false) }
                            let visibleText = visibleAssistantText(from: raw)
                            // High-frequency: live bubble + auto-scroll (narrow observable).
                            self.streamingStore.update(visibleText)
                            // Low-frequency: checkpoint into sessions for copy/readbacks/finalize.
                            if shouldCheckpointSession {
                                self.streamMsgs[outIdx].text = visibleText
                            }
                            let shouldStopAfterParagraph = self.shouldStopAtRequestedParagraphBoundary(in: visibleText)
                            if didTriggerFinalAnswerStartHaptic {
                                return (false, shouldStopAfterParagraph)
                            }
                            return (self.strictFinalAnswerText(forText: visibleText, toolCalls: self.streamMsgs[outIdx].toolCalls) != nil, shouldStopAfterParagraph)
                        }
                        : (false, false)
                    if streamUpdate.stopAfterParagraph {
                        await logger.log("[ChatVM] Stop-after-paragraph boundary reached")
                        await MainActor.run {
                            self.clearStopAfterParagraphRequest()
                        }
                        c.cancelActive()
                        break
                    }
                    if streamUpdate.triggerHaptic {
#if os(iOS)
                        Haptics.impact(.medium)
#endif
                        didTriggerFinalAnswerStartHaptic = true
                    }
                    if shouldRestartWithToolResult { break }
                }
            } catch {
                let wasCancellation = (error as? CancellationError) != nil
                    || (error as? URLError)?.code == .cancelled
                let intentionalToolRestartCancellation = wasCancellation && didCancelInitialStreamForToolRestart
                if intentionalToolRestartCancellation {
                    await logger.log("[Tool][ChatVM] Ignoring intentional cancellation during tool restart")
                }
                await MainActor.run {
                    guard myID == self.activeRunID,
                          self.streamMsgs.indices.contains(outIdx) else { return }
                    if !intentionalToolRestartCancellation {
                        // Commit any partial streamed text (loop only checkpointed periodically)
                        // and stop rendering the bubble from the store.
                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                        self.streamingStore.finish()
                        self.streamMsgs[outIdx].streaming = false
                    }
                    self.clearPromptProcessing(for: outIdx)
                    // Consider an in‑app review prompt after a successful turn.
                    ReviewPrompter.shared.safeMaybePromptIfEligible(chatVM: self)
                    if !wasCancellation {
                        let message = error.localizedDescription
                        if let overflow = self.parseContextOverflowDetails(from: message) {
                            self.registerContextOverflow(strategy: self.contextOverflowStrategy, details: overflow)
                            if self.contextOverflowStrategy == .stopAtLimit {
                                self.streamMsgs[outIdx].text = "⚠️ " + self.contextStopMessage(details: overflow)
                            } else {
                                let promptStr = overflow.promptTokens.map { "\($0)" } ?? "?"
                                let ctxStr = overflow.contextTokens.map { "\($0)" } ?? "?"
                                self.streamMsgs[outIdx].text = "⚠️ " + self.contextFallbackMessage(for: self.contextOverflowStrategy) + " (\(promptStr)/\(ctxStr) tokens)"
                            }
                        } else {
                            let lower = message.lowercased()
                            if !lower.contains("decode") {
                                self.streamMsgs[outIdx].text = "⚠️ " + message
                            }
                        }
                    }
                }
                if !wasCancellation {
                    self.markRollingThoughtsInterrupted(forMessageAt: outIdx)
                }
                if self.loadedFormat == .afm && !intentionalToolRestartCancellation {
                    self.applyPendingAFMToolSummary(to: outIdx)
                    self.applyPendingAFMRouteInfo(to: outIdx)
                }
                if self.remoteLoadingPending {
                    await MainActor.run {
                        self.loadingProgressTracker.completeLoading()
                    }
                    self.remoteLoadingPending = false
                }
                if intentionalToolRestartCancellation {
                    didCancelInitialStreamForToolRestart = false
                } else {
                    await self.cancelPerfTracking(messageID: messageID)
                    return
                }
            }
            if pendingToolJSON == nil, let remoteService = await self.remoteService {
                let bufferedTokens = await remoteService.drainBufferedToolTokens()
                if !bufferedTokens.isEmpty {
                    for token in bufferedTokens {
                        if Task.isCancelled { break }
                        if shouldRestartWithToolResult { break }
                        let trimmedTok = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedTok.isEmpty else { continue }
                        if trimmedTok.hasPrefix("TOOL_RESULT:") {
                            let json = trimmedTok.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            Task { await logger.log("[Tool][Stream][Buffered] TOOL_RESULT raw: \(json)") }
                            if let data = json.data(using: .utf8) {
                                struct BufferedSimpleWebHit: Decodable {
                                    let title: String
                                    let url: String
                                    let snippet: String
                                    let engine: String?
                                    let score: Double?
                                }
                                if let hits = try? JSONDecoder().decode([BufferedSimpleWebHit].self, from: data) {
                                    await MainActor.run {
                                        if self.streamMsgs.indices.contains(outIdx) {
                                            self.streamMsgs[outIdx].usedWebSearch = true
                                            self.streamMsgs[outIdx].webError = nil
                                            self.streamMsgs[outIdx].webHits = hits.enumerated().map { (i, h) in
                                                let engine = h.engine?.trimmingCharacters(in: .whitespacesAndNewlines)
                                                let resolvedEngine = engine?.isEmpty == false ? engine! : "searxng"
                                                return .init(
                                                    id: String(i+1),
                                                    title: h.title,
                                                    snippet: h.snippet,
                                                    url: h.url,
                                                    engine: resolvedEngine,
                                                    score: h.score ?? 0
                                                )
                                            }
                                        }
                                    }
                                } else if let any = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                                    let err: String? = {
                                        if let e = any["error"] as? String { return e }
                                        if let msg = any["message"] as? String { return msg }
                                        if let code = any["code"] { return "Error: \(code)" }
                                        return nil
                                    }()
                                    if let err = err, !err.isEmpty {
                                        await MainActor.run {
                                            if self.streamMsgs.indices.contains(outIdx) {
                                                self.streamMsgs[outIdx].usedWebSearch = true
                                                self.streamMsgs[outIdx].webError = err
                                                self.streamMsgs[outIdx].webHits = nil
                                            }
                                        }
                                    }
                                }
                            }
                            let anchoredRaw = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: raw))
                            pendingAssistantText = anchoredRaw
                            raw = anchoredRaw
                            pendingToolJSON = json
                            shouldRestartWithToolResult = true
                            didCancelInitialStreamForToolRestart = true
                            c.cancelActive()
                            break
                        } else if trimmedTok.hasPrefix("TOOL_CALL:") {
                            Task { await logger.log("[Tool][Stream][Buffered] TOOL_CALL token: \(trimmedTok)") }
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                            if let (handled, trailing) = await interceptToolCallIfPresent(trimmedTok, messageIndex: outIdx, chatVM: self) {
                                let anchoredRaw = appendingToolAnchor(to: raw)
                                pendingAssistantText = anchoredRaw
                                raw = anchoredRaw
                                if let trailing, !trailing.isEmpty {
                                raw += trailing
                                await MainActor.run {
                                    if self.streamMsgs.indices.contains(outIdx) {
                                            self.streamingStore.update(visibleAssistantText(from: raw))
                                            self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                                    }
                                }
                            }
                                await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                                let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                                pendingToolJSON = json
                                didProcessEmbeddedToolCall = true
                                shouldRestartWithToolResult = true
                                didCancelInitialStreamForToolRestart = true
                                c.cancelActive()
                                break
                            }
                        }
                    }
                }
            }
            // Final safety net: if the model emitted a <tool_call> or bare JSON tool call
            // right at the end of the stream and we didn't process it mid-stream, detect
            // and dispatch it now so the conversation reliably continues.
            if !didProcessEmbeddedToolCall, pendingToolJSON == nil {
                if let result = await interceptEmbeddedToolCallIfPresent(in: raw, messageIndex: outIdx, chatVM: self),
                   let handled = result.token {
                    Task { await logger.log("[Tool][ChatVM] Post-stream embedded tool call detected and dispatched") }
                    // Preserve assistant text prior to the tool call
                    let anchoredCleaned = result.cleanedText
                    pendingAssistantText = anchoredCleaned
                    raw = anchoredCleaned
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.streamMsgs[outIdx].usedWebSearch = true
                            self.streamingStore.update(visibleAssistantText(from: anchoredCleaned))
                            self.streamMsgs[outIdx].text = visibleAssistantText(from: anchoredCleaned)
                        }
                    }
                    await self.handleRollingThoughts(raw: raw, messageIndex: outIdx)
                    let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    pendingToolJSON = json
                    didProcessEmbeddedToolCall = true
                }
            }

            if self.remoteLoadingPending {
                await MainActor.run {
                    self.loadingProgressTracker.completeLoading()
                }
                self.remoteLoadingPending = false
            }

            // Do not hide or alter chain-of-thought: preserve full model output including <think> sections.
            // Avoid transforming enumerations (e.g., "Step 1:") to keep original thinking intact.
            let cleanedBase = self.cleanOutput(raw, kind: self.currentKind)
            var cleaned = pendingToolJSON == nil
                ? await self.scrubEmbeddedToolArtifactsWithoutDispatch(in: cleanedBase, messageIndex: outIdx)
                : cleanedBase
            if pendingToolJSON == nil {
                cleaned = await pruneDanglingPlaceholderToolCalls(
                    messageIndex: outIdx,
                    chatVM: self,
                    preferredText: cleaned
                ) ?? cleaned
            }
            // Trailing flush: commit the final visible text into `sessions` so finalize sees
            // the complete output (the per-token loop only checkpointed periodically).
            if pendingToolJSON == nil {
                await MainActor.run {
                    if myID == self.activeRunID,
                       self.streamMsgs.indices.contains(outIdx),
                       self.streamMsgs[outIdx].streaming {
                        self.streamMsgs[outIdx].text = visibleAssistantText(from: raw)
                    }
                }
            }
            let injectionOverhead = (self.injectionMethod == .full && self.currentInjectedTokenOverhead > 0) ? self.currentInjectedTokenOverhead : 0
            let perfResult: Msg.Perf? = shouldRestartWithToolResult ? nil : await self.finalizePerf(messageID: messageID, injectionOverhead: injectionOverhead)
            await self.finalizeAssistantStream(
                runID: myID,
                messageIndex: outIdx,
                cleanedText: cleaned,
                pendingToolJSON: pendingToolJSON,
                perfResult: perfResult,
                tokenCount: count,
                generationStart: start,
                firstTokenTimestamp: firstTok,
                isMLXFormat: isMLXFormat
            )
            if self.loadedFormat == .afm {
                self.applyPendingAFMToolSummary(to: outIdx)
                self.applyPendingAFMRouteInfo(to: outIdx)
            }
            // Set session title from first user query with a sensible word cap
            if let sIdx = self.streamSessionIndex,
               self.sessions.indices.contains(sIdx),
               self.sessions[sIdx].title.isEmpty || self.sessions[sIdx].title == "New chat" {
                let normalized = input
                    .replacingOccurrences(of: "[\n\r]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // Remove surrounding quotes if present
                let unquoted: String = {
                    if normalized.hasPrefix("\"") && normalized.hasSuffix("\"") && normalized.count > 2 {
                        return String(normalized.dropFirst().dropLast())
                    }
                    if normalized.hasPrefix("'") && normalized.hasSuffix("'") && normalized.count > 2 {
                        return String(normalized.dropFirst().dropLast())
                    }
                    return normalized
                }()
                // Limit to a sensible word count (e.g., 8 words)
                let words = unquoted.split { $0.isWhitespace }
                let capped = words.prefix(8).joined(separator: " ")
                let cleaned = capped.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
                self.sessions[sIdx].title = cleaned.isEmpty ? Self.defaultTitle(date: Date()) : cleaned
            }
            // If a tool was called mid-stream
            if let toolJSON = pendingToolJSON {
                // For ET models: do NOT append any visible user message.
                // We'll continue by sending a hidden user nudge (not shown in UI) so the
                // assistant continues streaming into the same bubble.
                if self.loadedFormat == .et {
                    // Fall through to continuation task, which will stream the assistant's
                    // reply into the SAME assistant box (outIdx) using a hidden postToolInput.
                }
                // Non-ET: continue in place with hidden tool context
                let continuationTask: Task<Void, Never> = Task { [weak self] in
                    guard let self else { return }
                    guard let client = self.client else {
                        await self.cancelPerfTracking(messageID: messageID)
                        return
                    }
                    await self.runToolContinuation(
                        client: client,
                        initialPendingAssistantText: pendingAssistantText,
                        sessionIndex: sessionIndex,
                        messageID: messageID,
                        history: history,
                        outIdx: outIdx,
                        toolJSON: toolJSON,
                        streamChunkMergeMode: streamChunkMerger.mode,
                        usedImagePathsForThisRun: usedImagePathsForThisRun
                    )
                }
                self.currentContinuationTask = continuationTask
            }
    }

    // maybeAutoTitle removed in favor of using the first user query as title

    private func runToolContinuation(
        client: AnyLLMClient,
        initialPendingAssistantText: String?,
        sessionIndex: Int,
        messageID: UUID,
        history: [ChatVM.Msg],
        outIdx: Int,
        toolJSON: String,
        streamChunkMergeMode: StreamChunkMergeMode,
        usedImagePathsForThisRun: [String]
    ) async {
        defer {
            Task { @MainActor in
                if self.streamSessionIndex == sessionIndex {
                    self.streamSessionIndex = nil
                }
            }
        }

        // Hidden assistant transcript used only for continuation prompt rebuilding.
        var pendingAssistantText = initialPendingAssistantText

        let originalQuestion = history.last(where: {
            let role = $0.role.lowercased()
            return role == "user" || $0.role == "🧑‍💻"
        })?.text ?? ""

        var continuationHistory = history
        if continuationHistory.indices.contains(outIdx) {
            continuationHistory[outIdx].text = pendingAssistantText ?? ""
        }
        let toolMessage = ChatVM.Msg(
            role: "tool",
            text: toolJSON,
            timestamp: Date()
        )
        continuationHistory.append(toolMessage)

        var localHistory = continuationHistory
        var continuationChunkMerger = StreamChunkMerger(mode: streamChunkMergeMode)
        var didTriggerFinalAnswerStartHaptic = false
        // Same coalescing policy as the initial stream loop (see notes there).
        var lastStoreFlush: ContinuousClock.Instant?
        var lastSessionFlush: ContinuousClock.Instant?
        let storeFlushInterval: Duration = .milliseconds(33)
        let sessionCheckpointInterval: Duration = .milliseconds(100)

        await MainActor.run {
            if self.streamMsgs.indices.contains(outIdx) {
                self.streamMsgs[outIdx].streaming = true
                // Re-arm the narrow store for the post-tool continuation, seeding it with the
                // text already on screen so the bubble doesn't flash empty.
                self.streamingStore.begin(id: self.streamMsgs[outIdx].id, initialText: self.streamMsgs[outIdx].text)
                if self.supportsPromptProcessingCard {
                    self.startPromptProcessing(for: outIdx)
                    self.streamMsgs[outIdx].postToolWaiting = false
                } else {
                    self.clearPromptProcessing(for: outIdx)
                    self.streamMsgs[outIdx].postToolWaiting = true
                }
                AccessibilityAnnouncer.announceLocalized("Generating response…")
            }
        }

        var remainingToolTurns = 1
        var prefillRetryAttempts = 0
        let maxPrefillRetries = 3
        continuationLoop: while true {
            var postToolInput: LLMInput? = nil
            await MainActor.run {
                if self.streamMsgs.indices.contains(outIdx) {
                    if self.supportsPromptProcessingCard {
                        self.startPromptProcessing(for: outIdx)
                        self.streamMsgs[outIdx].postToolWaiting = false
                    } else {
                        self.clearPromptProcessing(for: outIdx)
                        self.streamMsgs[outIdx].postToolWaiting = true
                    }
                }
            }
            if self.loadedFormat == .et {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if localHistory.indices.contains(outIdx) {
                let latestAssistantText: String
                if let preserved = pendingAssistantText {
                    latestAssistantText = preserved
                } else {
                    latestAssistantText = await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            return self.streamMsgs[outIdx].text
                        } else {
                            return localHistory[outIdx].text
                        }
                    }
                }
                localHistory[outIdx].text = latestAssistantText
            }
            var promptHistory: [ChatVM.Msg] = {
                guard self.loadedFormat != .et else { return localHistory }
                let latestToolName = self.streamMsgs.indices.contains(outIdx)
                    ? self.streamMsgs[outIdx].toolCalls?.last?.toolName
                    : nil
                var enrichedHistory = localHistory
                enrichedHistory.append(
                    ChatVM.Msg(
                        role: "user",
                        text: self.postToolContinuationNudge(
                            toolName: latestToolName,
                            originalQuestion: originalQuestion
                        ),
                        timestamp: Date()
                    )
                )
                return enrichedHistory
            }()
            // Tool results (web pages, search dumps) can blow past the context
            // budget mid-conversation; apply the same overflow plan as the
            // initial send so the continuation doesn't 400 with a raw error.
            if self.loadedFormat != .et {
                let continuationPlan = self.planHistoryForContextOverflow(history: promptHistory)
                if continuationPlan.initialEstimate > self.contextSoftLimitTokens() {
                    self.registerContextOverflow(
                        strategy: self.contextOverflowStrategy,
                        details: ContextOverflowDetails(
                            promptTokens: continuationPlan.initialEstimate,
                            contextTokens: self.currentPromptBudget().usablePromptTokens,
                            rawMessage: "continuation-overflow"
                        )
                    )
                }
                if continuationPlan.requiresStop && self.contextOverflowStrategy == .stopAtLimit {
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                            let stopNote = self.contextStopMessage(details: nil)
                            let partialText = localHistory.indices.contains(outIdx)
                                ? visibleAssistantText(from: localHistory[outIdx].text)
                                : ""
                            self.streamMsgs[outIdx].text = partialText + "\n⚠️ " + stopNote
                            self.streamMsgs[outIdx].postToolWaiting = false
                            self.streamingStore.finish()
                        }
                    }
                    break continuationLoop
                }
                promptHistory = continuationPlan.history
            }
            let (_, continuationStops, _) = self.buildPrompt(kind: self.currentKind, history: promptHistory)
            if self.loadedFormat == .et {
                let previousUser = history.last(where: { $0.role.lowercased() == "user" || $0.role == "🧑‍💻" })?.text ?? ""
                let trimmedQuestion = previousUser.trimmingCharacters(in: .whitespacesAndNewlines)
                let nudgeBody: String = {
                    if trimmedQuestion.isEmpty {
                        return "With these search results, continue your earlier response. Do not call web search again unless explicitly requested."
                    }
                    return "With these results from search, respond to: \(trimmedQuestion). Do not call web search again; use the context you received."
                }()
                let toolPayload: String = (localHistory.last { $0.role == "tool" })?.text ?? toolJSON
                let toolMsg = ChatMessage(role: "tool", content: toolPayload)
                let userMsg = ChatMessage(role: "user", content: nudgeBody)
                postToolInput = LLMInput(.messages([toolMsg, userMsg]))
            } else {
                let retrievedContext = self.streamMsgs.indices.contains(outIdx)
                    ? self.streamMsgs[outIdx].retrievedContext
                    : nil
                if !usedImagePathsForThisRun.isEmpty,
                   let structuredInput = self.structuredLoopbackMultimodalInput(
                    for: promptHistory,
                    imagePaths: usedImagePathsForThisRun,
                    retrievedContext: retrievedContext
                   ) {
                    postToolInput = structuredInput
                } else if let structuredInput = self.structuredLoopbackInput(
                    for: promptHistory,
                    retrievedContext: retrievedContext
                ) {
                    postToolInput = structuredInput
                } else {
                    let (continuationPrompt, _, _) = self.buildPrompt(kind: self.currentKind, history: promptHistory)
                    postToolInput = LLMInput.plain(continuationPrompt)
                }
            }

            let baseAssistantText = localHistory.indices.contains(outIdx) ? localHistory[outIdx].text : ""
            let baseVisibleAssistantText = visibleAssistantText(from: baseAssistantText)
            var continuation = ""
            var nextToolJSON: String? = nil
            var didCancelContinuationForToolRestart = false
            var didCancelContinuationForToolResult = false
            let maxContTokens = Int(self.contextLimit * 0.4)
            var contTokCount = 0
            var resolvedFinalContinuationText: String? = nil
            do {
                guard let input = postToolInput else { break }
                let continuationPromptProgressHandler: (@Sendable (Double) -> Void)?
                if self.supportsPromptProcessingCard {
                    continuationPromptProgressHandler = { progress in
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.streamMsgs.indices.contains(outIdx) else { return }
                            self.updatePromptProcessingProgress(progress, messageIndex: outIdx)
                        }
                    }
                } else {
                    continuationPromptProgressHandler = nil
                }
                for try await t in try await client.textStream(
                    from: input,
                    onPromptProgress: continuationPromptProgressHandler
                ) {
                    if Task.isCancelled { break }
                    await self.recordToken(messageID: messageID)
                    let trimmedT = t.trimmingCharacters(in: .whitespacesAndNewlines)

                    if trimmedT.hasPrefix("TOOL_CALL:") {
                        if remainingToolTurns <= 0 {
                            await logger.log("[Tool][Continuation] Ignoring additional tool call (limit reached for this turn).")
                            continue
                        }
                        if let (handled, trailing) = await interceptToolCallIfPresent(trimmedT, messageIndex: outIdx, chatVM: self) {
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamMsgs[outIdx].usedWebSearch = true
                                }
                            }
                            let json = handled.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                            nextToolJSON = json
                            continuation = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: continuation))
                            pendingAssistantText = continuation
                            if let trailing, !trailing.isEmpty {
                                continuation += trailing
                            }
                            let continuationText = baseVisibleAssistantText + visibleAssistantText(from: continuation)
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamingStore.update(continuationText)
                                    self.streamMsgs[outIdx].text = continuationText
                                }
                            }
                            await self.handleRollingThoughts(raw: continuationText, messageIndex: outIdx)
                            await MainActor.run {
                                if self.streamMsgs.indices.contains(outIdx) {
                                    self.streamMsgs[outIdx].postToolWaiting = true
                                }
                            }
                            didCancelContinuationForToolRestart = true
                            client.cancelActive()
                            break
                        }
                    }
                    if trimmedT.hasPrefix("TOOL_RESULT:") {
                        let json = trimmedT.replacingOccurrences(of: "TOOL_RESULT:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                        pendingAssistantText = appendingToolAnchor(to: scrubVisibleToolArtifacts(from: continuation))
                        nextToolJSON = json
                        didCancelContinuationForToolResult = true
                        client.cancelActive()
                        break
                    }

                    _ = continuationChunkMerger.append(t, to: &continuation)
                    contTokCount += 1

                    if contTokCount == 1 {
                        await MainActor.run {
                            if self.streamMsgs.indices.contains(outIdx) {
                                self.clearPromptProcessing(for: outIdx)
                                self.streamMsgs[outIdx].postToolWaiting = false
                            }
                        }
                    }

                    let visibleContinuation = baseVisibleAssistantText + visibleAssistantText(from: continuation)
                    let now = ContinuousClock().now
                    let shouldFlushStore = lastStoreFlush.map { now - $0 >= storeFlushInterval } ?? true
                    let shouldCheckpointSession = lastSessionFlush.map { now - $0 >= sessionCheckpointInterval } ?? true
                    if shouldFlushStore { lastStoreFlush = now }
                    if shouldFlushStore, shouldCheckpointSession { lastSessionFlush = now }
                    if shouldFlushStore {
                        let shouldTriggerFinalAnswerHaptic = await MainActor.run { () -> Bool in
                            guard self.streamMsgs.indices.contains(outIdx) else { return false }
                            // High-frequency: live bubble + auto-scroll (narrow observable).
                            self.streamingStore.update(visibleContinuation)
                            // Low-frequency: checkpoint into sessions for copy/readbacks/finalize.
                            if shouldCheckpointSession {
                                self.streamMsgs[outIdx].text = visibleContinuation
                            }
                            if didTriggerFinalAnswerStartHaptic { return false }
                            return self.strictFinalAnswerText(forText: visibleContinuation, toolCalls: self.streamMsgs[outIdx].toolCalls) != nil
                        }
                        if shouldTriggerFinalAnswerHaptic {
#if os(iOS)
                            Haptics.impact(.medium)
#endif
                            didTriggerFinalAnswerStartHaptic = true
                        }
                    }
                    let fullText = visibleContinuation
                    await self.handleRollingThoughts(raw: fullText, messageIndex: outIdx)

                    if let sfx = continuationStops.first(where: { continuation.hasSuffix($0) }) {
                        let lastOpen = fullText.range(of: "<think>", options: .backwards)
                        let lastClose = fullText.range(of: "</think>", options: .backwards)
                        let insideThink = {
                            if let o = lastOpen {
                                if let c = lastClose { return o.lowerBound > c.lowerBound }
                                return true
                            }
                            return false
                        }()
                        if !insideThink {
                            continuation = String(continuation.dropLast(sfx.count))
                            break
                        }
                    }
                    if contTokCount >= maxContTokens { break }
                }
                // Trailing flush on successful completion: commit the final visible text
                // (the loop only checkpointed periodically) into both the store and sessions.
                await MainActor.run {
                    if self.streamMsgs.indices.contains(outIdx) {
                        let finalVisible = baseVisibleAssistantText + visibleAssistantText(from: continuation)
                        self.streamingStore.update(finalVisible)
                        self.streamMsgs[outIdx].text = finalVisible
                    }
                }
            } catch {
                let wasCancellation = (error as? CancellationError) != nil
                    || (error as? URLError)?.code == .cancelled
                let intentionalContinuationCancellation = wasCancellation &&
                    (didCancelContinuationForToolRestart || didCancelContinuationForToolResult)
                if intentionalContinuationCancellation {
                    await logger.log("[Tool][Continuation] Ignoring intentional cancellation during restart")
                }
                let lower = error.localizedDescription.lowercased()
                if self.loadedFormat == .et && (lower.contains("prefill aborted") || lower.contains("interrupted")) {
                    if prefillRetryAttempts < maxPrefillRetries {
                        let attempt = prefillRetryAttempts
                        prefillRetryAttempts += 1
                        let backoff = UInt64(250_000_000 * Int(pow(2.0, Double(attempt))))
                        await logger.log("[ChatVM] Prefill aborted. Retrying in \(backoff / 1_000_000)ms (attempt \(attempt + 1)/\(maxPrefillRetries)).")
                        try? await Task.sleep(nanoseconds: backoff)
                        continue continuationLoop
                    } else {
                        await logger.log("[ChatVM] Prefill aborted after \(maxPrefillRetries) retries. Failing.")
                    }
                }
                if !intentionalContinuationCancellation {
                    let overflow = self.parseContextOverflowDetails(from: error.localizedDescription)
                    if let overflow {
                        self.registerContextOverflow(strategy: self.contextOverflowStrategy, details: overflow)
                    }
                    let displayedError = overflow != nil
                        ? self.contextFallbackMessage(for: self.contextOverflowStrategy)
                        : error.localizedDescription
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                            // Commit the full partial continuation (the loop only checkpointed
                            // periodically) before appending the error.
                            self.streamMsgs[outIdx].text = baseVisibleAssistantText + visibleAssistantText(from: continuation) + "\n⚠️ " + displayedError
                            self.streamMsgs[outIdx].postToolWaiting = false
                        }
                    }
                } else {
                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.clearPromptProcessing(for: outIdx)
                        }
                    }
                }
            }

            if nextToolJSON == nil {
                let combinedText = baseAssistantText + continuation
                if remainingToolTurns > 0,
                   let result = await interceptEmbeddedToolCallIfPresent(
                    in: combinedText,
                    messageIndex: outIdx,
                    chatVM: self
                   ), let handled = result.token {
                    let nextJSON = handled
                        .replacingOccurrences(of: "TOOL_RESULT:", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    nextToolJSON = nextJSON
                    let updatedText = result.cleanedText
                    pendingAssistantText = updatedText
                    let appendedPortion: String = {
                        if updatedText.count >= baseAssistantText.count {
                            let startIndex = updatedText.index(updatedText.startIndex, offsetBy: baseAssistantText.count)
                            return String(updatedText[startIndex...])
                        }
                        return updatedText
                    }()
                    continuation = appendedPortion

                    await MainActor.run {
                        if self.streamMsgs.indices.contains(outIdx) {
                            self.streamingStore.update(visibleAssistantText(from: updatedText))
                            self.streamMsgs[outIdx].text = visibleAssistantText(from: updatedText)
                            if let toolName = self.streamMsgs[outIdx].toolCalls?.last?.toolName,
                               toolName == "noema.web.retrieve" {
                                self.streamMsgs[outIdx].usedWebSearch = true
                            }
                        }
                    }
                    await self.handleRollingThoughts(raw: updatedText, messageIndex: outIdx)
                }
                if nextToolJSON == nil {
                    await pruneDanglingPlaceholderToolCalls(
                        messageIndex: outIdx,
                        chatVM: self
                    )
                }
            }

            if self.loadedFormat == .et && continuation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nextToolJSON == nil {
                if prefillRetryAttempts < maxPrefillRetries {
                    let attempt = prefillRetryAttempts
                    prefillRetryAttempts += 1
                    let backoff = UInt64(150_000_000 * Int(pow(2.0, Double(attempt))))
                    await logger.log("[ChatVM] Empty continuation. Retrying in \(backoff / 1_000_000)ms (attempt \(attempt + 1)/\(maxPrefillRetries)).")
                    try? await Task.sleep(nanoseconds: backoff)
                    continue continuationLoop
                }
            }

            let continuationOutcome: ToolContinuationOutcome = {
                if let json = nextToolJSON, remainingToolTurns > 0 {
                    return .restartWithTool(resultJSON: json)
                }
                return .finishWithVisibleText(
                    resolvedFinalContinuationText ?? (baseAssistantText + continuation)
                )
            }()

            switch continuationOutcome {
            case .streamMore:
                continue continuationLoop
            case .restartWithTool(let json):
                remainingToolTurns -= 1
                let toolMsg = ChatVM.Msg(role: "tool", text: json, timestamp: Date())
                localHistory.append(toolMsg)
                continue continuationLoop
            case .finishWithVisibleText(_):
                await MainActor.run {
                    if self.streamMsgs.indices.contains(outIdx) {
                        // Final text was already committed (success: end of stream `do`;
                        // error: in the catch). Just stop rendering the bubble from the store.
                        self.streamingStore.finish()
                        self.clearPromptProcessing(for: outIdx)
                        self.streamMsgs[outIdx].postToolWaiting = false
                    }
                }
                break continuationLoop
            }
        }

        let continuationOverhead = (self.injectionMethod == .full && self.currentInjectedTokenOverhead > 0) ? self.currentInjectedTokenOverhead : 0
        let finalPerf = await self.finalizePerf(messageID: messageID, injectionOverhead: continuationOverhead)
        await MainActor.run {
            if self.streamMsgs.indices.contains(outIdx) {
                self.streamMsgs[outIdx].streaming = false
                self.clearPromptProcessing(for: outIdx)
                self.streamMsgs[outIdx].postToolWaiting = false
                if let perf = finalPerf {
                    self.streamMsgs[outIdx].perf = perf
                }
#if os(iOS)
                if self.strictFinalAnswerText(for: self.streamMsgs[outIdx]) != nil {
                    Haptics.successLight()
                }
#endif
                ReviewPrompter.shared.safeMaybePromptIfEligible(chatVM: self)
                AccessibilityAnnouncer.announceLocalized("Response generated.")
            }
        }
        self.markRollingThoughtsInterrupted(forMessageAt: outIdx)
        await MainActor.run { self.currentContinuationTask = nil }
    }

    private func parse(_ text: String, toolCalls: [ToolCall]? = nil) -> [Piece] {
        // First parse code blocks
        let codeBlocks = Self.parseCodeBlocks(text)
        
        // Then parse think tags within each text piece
        var finalPieces: [Piece] = []
        var toolCallIndex = 0 // Track which tool call we're currently processing
        
        for piece in codeBlocks {
            switch piece {
            case .code(let code, let lang):
                // Detect tool-call JSON/XML inside fenced code blocks and surface a tool placeholder instead
                var insertedToolFromCodeBlock = false
                let codeSub = code[...]
                var tmp = codeSub
                // 1) XML-style <tool_call> blocks inside code fences
                while let callTag = tmp.range(of: "<tool_call>") {
                    tmp = tmp[callTag.upperBound...]
                    if let end = tmp.range(of: "</tool_call>") {
                        tmp = tmp[end.upperBound...]
                    } else {
                        tmp = tmp[tmp.endIndex...]
                    }
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 2) TOOL_CALL:/TOOL_RESULT markers inside code fences
                tmp = codeSub
                while let callRange = tmp.range(of: "TOOL_CALL:") {
                    tmp = tmp[callRange.upperBound...]
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 3) Bare JSON tool-call object inside code fences
                tmp = codeSub
                var searchStart = tmp.startIndex
                scanJSONInCode: while let braceStart = tmp[searchStart...].firstIndex(of: "{") {
                    if let braceEnd = findMatchingBrace(in: tmp, startingFrom: braceStart) {
                        let candidate = tmp[braceStart...braceEnd]
                        if (candidate.contains("\"tool_name\"") || candidate.contains("\"name\"") || candidate.contains("\"tool\"")) &&
                           (candidate.contains("\"arguments\"") || candidate.contains("\"args\"")) {
                            finalPieces.append(.tool(toolCallIndex))
                            if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                            insertedToolFromCodeBlock = true
                            // Continue after this JSON object in case of multiple
                            searchStart = tmp.index(after: braceEnd)
                            continue scanJSONInCode
                        }
                        searchStart = tmp.index(after: braceEnd)
                        continue scanJSONInCode
                    } else {
                        break scanJSONInCode
                    }
                }
                if !insertedToolFromCodeBlock {
                    finalPieces.append(.code(code, language: lang))
                }
            case .text(let t):
                // Parse think tags in text
                var rest = t[...]
                while let anchorRange = rest.range(of: noemaToolAnchorToken) {
                    if anchorRange.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<anchorRange.lowerBound])))
                    }
                    rest = rest[anchorRange.upperBound...]
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect inline tool call start(s) and replace with tool box, preserving following text
                while let callTag = rest.range(of: "<tool_call>") {
                    if callTag.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<callTag.lowerBound])))
                    }
                    // Skip over the tool call JSON content
                    rest = rest[callTag.upperBound...]
                    if let end = rest.range(of: "</tool_call>") {
                        rest = rest[end.upperBound...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect TOOL_CALL: inline markers repeatedly and hide JSON until the next tool response marker if present
                while let callRange = rest.range(of: "TOOL_CALL:") {
                    if callRange.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<callRange.lowerBound])))
                    }
                    var after = rest[callRange.upperBound...]
                    if let nextResp = (after.range(of: "<tool_response>") ?? after.range(of: "TOOL_RESULT:")) {
                        rest = after[nextResp.lowerBound...]
                    } else if let nl = after.firstIndex(of: "\n") {
                        rest = after[nl...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect inline tool result JSON markers repeatedly and render tool box instead of raw JSON
                toolLoop: while let toolRange = rest.range(of: "<tool_response>") ?? rest.range(of: "TOOL_RESULT:") {
                    // Emit text before the tool block
                    if toolRange.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<toolRange.lowerBound])))
                    }

                    let markerSlice = rest[toolRange]
                    var remainder = rest[toolRange.upperBound...]
                    var consumedPayload = false

                    if markerSlice.hasPrefix("<tool_response>") {
                        if let end = remainder.range(of: "</tool_response>") {
                            remainder = remainder[end.upperBound...]
                            consumedPayload = true
                        }
                    } else {
                        // Skip TOOL_RESULT JSON payloads. These can be objects or arrays.
                        var idx = remainder.startIndex
                        while idx < remainder.endIndex && remainder[idx].isWhitespace {
                            idx = remainder.index(after: idx)
                        }
                        if idx < remainder.endIndex {
                            if remainder[idx] == "[" {
                                if let close = findMatchingBracket(in: remainder, startingFrom: idx) {
                                    remainder = remainder[remainder.index(after: close)...]
                                    consumedPayload = true
                                }
                            } else if remainder[idx] == "{" {
                                if let close = findMatchingBrace(in: remainder, startingFrom: idx) {
                                    remainder = remainder[remainder.index(after: close)...]
                                    consumedPayload = true
                                }
                            } else {
                                // Unknown payload: drop through to the next newline to avoid leaking JSON.
                                if let newline = remainder[idx...].firstIndex(of: "\n") {
                                    remainder = remainder[newline...]
                                } else {
                                    remainder = remainder[remainder.endIndex...]
                                }
                                consumedPayload = true
                            }
                        } else {
                            remainder = remainder[idx...]
                            consumedPayload = true
                        }
                    }

                    // Tool response doesn't increment the index since it's for the same tool call
                    finalPieces.append(.tool(toolCallIndex))
                    rest = remainder
                    if !consumedPayload { break toolLoop }
                }
                // Parse all think blocks that remain
                while let s = rest.range(of: "<think>") {
                    if s.lowerBound > rest.startIndex {
                        finalPieces.append(.text(String(rest[..<s.lowerBound])))
                    }
                    rest = rest[s.upperBound...]
                    if let e = rest.range(of: "</think>") {
                        finalPieces.append(.think(String(rest[..<e.lowerBound]), done: true))
                        rest = rest[e.upperBound...]
                    } else {
                        finalPieces.append(.think(String(rest), done: false))
                        rest = rest[rest.endIndex...]
                    }
                }
                if !rest.isEmpty { finalPieces.append(.text(String(rest))) }
            case .think:
                // This shouldn't happen from parseCodeBlocks
                break
            case .tool(_):
                // Tool blocks are handled at render time; ignore here
                break
            }
        }
        
        return finalPieces
    }

    // Helper to find matching closing brace for a JSON object within a substring,
    // honoring string literals and escape sequences.
    private func findMatchingBrace(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
        guard text[startIndex] == "{" else { return nil }
        var braceCount = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" {
                inString.toggle()
                idx = text.index(after: idx)
                continue
            }
            if !inString {
                if char == "{" {
                    braceCount += 1
                } else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 {
                        return idx
                    }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // Helper to find matching closing bracket for a JSON array, honoring strings and escapes
    private func findMatchingBracket(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
        guard text[startIndex] == "[" else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "[" { depth += 1 }
                else if char == "]" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }

    // Inserts retrieval context inside the current template's user section so BOS/control tokens remain valid.
    // If the template isn't recognized, it falls back to prefixing a "Context:" block.
    nonisolated private static func injectContextIntoPrompt(
        original: String,
        context: String,
        kind: ModelKind,
        templateKind: ModelKind?
    ) -> String {
        let note = """
        Use the following information to answer the question. If passages are prefixed with bracketed numbers like [1], [2], cite those numbers. Otherwise cite the source names shown in the context. In <think>...</think>, reason about how each cited passage answers the question before writing the final response.
        """
        let block = note + context + "\n\n"
        let s = original
        switch templateKind ?? kind {
        case .llama3:
            // <|start_header_id|>user<|end_header_id|> ... <|eot_id|>
            let userOpen = "<|start_header_id|>user<|end_header_id|>\n"
            let eot = "<|eot_id|>"
            // Multi-turn prompts may contain many user blocks; inject into the most recent one.
            if let openRange = s.range(of: userOpen, options: .backwards) {
                if let closeRange = s.range(of: eot, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: block, at: closeRange.lowerBound)
                    return out
                }
            }
        case .gemma, .qwen, .smol, .lfm:
            // <|im_start|>user\n ... <|im_end|>
            let userOpen = "<|im_start|>user\n"
            let userClose = "<|im_end|>"
            if let openRange = s.range(of: userOpen, options: .backwards) {
                if let closeRange = s.range(of: userClose, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: block, at: closeRange.lowerBound)
                    return out
                }
            }
        case .mistral:
            // [INST] ... [/INST]
            let open = "[INST]"
            let close = "[/INST]"
            if let openRange = s.range(of: open, options: .backwards) {
                if let closeRange = s.range(of: close, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: "\n" + block, at: closeRange.lowerBound)
                    return out
                }
            }
        case .phi:
            // <|user|> ... <|assistant|>
            let uOpen = "<|user|>"
            let aOpen = "<|assistant|>"
            if let openRange = s.range(of: uOpen, options: .backwards) {
                if let closeRange = s.range(of: aOpen, range: openRange.upperBound..<s.endIndex) {
                    var out = s
                    out.insert(contentsOf: "\n" + block, at: closeRange.lowerBound)
                    return out
                }
            }
        default:
            break
        }
        return block + s
    }

    private func injectContextIntoPrompt(original: String, context: String, kind: ModelKind) -> String {
        Self.injectContextIntoPrompt(
            original: original,
            context: context,
            kind: kind,
            templateKind: templateKind()
        )
    }

    private var usesTemplateDrivenLoopbackMessages: Bool {
        guard loadedFormat == .gguf, let url = loadedURL else { return false }
        return TemplateDrivenModelSupport.usesTemplateDrivenMessages(modelURL: url)
    }

    /// Formats whose client applies the model's own chat template to structured
    /// messages, so ChatVM must send history as messages rather than a
    /// pre-templated prompt string (which would be templated a second time).
    private var usesStructuredChatMessages: Bool {
        if loadedFormat == .mlx { return true }
        // CoreAILLMClient re-templates `.plain` input as a single user turn, so a
        // pre-templated prompt string would be wrapped a second time. Sending
        // structured messages lets the client apply its template exactly once and
        // keeps tool calls + results paired in replayed history.
        if loadedFormat == .coreai { return true }
        return usesTemplateDrivenLoopbackMessages
    }

    private func injectContextIntoMessages(_ messages: [ChatMessage], context: String) -> [ChatMessage] {
        let note = """
        Use the following information to answer the question. If passages are prefixed with bracketed numbers like [1], [2], cite those numbers. Otherwise cite the source names shown in the context. In <think>...</think>, reason about how each cited passage answers the question before writing the final response.
        """
        let block = note + context
        var result = messages
        if let userIndex = result.lastIndex(where: { $0.role.lowercased() == "user" }) {
            let merged = result[userIndex].content + "\n\n" + block
            result[userIndex] = ChatMessage(
                role: result[userIndex].role,
                content: merged,
                toolCalls: result[userIndex].toolCalls,
                toolCallId: result[userIndex].toolCallId
            )
            return result
        }
        result.append(ChatMessage(role: "user", content: block))
        return result
    }

    private func normalizedLoopbackRole(_ role: String) -> String {
        let lowered = role.lowercased()
        if lowered == "🧑‍💻".lowercased() { return "user" }
        if lowered == "🤖".lowercased() { return "assistant" }
        return lowered
    }

    private func sanitizedLoopbackContent(_ text: String, role: String) -> String {
        guard role == "assistant" else { return text }
        return text.replacingOccurrences(of: noemaToolAnchorToken, with: "")
    }

    private func resolvedLoopbackToolCallID(for call: Msg.ToolCall) -> String {
        if let externalToolCallID = call.externalToolCallID,
           !externalToolCallID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return externalToolCallID
        }
        return call.id.uuidString
    }

    private func serializedLoopbackToolCalls(from calls: [Msg.ToolCall]?) -> [APILoopbackToolCall]? {
        guard let calls, !calls.isEmpty else { return nil }
        return calls.map { call in
            let requestData = (try? JSONEncoder().encode(call.requestParams)) ?? Data("{}".utf8)
            let requestJSON = String(data: requestData, encoding: .utf8) ?? "{}"
            return APILoopbackToolCall(
                id: resolvedLoopbackToolCallID(for: call),
                name: call.toolName,
                arguments: requestJSON
            )
        }
    }

    /// Re-materializes the `tool` role messages that carry tool results so a tool
    /// call *and* its result are replayed into the model context on later turns.
    ///
    /// The saved transcript keeps tool results only inside `Msg.toolCalls[].result`
    /// (the visible assistant text is scrubbed of all tool markers by
    /// `visibleAssistantText`). Without this step, history rebuilt for a new turn
    /// would serialize the assistant's `tool_calls` (the arguments) but never emit
    /// the matching `tool` result messages, so the model would only ever see its own
    /// final answers and "forget" what the tools returned. Inserting a `tool` message
    /// per call lets the existing `pendingToolCallIDs` pairing in `loopbackChatMessages`
    /// attach the results, and also preserves the `tool_calls`⇄`tool` invariant the
    /// chat-completions format expects.
    private func historyWithReconstructedToolMessages(_ history: [Msg]) -> [Msg] {
        var result: [Msg] = []
        result.reserveCapacity(history.count)

        for index in history.indices {
            let message = history[index]
            result.append(message)

            guard normalizedLoopbackRole(message.role) == "assistant",
                  let calls = message.toolCalls,
                  !calls.isEmpty else { continue }

            // In-turn continuation already appends an explicit `tool` message right
            // after the assistant; don't duplicate it. This also keeps the function
            // idempotent if applied to an already-reconstructed history.
            let nextIsToolMessage: Bool = {
                let nextIndex = index + 1
                guard history.indices.contains(nextIndex) else { return false }
                return normalizedLoopbackRole(history[nextIndex].role) == "tool"
            }()
            if nextIsToolMessage { continue }

            for call in calls {
                let payload = call.result
                    ?? call.error.map { "Error: \($0)" }
                    ?? "(no tool result was recorded)"
                result.append(Msg(role: "tool", text: payload, timestamp: call.timestamp))
            }
        }

        return result
    }

    func loopbackChatMessages(from history: [Msg], retrievedContext: String? = nil) -> [ChatMessage]? {
        guard usesStructuredChatMessages else { return nil }

        let toolAwareHistory = historyWithReconstructedToolMessages(history)
        let sanitizedHistory = sanitizedHistoryForTemplateDrivenLoopback(toolAwareHistory)
        let rendered = prepareForGeneration(messages: sanitizedHistory, system: systemPromptText)
        guard case .messages(let renderedMessages) = rendered else { return nil }

        let sourceMessages = sanitizedHistory.filter { normalizedLoopbackRole($0.role) != "system" }
        var sourceIndex = 0
        var pendingToolCallIDs: [String] = []
        var chatMessages: [ChatMessage] = []
        chatMessages.reserveCapacity(renderedMessages.count)

        for renderedMessage in renderedMessages {
            let renderedRole = normalizedLoopbackRole(renderedMessage.role)
            if renderedRole == "system" {
                chatMessages.append(
                    ChatMessage(
                        role: renderedMessage.role,
                        content: renderedMessage.content
                    )
                )
                continue
            }

            guard sourceIndex < sourceMessages.count else {
                chatMessages.append(
                    ChatMessage(
                        role: renderedMessage.role,
                        content: sanitizedLoopbackContent(renderedMessage.content, role: renderedRole)
                    )
                )
                continue
            }

            let sourceMessage = sourceMessages[sourceIndex]
            sourceIndex += 1
            let sourceRole = normalizedLoopbackRole(sourceMessage.role)
            if sourceRole != renderedRole {
                Task {
                    await logger.log("[Loopback] role mismatch while preserving tool metadata source=\(sourceRole) rendered=\(renderedRole)")
                }
            }

            let toolCalls = sourceRole == "assistant"
                ? serializedLoopbackToolCalls(from: sourceMessage.toolCalls)
                : nil
            if sourceRole == "assistant", let sourceToolCalls = sourceMessage.toolCalls {
                pendingToolCallIDs.append(contentsOf: sourceToolCalls.map(resolvedLoopbackToolCallID))
            }

            let toolCallId: String? = {
                guard sourceRole == "tool", !pendingToolCallIDs.isEmpty else { return nil }
                return pendingToolCallIDs.removeFirst()
            }()

            chatMessages.append(
                ChatMessage(
                    role: renderedMessage.role,
                    content: sanitizedLoopbackContent(renderedMessage.content, role: renderedRole),
                    toolCalls: toolCalls,
                    toolCallId: toolCallId
                )
            )
        }

        if let retrievedContext,
           !retrievedContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chatMessages = injectContextIntoMessages(chatMessages, context: retrievedContext)
        }

        return chatMessages
    }

    func sanitizedHistoryForTemplateDrivenLoopback(_ history: [Msg]) -> [Msg] {
        guard let last = history.last else { return history }

        let normalizedRole = last.role.lowercased()
        let isAssistantPlaceholder = (normalizedRole == "assistant" || normalizedRole == "🤖")
            && last.streaming
            && last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isAssistantPlaceholder else { return history }

        Task {
            await logger.log("[Loopback] stripped trailing assistant placeholder for template-driven request")
        }

        var sanitized = history
        sanitized.removeLast()
        return sanitized
    }

    func structuredLoopbackInput(for history: [Msg], retrievedContext: String? = nil) -> LLMInput? {
        guard let chatMessages = loopbackChatMessages(from: history, retrievedContext: retrievedContext) else {
            return nil
        }
        return LLMInput(.messages(chatMessages))
    }

    func structuredLoopbackMultimodalInput(
        for history: [Msg],
        imagePaths: [String],
        retrievedContext: String? = nil
    ) -> LLMInput? {
        guard let chatMessages = loopbackChatMessages(from: history, retrievedContext: retrievedContext) else {
            return nil
        }
        return LLMInput.multimodal(messages: chatMessages, imagePaths: imagePaths)
    }
}

// Utility helpers used by `ChatVM`.
extension ChatVM {
    // Inserts image placeholder tokens into the current template's latest user section so BOS/control tokens remain valid.
    // If the template isn't recognized, it falls back to prefixing simple placeholders at the beginning.
    private func injectImagesIntoPrompt(original: String, imageCount: Int, kind: ModelKind) -> String {
        guard imageCount > 0 else { return original }
        let s = original
        let tmpl = templateKind() ?? kind
        func placeholders(chatml: Bool) -> String {
            let token = chatml ? "<|image|>\n" : "<image>\n"
            return String(repeating: token, count: max(1, imageCount))
        }
        switch tmpl {
        case .llama3:
            // <|start_header_id|>user<|end_header_id|> ... <|eot_id|>
            let userOpen = "<|start_header_id|>user<|end_header_id|>\n"
            let eot = "<|eot_id|>"
            if let open = s.range(of: userOpen), let close = s.range(of: eot, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        case .gemma, .qwen, .smol, .lfm:
            // ChatML-style or Gemma turn: <|im_start|>user\n ... <|im_end|>
            let userOpen = "<|im_start|>user\n"
            let userClose = "<|im_end|>"
            if let open = s.range(of: userOpen, options: .backwards), let close = s.range(of: userClose, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: placeholders(chatml: true), at: close.lowerBound)
                return out
            }
            // Gemma-turn variant: <start_of_turn>user\n ... <end_of_turn>
            let gOpen = "<start_of_turn>user\n"
            let gClose = "<end_of_turn>"
            if let open = s.range(of: gOpen, options: .backwards), let close = s.range(of: gClose, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        case .mistral:
            // [INST] ... [/INST]
            let openTag = "[INST]"
            let closeTag = "[/INST]"
            if let open = s.range(of: openTag, options: .backwards), let close = s.range(of: closeTag, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: "\n" + placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        case .phi:
            // <|user|> ... <|assistant|>
            let uOpen = "<|user|>"
            let aOpen = "<|assistant|>"
            if let open = s.range(of: uOpen, options: .backwards), let close = s.range(of: aOpen, range: open.upperBound..<s.endIndex) {
                var out = s
                out.insert(contentsOf: "\n" + placeholders(chatml: false), at: close.lowerBound)
                return out
            }
        default:
            break
        }
        // Fallback: prefix placeholders
        return placeholders(chatml: false) + s
    }
    static func metalQuant(from url: URL) -> String? {
        let name = url.lastPathComponent
        if let r = name.range(of: #"q[0-9][A-Za-z0-9_]*"#, options: .regularExpression) {
            return String(name[r])
        }
        return nil
    }
    func templateKind() -> ModelKind? {
        guard let t = promptTemplate?.lowercased() else { return nil }
        if t.contains("<|begin_of_text|>") { return .llama3 }
        if t.contains("[inst]") { return .mistral }
        if t.contains("<|startoftext|>") { return .lfm }
        if t.contains("<|im_start|>") {
            if currentKind == .gemma { return .gemma }
            if currentKind == .lfm { return .lfm }
            // Smol and Qwen both serialize with ChatML tokens by default
            if currentKind == .smol { return .smol }
            if currentKind == .internlm { return .internlm }
            if currentKind == .yi { return .yi }
            return .qwen
        }
        // DeepSeek may use distinct BOS and role tags; detect via placeholders if present
        if (t.contains("<|user|>") && t.contains("<|assistant|>")) ||
           (t.contains("<｜user｜>") && t.contains("<｜assistant｜>")) ||
            t.contains("<｜begin▁of▁sentence｜>") {
            return .deepseek
        }
        if t.contains("<|system|>") { return .phi }
        return nil
    }

    /// Builds a prompt for the underlying model from a message history.
    /// Example: Gemma single turn history `["Hi"]` → prompt ends with
    /// "<|im_start|>assistant\n" and user sees no control tokens.
    func buildPrompt(kind: ModelKind, history: [ChatVM.Msg]) -> (String, [String], Int?) {
        // Use the unified formatter to prepare messages vs plain prompt
        let cfMessages: [ChatFormatter.Message] = history.map { m in
            let roleLower = m.role.lowercased()
            let normalizedRole: String
            if roleLower == "🧑‍💻".lowercased() { normalizedRole = "user" }
            else if roleLower == "🤖".lowercased() { normalizedRole = "assistant" }
            else { normalizedRole = roleLower }
            return ChatFormatter.Message(role: normalizedRole, content: m.text)
        }
        let systemPrompt = systemPromptText
        Task {
            await logger.log(Self.systemPromptMetadataSummary(systemPrompt))
        }
        // Replay tool results from history so completion-style prompts keep the
        // tool call + result in context (mirrors the structured loopback path).
        let rendered = prepareForGeneration(
            messages: historyWithReconstructedToolMessages(history),
            system: systemPrompt
        )
        switch rendered {
        case .messages(let arr):
            // Convert back to ChatVM.Msg for our renderer
            let msgs: [ChatVM.Msg] = arr.map { ChatVM.Msg(role: $0.role, text: $0.content) }
            return PromptBuilder.build(template: promptTemplate, family: kind, messages: msgs)
        case .plain(let s):
            // Let caller pick default stops; provide generous token budget
            return (s, [], nil)
        }
    }

    /// New unified chat preparation that returns either a messages array (for chat-aware backends)
    /// or a single plain prompt string for completion-style backends.
    func prepareForGeneration(messages: [ChatVM.Msg], system: String) -> ChatFormatter.RenderedPrompt {
        let modelId: String = loadedURL?.lastPathComponent ?? "unknown"
        var cf = ChatFormatter.shared
        let family = currentKind

        // Convert to ChatFormatter.Message list (preserve order and roles)
        let msgs: [ChatFormatter.Message] = messages.map { m in
            ChatFormatter.Message(role: m.role.lowercased() == "🧑‍💻".lowercased() ? "user" : (m.role.lowercased() == "🤖".lowercased() ? "assistant" : m.role.lowercased()), content: m.text)
        }

        let rendered = cf.prepareForGeneration(
            modelId: modelId,
            template: promptTemplate,
            family: family,
            messages: msgs,
            system: system
        )

        // Runtime validation: ensure system content appears before first user span
        func validate(_ prompt: String, sys: String) -> Bool {
            let s = sys.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return true }
            let lower = prompt.lowercased()
            let sysIdx = lower.range(of: s.lowercased())?.lowerBound
            let userIdx = lower.range(of: "user:")?.lowerBound
            if let sysIdx, let userIdx { return sysIdx < userIdx }
            return sysIdx != nil
        }

        switch rendered {
        case .messages(let arr):
            // Cheap join to validate order without changing the authoritative structure
            let flat = arr.map { "\($0.role.capitalized): \($0.content)" }.joined(separator: "\n")
            if !validate(flat, sys: system) {
                Task { await logger.log("[Warn][Prompt] System text missing after render; model=\(modelId) hash=\(system.hashValue)") }
                // Conservative fallback: re-render via inline-first-user path
                var cf2 = ChatFormatter.shared
                let re = cf2.prepareForGeneration(
                    modelId: modelId,
                    template: promptTemplate,
                    family: family,
                    messages: arr.map { ChatFormatter.Message(role: $0.role, content: $0.content) },
                    system: system,
                    forceInlineWhenTemplatePresent: true
                )
                return re
            }
            return .messages(arr)
        case .plain(let s):
            if !validate(s, sys: system) {
                Task { await logger.log("[Warn][Prompt] System text missing in plain render; model=\(modelId) hash=\(system.hashValue)") }
                // For plain, prepend explicitly
                let fixed = "System: " + system + "\n\n" + s
                return .plain(fixed)
            }
            return .plain(s)
        }
    }

    /// Removes any model specific control tokens from the raw output.
    func cleanOutput(_ raw: String, kind: ModelKind) -> String {
        var t = raw
        let tmplKind = templateKind() ?? kind
        switch tmplKind {
        case .gemma, .qwen, .smol, .lfm:
            if tmplKind == .gemma && gemmaAutoTemplated {
                t = t.replacingOccurrences(of: "<start_of_turn>model", with: "")
                t = t.replacingOccurrences(of: "<start_of_turn>user", with: "")
                t = t.replacingOccurrences(of: "<start_of_turn>system", with: "")
                t = t.replacingOccurrences(of: "<end_of_turn>", with: "")
                t = t.replacingOccurrences(of: "<bos>", with: "")
                t = t.replacingOccurrences(of: "<eos>", with: "")
            } else {
                t = t.replacingOccurrences(of: "<|im_start|>assistant", with: "")
                t = t.replacingOccurrences(of: "<|im_start|>user", with: "")
                t = t.replacingOccurrences(of: "<|im_end|>", with: "")
                t = t.replacingOccurrences(of: "<\\|im_.*?\\|>\n?", with: "", options: .regularExpression)
            }
        case .internlm:
            // ChatML-like tokens
            t = t.replacingOccurrences(of: "<|im_start|>assistant", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>user", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>system", with: "")
            t = t.replacingOccurrences(of: "<|im_end|>", with: "")
        case .yi:
            t = t.replacingOccurrences(of: "<|startoftext|>", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>assistant", with: "")
            t = t.replacingOccurrences(of: "<|im_start|>user", with: "")
            t = t.replacingOccurrences(of: "<|im_end|>", with: "")
        case .deepseek:
            // Remove DeepSeek control tokens (canonical fullwidth; also strip legacy/ascii variants)
            t = t.replacingOccurrences(of: "<｜begin▁of▁sentence｜>", with: "")
            t = t.replacingOccurrences(of: "<｜User｜>", with: "")
            t = t.replacingOccurrences(of: "<｜Assistant｜>", with: "")
            // Legacy/weird variants (left in for robustness)
            t = t.replacingOccurrences(of: "<攼 begin▁of▁sentence放>", with: "")
            t = t.replacingOccurrences(of: "<|User|>", with: "")
            t = t.replacingOccurrences(of: "<|Assistant|>", with: "")
        case .llama3:
            t = t.replacingOccurrences(of: "<|begin_of_text|>", with: "")
            t = t.replacingOccurrences(of: "<|start_header_id|>", with: "")
            t = t.replacingOccurrences(of: "<|end_header_id|>", with: "")
            t = t.replacingOccurrences(of: "<|eot_id|>", with: "")
            t = t.replacingOccurrences(of: "<\\|.*?\\|>", with: "", options: .regularExpression)
        case .mistral:
            t = t.replacingOccurrences(of: "<s>", with: "")
            t = t.replacingOccurrences(of: "</s>", with: "")
            t = t.replacingOccurrences(of: "[INST]", with: "")
            t = t.replacingOccurrences(of: "[/INST]", with: "")
        case .phi:
            t = t.replacingOccurrences(of: "<|system|>", with: "")
            t = t.replacingOccurrences(of: "<|user|>", with: "")
            t = t.replacingOccurrences(of: "<|assistant|>", with: "")
            t = t.replacingOccurrences(of: "<|end|>", with: "")
        default:
            t = t.replacingOccurrences(of: "System:", with: "")
            t = t.replacingOccurrences(of: "User:", with: "")
            if t.hasPrefix("Assistant:") {
                t = String(t.dropFirst("Assistant:".count))
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits text into `.text` and `.code` pieces based on fenced triple backticks.
    /// Recognizes optional language hints immediately following the opening ```.
    fileprivate static func parseCodeBlocks(_ text: String) -> [Piece] {
        var pieces: [Piece] = []
        var currentText = ""
        let lines = text.components(separatedBy: .newlines)
        var i = 0

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                if !currentText.isEmpty {
                    pieces.append(.text(currentText.trimmingCharacters(in: .newlines)))
                    currentText = ""
                }

                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }

                if !codeLines.isEmpty {
                    let code = codeLines.joined(separator: "\n")
                    pieces.append(.code(code, language: lang.isEmpty ? nil : lang))
                }
            } else {
                currentText += (currentText.isEmpty ? "" : "\n") + line
            }
            i += 1
        }

        if !currentText.isEmpty {
            pieces.append(.text(currentText.trimmingCharacters(in: .newlines)))
        }

        return pieces
    }

    // Build the model-facing prompt without changing the visible chat bubble text.
    nonisolated static func promptText(userText: String, mediaAttachments: [ChatMediaAttachment]) -> String {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let includeTimestamps = TranscriptionSettings.includesTimestampsInPrompt
        let transcriptBlocks = mediaAttachments.compactMap { $0.promptBlock(includeTimestamps: includeTimestamps) }
        guard !transcriptBlocks.isEmpty else { return trimmed }

        var parts: [String] = []
        if !trimmed.isEmpty {
            parts.append(trimmed)
        } else {
            parts.append(String(localized: "Use the attached transcript to answer."))
        }
        parts.append(transcriptBlocks.joined(separator: "\n\n"))
        return parts.joined(separator: "\n\n")
    }

    nonisolated static func modelFacingHistory(visibleHistory: [Msg], modelInput: String) -> [Msg] {
        var history = visibleHistory
        if let userIndex = history.indices.dropLast().last(where: { history[$0].role == "🧑‍💻" }) {
            history[userIndex].text = modelInput
        }
        return history
    }

    @MainActor
    func savePendingMediaFile(from sourceURL: URL, originalFilename overrideFilename: String? = nil) async {
        guard let kind = TranscriptionMediaSupport.kind(for: sourceURL) else {
            audioRecordingError = String(localized: "This media format is not supported for transcription.")
            return
        }

        let fm = FileManager.default
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? (kind == .audio ? "m4a" : "mov") : sourceURL.pathExtension
        let filename = UUID().uuidString + "." + ext
        let destination = Self.attachmentStorageDirectory().appendingPathComponent(filename)

        do {
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            if Self.isPath(sourceURL.path, inside: Self.attachmentStorageDirectory()) {
                if sourceURL.path != destination.path {
                    try fm.copyItem(at: sourceURL, to: destination)
                }
            } else {
                try fm.copyItem(at: sourceURL, to: destination)
            }
            let bytes = (try? fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
            let duration = await mediaDurationSeconds(for: destination)
            let attachment = ChatMediaAttachment(
                kind: kind,
                originalFilename: overrideFilename?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? overrideFilename!
                    : sourceURL.lastPathComponent,
                storedPath: destination.path,
                fileSizeBytes: bytes,
                durationSeconds: duration
            )
            pendingMediaAttachments.append(
                attachment
            )
            Task { await logger.log("[ASR][Attach] kind=\(kind.rawValue) name=\(attachment.originalFilename) path=\(destination.path)") }
            if TranscriptionSettings.autoTranscribesAttachments {
                if TranscriptionSettings.selectedEngineID == .audioLanguageModel,
                   !TranscriptionSettings.hasConfirmedRemoteUpload {
                    audioRecordingError = String(localized: "Confirm remote ASR upload before transcribing this media.")
                } else {
                    beginTranscribingPendingMediaAttachment(id: attachment.id)
                }
            }
        } catch {
            audioRecordingError = error.localizedDescription
            Task { await logger.log("[ASR][Attach] failed=\(error.localizedDescription)") }
        }
    }

    private func mediaDurationSeconds(for url: URL) async -> TimeInterval? {
#if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        return seconds.isFinite && seconds > 0 ? seconds : nil
#else
        return nil
#endif
    }

    @MainActor
    func removePendingMediaAttachment(id: ChatMediaAttachment.ID) {
        mediaTranscriptionTasks[id]?.cancel()
        mediaTranscriptionTasks[id] = nil
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        let attachment = pendingMediaAttachments.remove(at: index)
        let referencedByMessage = sessions.contains { session in
            session.messages.contains { msg in
                msg.mediaAttachments?.contains(where: { $0.id == id }) == true
            }
        }
        guard !referencedByMessage else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: attachment.storedPath))
        if let sidecar = attachment.transcriptSidecarPath {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: sidecar))
        }
    }

    @MainActor
    func beginTranscribingPendingMediaAttachment(id: ChatMediaAttachment.ID) {
        guard mediaTranscriptionTasks[id] == nil else { return }
        let task = Task { [weak self] in
            await self?.transcribePendingMediaAttachment(id: id)
            await MainActor.run {
                self?.mediaTranscriptionTasks[id] = nil
            }
        }
        mediaTranscriptionTasks[id] = task
    }

    @MainActor
    func cancelPendingMediaTranscription(id: ChatMediaAttachment.ID) {
        mediaTranscriptionTasks[id]?.cancel()
        mediaTranscriptionTasks[id] = nil
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        pendingMediaAttachments[index].status = .notStarted
        pendingMediaAttachments[index].partialTranscript = nil
        pendingMediaAttachments[index].errorMessage = nil
    }

    @MainActor
    func transcribePendingMediaAttachment(id: ChatMediaAttachment.ID) async {
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
        var attachment = pendingMediaAttachments[index]
        attachment.status = .transcribing
        attachment.errorMessage = nil
        pendingMediaAttachments[index] = attachment

        let offGrid = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
        let options = TranscriptionSettings.requestOptions(offGrid: offGrid)
        let mediaURL = URL(fileURLWithPath: attachment.storedPath)
        let selectedEngineID = TranscriptionSettings.selectedEngineID
        // Capture the Sendable filename so the @Sendable onEvent closure doesn't
        // capture the non-Sendable `attachment` across isolation.
        let originalFilename = attachment.originalFilename
        Task {
            await logger.log("[ASR][Transcribe] start name=\(attachment.originalFilename) engine=\(selectedEngineID.rawValue) locale=\(options.localeIdentifier) off_grid=\(offGrid) bytes=\(attachment.fileSizeBytes ?? -1) duration=\(attachment.durationSeconds.map { String(format: "%.2f", $0) } ?? "unknown")")
        }

        do {
            let backend: any TranscriptionBackend = try TranscriptionBackendFactory.makeBackend(for: selectedEngineID)
            Task { await logger.log("[ASR][Transcribe] backend.ready requested=\(selectedEngineID.rawValue) actual=\(backend.engineID.rawValue)") }
            let rawArtifact = try await backend.transcribe(
                mediaURL: mediaURL,
                originalFilename: attachment.originalFilename,
                options: options,
                onEvent: { [weak self] event in
                    guard let self else { return }
                    Task { @MainActor in
                        guard let currentIndex = self.pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
                        switch event {
                        case .partial(let text):
                            self.pendingMediaAttachments[currentIndex].partialTranscript = text
                            Task { await logger.log("[ASR][Transcribe] partial name=\(originalFilename) chars=\(text.count)") }
                        case .completed:
                            break
                        }
                    }
                }
            )
            let artifact = rawArtifact.withProvenance(engineID: selectedEngineID, options: options)

            guard let currentIndex = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
            let sidecar = try writeTranscriptSidecar(artifact)
            pendingMediaAttachments[currentIndex].status = .completed
            pendingMediaAttachments[currentIndex].partialTranscript = nil
            pendingMediaAttachments[currentIndex].transcript = artifact
            pendingMediaAttachments[currentIndex].transcriptSidecarPath = sidecar.path
            Haptics.successLight()
            AccessibilityAnnouncer.announceLocalized("Transcription complete")
            Task { await logger.log("[ASR][Transcribe] completed name=\(attachment.originalFilename) chars=\(artifact.transcriptText.count)") }
        } catch {
            if Task.isCancelled { return }
            guard let currentIndex = pendingMediaAttachments.firstIndex(where: { $0.id == id }) else { return }
            pendingMediaAttachments[currentIndex].status = .failed
            pendingMediaAttachments[currentIndex].errorMessage = error.localizedDescription
            Haptics.error()
            AccessibilityAnnouncer.announce(error.localizedDescription)
            Task { await logger.log("[ASR][Transcribe] failed name=\(attachment.originalFilename) engine=\(selectedEngineID.rawValue) error_type=\(String(describing: type(of: error))) error=\(error.localizedDescription)") }
        }
    }

    @MainActor
    func updatePendingMediaTranscript(id: ChatMediaAttachment.ID, title: String, transcriptText: String) {
        guard let index = pendingMediaAttachments.firstIndex(where: { $0.id == id }),
              let artifact = pendingMediaAttachments[index].transcript else { return }
        let updated = artifact.updatingReview(title: title, transcriptText: transcriptText)
        pendingMediaAttachments[index].transcript = updated
        if let sidecarURL = try? writeTranscriptSidecar(updated) {
            pendingMediaAttachments[index].transcriptSidecarPath = sidecarURL.path
        }
    }

    @MainActor
    func updateMessageMediaTranscript(messageID: Msg.ID, attachmentID: ChatMediaAttachment.ID, title: String, transcriptText: String) {
        var messages = msgs
        guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
              var attachments = messages[messageIndex].mediaAttachments,
              let attachmentIndex = attachments.firstIndex(where: { $0.id == attachmentID }),
              let artifact = attachments[attachmentIndex].transcript else { return }
        let updated = artifact.updatingReview(title: title, transcriptText: transcriptText)
        attachments[attachmentIndex].transcript = updated
        if let sidecarURL = try? writeTranscriptSidecar(updated) {
            attachments[attachmentIndex].transcriptSidecarPath = sidecarURL.path
        }
        messages[messageIndex].mediaAttachments = attachments
        msgs = messages
        saveSessions()
    }

    @MainActor
    func saveTranscriptAttachmentAsDataset(_ attachment: ChatMediaAttachment) async -> Result<LocalDataset, Error> {
        guard let artifact = attachment.transcript else {
            return .failure(Self.transcriptSaveError(String(localized: "No transcript was saved.")))
        }
        guard let datasetManager else {
            return .failure(Self.transcriptSaveError(String(localized: "Stored is unavailable.")))
        }
        let dir = Self.attachmentStorageDirectory()
            .appendingPathComponent("TranscriptExports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = attachment.originalFilename
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let textURL = dir.appendingPathComponent((base.isEmpty ? artifact.id.uuidString : base) + ".transcript.txt")
        let body = artifact.exportText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try body.data(using: .utf8)?.write(to: textURL, options: [.atomic])
            if let dataset = await datasetManager.importDocuments(
                from: [textURL],
                suggestedName: String.localizedStringWithFormat(String(localized: "%@ Transcript"), attachment.originalFilename)
            ) {
                let metadataDir = DatasetIndexIO.transcriptMetadataDirectoryURL(for: dataset.url)
                try? FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
                let metadataURL = metadataDir.appendingPathComponent((base.isEmpty ? artifact.id.uuidString : base) + ".transcript.json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(artifact).write(to: metadataURL, options: [.atomic])
                Task { await logger.log("[ASR][Dataset] saved transcript dataset=\(dataset.datasetID) name=\(dataset.name)") }
                return .success(dataset)
            }
            return .failure(Self.transcriptSaveError(String(localized: "No transcript was saved.")))
        } catch {
            Task { await logger.log("[ASR][Dataset] export failed=\(error.localizedDescription)") }
            return .failure(error)
        }
    }

    @MainActor
    func saveTranscriptAttachment(_ attachment: ChatMediaAttachment, toExistingDataset dataset: LocalDataset) async -> Result<LocalDataset, Error> {
        guard let artifact = attachment.transcript else {
            return .failure(Self.transcriptSaveError(String(localized: "No transcript was saved.")))
        }
        let base = Self.safeTranscriptBaseName(attachment.originalFilename, fallback: artifact.id.uuidString)
        let mediaTranscriptDir = dataset.url.appendingPathComponent("Media Transcripts", isDirectory: true)
        let metadataDir = DatasetIndexIO.transcriptMetadataDirectoryURL(for: dataset.url)
        do {
            try FileManager.default.createDirectory(at: mediaTranscriptDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadataDir, withIntermediateDirectories: true)
            let textURL = Self.uniqueTranscriptURL(in: mediaTranscriptDir, base: base, ext: "transcript.txt")
            let metadataURL = Self.uniqueTranscriptURL(in: metadataDir, base: base, ext: "transcript.json")
            try artifact.exportText.trimmingCharacters(in: .whitespacesAndNewlines)
                .data(using: .utf8)?.write(to: textURL, options: [.atomic])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(artifact).write(to: metadataURL, options: [.atomic])
            datasetManager?.reloadFromDisk()
            Task { await logger.log("[ASR][Dataset] saved transcript existing dataset=\(dataset.datasetID) name=\(dataset.name)") }
            return .success(dataset)
        } catch {
            Task { await logger.log("[ASR][Dataset] existing save failed=\(error.localizedDescription)") }
            return .failure(error)
        }
    }

    private static func safeTranscriptBaseName(_ name: String, fallback: String) -> String {
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return base.isEmpty ? fallback : base
    }

    private static func uniqueTranscriptURL(in directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent(base + "." + ext)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(base + "-\(suffix)." + ext)
            suffix += 1
        }
        return candidate
    }

    private static func transcriptSaveError(_ message: String) -> NSError {
        NSError(
            domain: "Noema.TranscriptSave",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    @MainActor
    private func writeTranscriptSidecar(_ artifact: TranscriptArtifact) throws -> URL {
        let sidecarURL = Self.attachmentStorageDirectory()
            .appendingPathComponent(artifact.id.uuidString + ".transcript.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifact).write(to: sidecarURL, options: [.atomic])
        return sidecarURL
    }

#if canImport(AVFoundation)
    @MainActor
    func toggleAudioRecording() async {
        if isRecordingAudio {
            await stopAudioRecording()
        } else {
            await startAudioRecording()
        }
    }

    @MainActor
    private func startAudioRecording() async {
        audioRecordingError = nil
        do {
#if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            let granted: Bool
#if os(iOS)
            if #available(iOS 17.0, *) {
                granted = await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
            } else {
                granted = await withCheckedContinuation { continuation in
                    session.requestRecordPermission { allowed in
                        continuation.resume(returning: allowed)
                    }
                }
            }
#else
            granted = await withCheckedContinuation { continuation in
                session.requestRecordPermission { allowed in
                    continuation.resume(returning: allowed)
                }
            }
#endif
            guard granted else {
                audioRecordingError = String(localized: "Microphone permission is required to record audio.")
                Haptics.error()
                AccessibilityAnnouncer.announceLocalized("Microphone permission is required to record audio.")
                return
            }
            // Activation blocks; keep it off the main thread (the OS warns
            // "AVAudioSession activate/deactivate called on main thread").
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
                try session.setActive(true)
            }.value
#endif
            let url = Self.attachmentStorageDirectory().appendingPathComponent(UUID().uuidString + ".m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            audioRecorder = try AVAudioRecorder(url: url, settings: settings)
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            audioRecordingURL = url
            audioRecordingFriendlyName = Self.friendlyVoiceNoteName()
            audioRecordingStartedAt = Date()
            audioRecordingLevel = 0
            isRecordingAudio = true
            Haptics.successLight()
            AccessibilityAnnouncer.announceLocalized("Recording started")
            startAudioRecordingMeter()
        } catch {
            audioRecordingError = error.localizedDescription
            Haptics.error()
            AccessibilityAnnouncer.announce(error.localizedDescription)
        }
    }

    @MainActor
    private func stopAudioRecording() async {
        let friendlyName = audioRecordingFriendlyName
        audioRecordingMeterTask?.cancel()
        audioRecordingMeterTask = nil
        audioRecorder?.stop()
        audioRecorder = nil
        isRecordingAudio = false
        audioRecordingStartedAt = nil
        audioRecordingLevel = 0
        audioRecordingFriendlyName = nil
#if os(iOS) || os(visionOS)
        Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
#endif
        guard let url = audioRecordingURL else { return }
        audioRecordingURL = nil
        Haptics.successLight()
        AccessibilityAnnouncer.announceLocalized("Recording stopped")
        await savePendingMediaFile(from: url, originalFilename: friendlyName)
    }

    @MainActor
    private func startAudioRecordingMeter() {
        audioRecordingMeterTask?.cancel()
        audioRecordingMeterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.audioRecorder?.updateMeters()
                if let power = self?.audioRecorder?.averagePower(forChannel: 0), power.isFinite {
                    self?.audioRecordingLevel = max(0, min(1, (power + 55) / 55))
                }
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private static func friendlyVoiceNoteName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return String.localizedStringWithFormat(String(localized: "Voice Note %@.m4a"), formatter.string(from: date))
    }
#endif

    // Heuristic for GGUF VLMs when Hub metadata is unavailable (offline or missing tags)
    @MainActor
    func savePendingImage(_ image: UIImage) async {
        guard let normalized = AttachmentImageNormalizer.normalizeAttachmentImage(image) else { return }
        await savePendingNormalizedAttachment(normalized, source: "image")
    }

    @MainActor
    func savePendingImageData(_ data: Data) async {
        guard let normalized = AttachmentImageNormalizer.normalizeAttachmentData(data) else { return }
        await savePendingNormalizedAttachment(normalized, source: "data")
    }

    @MainActor
    func removePendingImage(at index: Int) {
        guard pendingImageURLs.indices.contains(index) else { return }
        let url = pendingImageURLs.remove(at: index)
        pendingThumbnails.removeValue(forKey: url)
        let referencedByMessage = sessions.contains { session in
            session.messages.contains { msg in
                msg.imagePaths?.contains(url.path) == true
            }
        }
        if !referencedByMessage {
            try? FileManager.default.removeItem(at: url)
        }
        Task { await logger.log("[Images][Remove] removed=\(url.lastPathComponent) pending=\(pendingImageURLs.count)") }
    }

    // Accessor used by views to fetch cached thumbnails
    func pendingThumbnail(for url: URL) -> UIImage? {
        pendingThumbnails[url]
    }

    @MainActor
    private func savePendingNormalizedAttachment(_ normalized: AttachmentImageNormalizer.Result, source: String) async {
        let dir = Self.attachmentStorageDirectory()
        let url = dir.appendingPathComponent(UUID().uuidString + ".jpg")
        do {
            try normalized.data.write(to: url, options: [.atomic])
        } catch {
            Task { await logger.log("[Images][Attach] write-failed path=\(url.path) error=\(error.localizedDescription)") }
            return
        }

        let target = CGSize(width: 160, height: 160)
        if let thumb = ImageThumbnailCache.shared.thumbnail(for: url.path, pointSize: target, maxScale: 1) {
            pendingThumbnails[url] = thumb
        }

        pendingImageURLs.append(url)

        let originalWidth = normalized.originalPixelWidth ?? normalized.pixelWidth
        let originalHeight = normalized.originalPixelHeight ?? normalized.pixelHeight
        Task {
            await logger.log(
                "[Images][Attach] saved=\(url.lastPathComponent) source=\(source) original=\(originalWidth)x\(originalHeight) normalized=\(normalized.pixelWidth)x\(normalized.pixelHeight) clamped=\(normalized.wasClamped) suspicious=\(normalized.suspiciouslyLargeSource) path=\(url.path) pending=\(pendingImageURLs.count)"
            )
        }
    }
    
    /// Handle rolling thoughts for <think> tags during streaming
    private func handleRollingThoughts(raw: String, messageIndex: Int) async {
        // Parse think blocks from the raw text
        let thinkBlocks = parseThinkBlocks(from: raw)
        
        await MainActor.run {
            // Update or create rolling thought view models for each think block
            for (index, thinkBlock) in thinkBlocks.enumerated() {
                // Use message UUID for stable keys so view can find the matching view model
                guard messageIndex >= 0 && messageIndex < streamMsgs.count else { continue }
                let msgId = streamMsgs[messageIndex].id.uuidString
                let thinkKey = "message-\(msgId)-think-\(index)"

                // Skip empty think blocks
                guard !thinkBlock.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let viewModel: RollingThoughtViewModel
                if let existing = rollingThoughtViewModels[thinkKey] {
                    viewModel = existing
                } else {
                    viewModel = RollingThoughtViewModel()
                    rollingThoughtViewModels[thinkKey] = viewModel
                }

                // Assign the authoritative think text directly. `raw` already holds the
                // full content parsed from the growing stream buffer, so feeding a delta
                // through a token stream (the old approach) only introduced a race that
                // duplicated text and broke completion. Setting it outright is race-free
                // and keeps fullText exactly equal to thinkBlock.content.
                viewModel.setContent(thinkBlock.content)

                // Mark complete once the closing </think> has arrived. Because fullText
                // now matches the block exactly, this fires reliably (no deferral needed).
                // finish() preserves an expanded box while still flagging completion.
                if thinkBlock.isComplete && viewModel.phase != .complete {
                    viewModel.finish()
                    let storageKey = "RollingThought." + thinkKey
                    viewModel.saveState(forKey: storageKey)
                }
            }
        }
    }
    
    /// Parse think blocks from raw text
    private func parseThinkBlocks(from text: String) -> [(content: String, isComplete: Bool)] {
        var blocks: [(String, Bool)] = []
        var rest = text[...]
        
        while let start = rest.range(of: "<think>") {
            rest = rest[start.upperBound...]
            if let end = rest.range(of: "</think>") {
                let content = String(rest[..<end.lowerBound])
                // Strip any nested or stray think tags inside the content to avoid leaking markers
                let sanitized = content.replacingOccurrences(of: "<think>", with: "").replacingOccurrences(of: "</think>", with: "")
                blocks.append((sanitized, true))
                rest = rest[end.upperBound...]
            } else {
                let content = String(rest)
                let sanitized = content.replacingOccurrences(of: "<think>", with: "").replacingOccurrences(of: "</think>", with: "")
                blocks.append((sanitized, false))
                break
            }
        }
        
        return blocks
    }
    
    /// Recreate rolling thought view models for existing messages
    private func recreateRollingThoughtViewModels() {
        // Build allowed keys for current session and content map
        var allowedKeys: Set<String> = []
        var keyToContent: [String: (content: String, isComplete: Bool)] = [:]
        for msg in msgs {
            guard msg.role == "🤖" || msg.role.lowercased() == "assistant" else { continue }
            let blocks = parseThinkBlocks(from: msg.text)
            for (idx, block) in blocks.enumerated() {
                let content = block.content
                let isComplete = block.isComplete
                guard !content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { continue }
                let key = "message-\(msg.id.uuidString)-think-\(idx)"
                allowedKeys.insert(key)
                keyToContent[key] = (content, isComplete)
            }
        }

        // Compute removals and additions first
        var keysToRemove: [String] = []
        for key in rollingThoughtViewModels.keys where !allowedKeys.contains(key) {
            keysToRemove.append(key)
        }

        var modelsToAdd: [String: RollingThoughtViewModel] = [:]
        for key in allowedKeys where rollingThoughtViewModels[key] == nil {
            let vm = RollingThoughtViewModel()
            if let tuple = keyToContent[key] {
                vm.fullText = tuple.content
                vm.updateRollingLines()
                vm.phase = tuple.isComplete ? .complete : .expanded
            }
            modelsToAdd[key] = vm
        }

        // Apply all mutations in one deferred main-queue pass to avoid nested updates
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for key in keysToRemove {
                self.rollingThoughtViewModels[key]?.cancel()
                self.rollingThoughtViewModels.removeValue(forKey: key)
            }
            for (key, vm) in modelsToAdd {
                self.rollingThoughtViewModels[key] = vm
            }
        }
    }
    
    /// Returns assistant-visible text only when it appears after the latest control
    /// segment (`<think>`/tool markers). If controls are present and no trailing
    /// answer text exists yet, this returns nil.
    func strictFinalAnswerText(for message: Msg) -> String? {
        strictFinalAnswerText(forText: message.text, toolCalls: message.toolCalls)
    }

    /// Same as `strictFinalAnswerText(for:)` but operates on a raw visible-text string.
    /// Used by the streaming loops so the final-answer haptic can be evaluated against the
    /// live text without first writing it into `sessions`.
    func strictFinalAnswerText(forText text: String, toolCalls: [ToolCall]?) -> String? {
        let pieces = parse(text, toolCalls: toolCalls)
        guard !pieces.isEmpty else { return nil }

        let lastControlIndex = pieces.lastIndex { piece in
            switch piece {
            case .think, .tool:
                return true
            default:
                return false
            }
        }

        var trailingText: [String] = []
        for (index, piece) in pieces.enumerated() {
            guard case .text(let text) = piece else { continue }
            if let last = lastControlIndex, index <= last { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                trailingText.append(trimmed)
            }
        }

        let trailingCombined = trailingText.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailingCombined.isEmpty {
            return trailingCombined
        }

        let plainCombined = pieces.compactMap { piece -> String? in
            guard case .text(let text) = piece else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        return plainCombined.isEmpty ? nil : plainCombined
    }

    /// Returns only the assistant-visible answer text, stripping think/tool blocks
    /// and preferring content that appears after the final control segment.
    func finalAnswerText(for message: Msg) -> String? {
        let pieces = parse(message.text, toolCalls: message.toolCalls)
        guard !pieces.isEmpty else { return nil }
        
        let lastControlIndex = pieces.lastIndex { piece in
            switch piece {
            case .think, .tool:
                return true
            default:
                return false
            }
        }
        
        var segments: [String] = []
        for (index, piece) in pieces.enumerated() {
            guard case .text(let text) = piece else { continue }
            if let last = lastControlIndex, index <= last { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
        }
        
        var combined = segments.joined(separator: "\n")
        if combined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fallbackSegments = pieces.compactMap { piece -> String? in
                guard case .text(let text) = piece else { return nil }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            combined = fallbackSegments.joined(separator: "\n")
        }
        
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ChatVM: ModelBenchmarkingViewModel {
    func unloadAfterBenchmark() async {
        await unload()
    }
}

// MARK: –– Chat UI ----------------------------------------------------------

private enum TranscriptSaveFeedback: Equatable {
    case saving
    case saved(String?)
    case failed(String)

    var message: String? {
        switch self {
        case .saving:
            return String(localized: "Saving...")
        case .saved(let datasetName):
            if let datasetName, !datasetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return String.localizedStringWithFormat(String(localized: "Saved to %@"), datasetName)
            }
            return String(localized: "Saved to Stored")
        case .failed(let message):
            return message
        }
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }

    var isSaved: Bool {
        if case .saved = self { return true }
        return false
    }
}

enum TranscriptQuickAction: String, CaseIterable, Identifiable {
    case summarize
    case ask
    case actionItems
    case studyNotes
    case decisions
    case timeline
    case followUp

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .summarize: return "Summarize"
        case .ask: return "Ask"
        case .actionItems: return "Extract action items"
        case .studyNotes: return "Create study notes"
        case .decisions: return "Find decisions"
        case .timeline: return "Make timeline"
        case .followUp: return "Draft follow-up"
        }
    }

    var iconName: String {
        switch self {
        case .summarize: return "text.bubble"
        case .ask: return "questionmark.bubble"
        case .actionItems: return "checklist"
        case .studyNotes: return "book"
        case .decisions: return "checkmark.seal"
        case .timeline: return "list.bullet.rectangle"
        case .followUp: return "envelope"
        }
    }

    func prompt(for title: String) -> String {
        switch self {
        case .summarize:
            return String(localized: "Summarize this transcript.")
        case .ask:
            return String.localizedStringWithFormat(String(localized: "Ask about %@: "), title)
        case .actionItems:
            return String(localized: "Extract action items from this transcript.")
        case .studyNotes:
            return String(localized: "Create study notes from this transcript.")
        case .decisions:
            return String(localized: "Find the decisions in this transcript.")
        case .timeline:
            return String(localized: "Make a timeline from this transcript.")
        case .followUp:
            return String(localized: "Draft a follow-up based on this transcript.")
        }
    }
}

enum ASRRecoveryAction: String, CaseIterable, Identifiable {
    case openSettings
    case chooseLocale
    case downloadWhisperModel
    case configureEndpoint
    case retry

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .openSettings: return "Open ASR Settings"
        case .chooseLocale: return "Choose Locale"
        case .downloadWhisperModel: return "Download Whisper Model"
        case .configureEndpoint: return "Configure Endpoint"
        case .retry: return "Retry"
        }
    }

    var iconName: String {
        switch self {
        case .openSettings: return "gearshape"
        case .chooseLocale: return "globe"
        case .downloadWhisperModel: return "arrow.down.circle"
        case .configureEndpoint: return "network"
        case .retry: return "arrow.clockwise"
        }
    }

    static func actions(
        for message: String,
        includeRetry: Bool,
        includeRemoteEndpoint: Bool = false
    ) -> [ASRRecoveryAction] {
        let lower = message.lowercased()
        var actions: [ASRRecoveryAction] = []
        if lower.contains("locale") || lower.contains("on-device") || lower.contains("recognition") {
            actions.append(.chooseLocale)
        }
        if lower.contains("whisper") || lower.contains("model") || lower.contains("download") {
            actions.append(.downloadWhisperModel)
        }
        if includeRemoteEndpoint,
           lower.contains("endpoint") || lower.contains("remote") || lower.contains("audio-language") || lower.contains("upload") {
            actions.append(.configureEndpoint)
        }
        if lower.contains("permission") || lower.contains("unavailable") || actions.isEmpty {
            actions.append(.openSettings)
        }
        if includeRetry {
            actions.append(.retry)
        }
        return actions.reduce(into: []) { unique, action in
            if !unique.contains(action) { unique.append(action) }
        }
    }
}

private struct TranscriptReviewSheet: View {
    let attachment: ChatMediaAttachment
    let allowsEditing: Bool
    let onSaveEdits: (String, String) -> Void
    let onQuickAction: (TranscriptQuickAction) -> Void
    let onSaveNewDataset: () -> Void
    let onSaveExistingDataset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var transcriptText: String
    @State private var showsSegments = false

    init(
        attachment: ChatMediaAttachment,
        allowsEditing: Bool,
        onSaveEdits: @escaping (String, String) -> Void,
        onQuickAction: @escaping (TranscriptQuickAction) -> Void,
        onSaveNewDataset: @escaping () -> Void,
        onSaveExistingDataset: @escaping () -> Void
    ) {
        self.attachment = attachment
        self.allowsEditing = allowsEditing
        self.onSaveEdits = onSaveEdits
        self.onQuickAction = onQuickAction
        self.onSaveNewDataset = onSaveNewDataset
        self.onSaveExistingDataset = onSaveExistingDataset
        let artifact = attachment.transcript
        _title = State(initialValue: artifact?.displaySourceName ?? attachment.originalFilename)
        _transcriptText = State(initialValue: artifact?.effectiveTranscriptText ?? "")
    }

    private var visibleSegmentRows: [TranscriptReviewDisplayRow] {
        guard let artifact = attachment.transcript else {
            return TranscriptReviewDisplayRow.rows(from: transcriptText)
        }
        if !artifact.segments.isEmpty {
            return artifact.reviewSegmentRows
        }
        return TranscriptReviewDisplayRow.rows(from: transcriptText)
    }

    private var visibleTranscriptText: String {
        if showsSegments {
            return visibleSegmentRows.map { "[\($0.label)] \($0.text)" }.joined(separator: "\n")
        }
        return transcriptText
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey("Source title"))
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField(LocalizedStringKey("Source title"), text: $title)
                        .font(.title3)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 54)
                        .background(transcriptFieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(transcriptBorderColor, lineWidth: 1)
                        )
                        .disabled(!allowsEditing)
                }

                if let artifact = attachment.transcript {
                    Text(artifact.provenanceSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker(LocalizedStringKey("Transcript view"), selection: $showsSegments) {
                    Text(LocalizedStringKey("Full Text")).tag(false)
                    Text(LocalizedStringKey("Segments")).tag(true)
                }
                .pickerStyle(.segmented)

                if showsSegments {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(visibleSegmentRows.enumerated()), id: \.offset) { _, row in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(row.label)
                                        .font(.caption.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 54, alignment: .leading)
                                    Text(row.text)
                                        .font(.body)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .frame(minHeight: 320)
                    .background(transcriptFieldBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(transcriptBorderColor, lineWidth: 1)
                    )
                } else {
                    TextEditor(text: $transcriptText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 320)
                        .background(transcriptFieldBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .disabled(!allowsEditing)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(transcriptBorderColor, lineWidth: 1)
                        )
                }

                HStack(spacing: 8) {
                    Button {
                        copyTranscriptToPasteboard(visibleTranscriptText)
                    } label: {
                        transcriptActionLabel("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    Menu {
                        Button {
                            onSaveNewDataset()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            onSaveExistingDataset()
                            dismiss()
                        } label: {
                            Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        transcriptActionLabel("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    Menu {
                        ForEach(TranscriptQuickAction.allCases) { action in
                            Button {
                                onQuickAction(action)
                                dismiss()
                            } label: {
                                Label(action.titleKey, systemImage: action.iconName)
                            }
                        }
                    } label: {
                        transcriptActionLabel("Actions", systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)

                    if allowsEditing {
                        Button {
                            onSaveEdits(title, transcriptText)
                            dismiss()
                        } label: {
                            transcriptActionLabel("Done", systemImage: "checkmark", isProminent: true)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)
            .background(transcriptSheetBackground.ignoresSafeArea())
            .navigationTitle(Text(LocalizedStringKey("Review Transcript")))
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(.primary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(transcriptActionBackground))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey("Close")))
                }
            }
        }
    }

    private func transcriptActionLabel(
        _ titleKey: String,
        systemImage: String,
        isProminent: Bool = false
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .imageScale(.medium)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(titleKey))
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .allowsTightening(true)
        }
        .foregroundStyle(isProminent ? Color.white : Color.accentColor)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(
            Capsule(style: .continuous)
                .fill(isProminent ? Color.accentColor : transcriptActionBackground)
        )
    }

    private var transcriptSheetBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    private var transcriptFieldBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemBackground)
        #endif
    }

    private var transcriptActionBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemFill)
        #endif
    }

    private var transcriptBorderColor: Color {
        Color.secondary.opacity(0.18)
    }
}

private struct TranscriptDatasetPickerSheet: View {
    let datasets: [LocalDataset]
    let onSelect: (LocalDataset) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(datasets) { dataset in
                Button {
                    onSelect(dataset)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dataset.name)
                            .font(.body.weight(.semibold))
                        Text(dataset.datasetID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(Text(LocalizedStringKey("Choose Dataset")))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LocalizedStringKey("Cancel")) { dismiss() }
                }
            }
            .overlay {
                if datasets.isEmpty {
                    ContentUnavailableView(
                        LocalizedStringKey("No Stored datasets"),
                        systemImage: "folder",
                        description: Text(LocalizedStringKey("Create a Stored dataset first, then save transcripts into it."))
                    )
                }
            }
        }
    }
}

private func copyTranscriptToPasteboard(_ text: String) {
#if canImport(UIKit)
    UIPasteboard.general.string = text
#elseif canImport(AppKit)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
#endif
}

extension ChatVM.Msg {
    /// Returns a copy of this message with its visible text replaced. Used to render the
    /// streaming bubble from the live `StreamingMessageStore` text without mutating the
    /// `sessions`-backed copy on every token.
    func replacingText(_ newText: String) -> ChatVM.Msg {
        var copy = self
        copy.text = newText
        return copy
    }
}

/// Wraps `MessageView` so only the in-flight assistant bubble re-renders from the
/// `StreamingMessageStore` on every token. All other messages render statically from
/// their `msg` copy — no `@ObservedObject` subscription here, so a token update
/// never touches completed messages (tool calls, previous turns, etc.).
struct StreamingAwareMessageView: View {
    let msg: ChatVM.Msg
    let store: StreamingMessageStore   // plain let — no subscription

    /// Tracks whether THIS specific message is the one currently streaming.
    /// Updated via `onReceive(store.$activeID)` + `onAppear` so the transition
    /// is immediate even when the view is first mounted mid-stream.
    @State private var isStreamingThis = false

    var body: some View {
        Group {
            if isStreamingThis {
                ActiveStreamingMessageView(msg: msg, store: store)
            } else {
                MessageView(msg: msg)
            }
        }
        .onAppear {
            // Handle the case where the view mounts while streaming is already active.
            isStreamingThis = (store.activeID == msg.id)
        }
        .onReceive(store.$activeID) { id in
            let should = (id == msg.id)
            if isStreamingThis != should { isStreamingThis = should }
        }
    }
}

/// Holds the `@ObservedObject` subscription so only the one in-flight bubble
/// re-renders per token. Separated into its own struct so the subscription is
/// mounted/unmounted with the view rather than living on every row.
private struct ActiveStreamingMessageView: View {
    let msg: ChatVM.Msg
    @ObservedObject var store: StreamingMessageStore

    var body: some View {
        MessageView(msg: msg.replacingText(store.visibleText))
            // One scoped transaction per store flush (~30 Hz): newly inserted
            // word fragments fade in (WrappedInline attaches the transitions),
            // new paragraphs/blocks fade via the default ForEach transition,
            // and the bubble's height grows smoothly instead of jumping.
            // Scoped to the live bubble only — finished rows never animate.
            .animation(.easeOut(duration: 0.22), value: store.visibleText)
    }
}

/// Invisible view that follows the streaming text and keeps the chat pinned to the
/// bottom. It subscribes to the `StreamingMessageStore`, so it (and not the whole chat
/// list) is what re-renders on every token.
struct StreamingScrollAnchor: View {
    @ObservedObject var store: StreamingMessageStore
    let proxy: ScrollViewProxy
    let enabled: Bool

    /// `scrollTo` forces a synchronous layout pass of the scroll content. At
    /// the store's ~30 Hz flush cadence that triples the layout work and makes
    /// concurrent user scrolling stutter; ~12 Hz is visually identical for a
    /// bottom pin. A trailing call guarantees the final position after the
    /// last flush (e.g. `finish()`).
    @State private var lastScrollAt = Date.distantPast
    @State private var trailingScrollScheduled = false
    private static let minScrollInterval: TimeInterval = 0.08

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onChangeCompat(of: store.visibleText) { _, _ in
                scrollToBottomThrottled()
            }
    }

    /// Critically damped spring: retargeting at the throttle cadence preserves
    /// velocity, so the pinned view glides continuously instead of snapping to
    /// each new bottom position.
    private static let followAnimation = Animation.spring(response: 0.28, dampingFraction: 1.0)

    private func scrollToBottomThrottled() {
        guard enabled, let id = store.activeID else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastScrollAt)
        if elapsed >= Self.minScrollInterval {
            lastScrollAt = now
            withAnimation(Self.followAnimation) {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else if !trailingScrollScheduled {
            trailingScrollScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.minScrollInterval - elapsed)) {
                trailingScrollScheduled = false
                guard enabled, let id = store.activeID else { return }
                lastScrollAt = Date()
                withAnimation(Self.followAnimation) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}

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

/// Renders a single message. Any text between `<think>` tags is wrapped in a
/// collapsible box with rounded corners.
struct MessageView: View {
    let msg: ChatVM.Msg
    @EnvironmentObject var vm: ChatVM
    @EnvironmentObject var tabRouter: TabRouter
    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedThinkIndices: Set<Int> = []
    @State private var showCopyPopup = false
    @State private var copiedMessage = false
    @State private var pinnedToScratchpad = false
    @State private var expandedImagePath: String? = nil
    @State private var showEvidenceSheet = false
    @State private var transcriptSaveFeedback: [ChatMediaAttachment.ID: TranscriptSaveFeedback] = [:]
    @State private var transcriptReviewAttachment: ChatMediaAttachment?
    @State private var existingDatasetSaveAttachment: ChatMediaAttachment?
#if os(macOS)
    @State private var hoverCopyVisible = false
    @State private var suppressHoverCopy = false
#endif
#if os(visionOS)
    @EnvironmentObject private var pinnedStore: VisionPinnedNoteStore
    @Environment(\.openWindow) private var openWindow
    @State private var hoverActive = false
    @State private var showInteractionOptions = false
    @GestureState private var isPressingMessage = false
#endif

    private struct PrivacyBadgeDescriptor {
        let title: LocalizedStringKey
        let accessibilityLabel: LocalizedStringKey
        let iconName: String
        let tint: Color
    }
    
    private var datasetDisplayName: String? {
        if let stored = msg.datasetName, !stored.isEmpty { return stored }
        if let id = msg.datasetID,
           let ds = vm.datasetManager?.datasets.first(where: { $0.datasetID == id }) {
            return ds.name
        }
        return nil
    }

    private var retrievedContextChunks: [String] {
        (msg.retrievedContext ?? "")
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var ragChunkCount: Int {
        // RAG surfaces the same retrieved chunks three ways: one citation per
        // chunk, the joined `retrievedContext` string, and the `ragInjectionInfo`
        // summary. They're the same evidence, so count them once — as the number
        // of chunks. (e.g. 2 chunks must read as 2, not 2 + 2 + 1 = 5.)
        msg.citations?.count ?? retrievedContextChunks.count
    }

    private var evidenceItemCount: Int {
        var count = 0
        count += ragChunkCount
        // A web search is a `noema.web.retrieve` tool call whose results are
        // already counted via `webHits`. Counting the call itself would
        // double-count it (e.g. 3 results + 1 call = 4), so only its results
        // contribute. Every other tool call counts as one evidence point.
        count += msg.toolCalls?.filter { $0.toolName != "noema.web.retrieve" }.count ?? 0
        count += msg.webHits?.count ?? 0
        count += msg.imagePaths?.count ?? 0
        count += msg.mediaAttachments?.count ?? 0
        return count
    }

    private var hasEvidenceReceipt: Bool {
        msg.role != "🧑‍💻" && evidenceItemCount > 0
    }

    private var privacyBadgeDescriptor: PrivacyBadgeDescriptor? {
        guard msg.role != "🧑‍💻" else { return nil }
        if msg.usedRemoteBackend == true {
            return PrivacyBadgeDescriptor(
                title: "Remote",
                accessibilityLabel: "Remote Answer",
                iconName: "antenna.radiowaves.left.and.right",
                tint: .purple
            )
        }
        if msg.ranOnPrivateCloudCompute == true {
            return PrivacyBadgeDescriptor(
                title: "Private Cloud",
                accessibilityLabel: "Answered with Apple Private Cloud Compute",
                iconName: "lock.icloud",
                tint: .indigo
            )
        }
        if msg.usedWebSearch == true || msg.webHits?.isEmpty == false {
            return PrivacyBadgeDescriptor(
                title: "Network",
                accessibilityLabel: "Network-Assisted Answer",
                iconName: "globe",
                tint: .blue
            )
        }
        // "Local Only" is the expected default for a local-first app, so it only
        // appears as a diagnostic detail — the toolbar status dot carries the
        // local/private signal in normal use.
        if msg.usedRemoteBackend == false, isAdvancedMode {
            return PrivacyBadgeDescriptor(
                title: "Local Only",
                accessibilityLabel: "Local-Only Answer",
                iconName: "lock.shield",
                tint: .green
            )
        }
        return nil
    }

    private var hasReceiptBadges: Bool {
        privacyBadgeDescriptor != nil
            || hasEvidenceReceipt
            || (isAdvancedMode && (shouldNudgeForMissingEvidence || shouldShowModelOnlyUncertainty))
    }

    private var isCompletedAssistantAnswer: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var expectedGroundingWithoutEvidence: Bool {
        guard isCompletedAssistantAnswer, evidenceItemCount == 0 else { return false }
        let trimmedText = msg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty, !msg.streaming else { return false }
        return msg.datasetID != nil
            || msg.datasetName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || msg.usedWebSearch == true
            || msg.webError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var shouldNudgeForMissingEvidence: Bool {
        canAuditMessage && expectedGroundingWithoutEvidence
    }

    private var shouldShowModelOnlyUncertainty: Bool {
        isCompletedAssistantAnswer && evidenceItemCount == 0 && !expectedGroundingWithoutEvidence
    }
    
    /// Memoized: the result depends only on the text and the tool-call count
    /// (pieces store indices into the calls array, not the calls themselves),
    /// verified against `parseUncached`'s body which reads nothing else.
    private static let parsedPiecesCache = TextComputationCache<[ChatVM.Piece]>()

    private func parse(_ text: String, toolCalls: [ChatVM.Msg.ToolCall]? = nil) -> [ChatVM.Piece] {
        let countTag = toolCalls.map { String($0.count) } ?? "-"
        return Self.parsedPiecesCache.value(for: "\(countTag)\u{1}\(text)") {
            parseUncached(text, toolCalls: toolCalls)
        }
    }

    private func parseUncached(_ text: String, toolCalls: [ChatVM.Msg.ToolCall]? = nil) -> [ChatVM.Piece] {
        // First parse code blocks
        let codeBlocks = ChatVM.parseCodeBlocks(text)
        
        // Then parse think tags within each text piece
        var finalPieces: [ChatVM.Piece] = []
        var toolCallIndex = 0 // Track which tool call we're currently processing
        
        for piece in codeBlocks {
            switch piece {
            case .code(let code, let lang):
                // Detect tool-call JSON/XML inside fenced code blocks and surface a tool placeholder instead
                var insertedToolFromCodeBlock = false
                let codeSub = code[...]
                var tmp = codeSub
                // 1) XML-style <tool_call> blocks inside code fences
                while let callTag = tmp.range(of: "<tool_call>") {
                    tmp = tmp[callTag.upperBound...]
                    if let end = tmp.range(of: "</tool_call>") {
                        tmp = tmp[end.upperBound...]
                    } else {
                        tmp = tmp[tmp.endIndex...]
                    }
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 2) TOOL_CALL:/TOOL_RESULT markers inside code fences
                tmp = codeSub
                while let callRange = tmp.range(of: "TOOL_CALL:") {
                    tmp = tmp[callRange.upperBound...]
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                    insertedToolFromCodeBlock = true
                }
                // 3) Bare JSON tool-call object inside code fences
                tmp = codeSub
                var searchStart = tmp.startIndex
                scanJSONInCode: while let braceStart = tmp[searchStart...].firstIndex(of: "{") {
                    if let braceEnd = findMatchingBrace(in: tmp, startingFrom: braceStart) {
                        let candidate = tmp[braceStart...braceEnd]
                        if (candidate.contains("\"tool_name\"") || candidate.contains("\"name\"") || candidate.contains("\"tool\"")) &&
                            (candidate.contains("\"arguments\"") || candidate.contains("\"args\"")) {
                            finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                            if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 { toolCallIndex += 1 }
                            insertedToolFromCodeBlock = true
                            // Continue after this JSON object in case of multiple
                            searchStart = tmp.index(after: braceEnd)
                            continue scanJSONInCode
                        }
                        searchStart = tmp.index(after: braceEnd)
                        continue scanJSONInCode
                    } else {
                        break scanJSONInCode
                    }
                }
                if !insertedToolFromCodeBlock {
                    finalPieces.append(ChatVM.Piece.code(code, language: lang))
                }
            case .text(let t):
                // Parse think tags in text
                var rest = t[...]
                // Detect multiple inline tool_call blocks
                func appendTextWithThinks(_ segment: Substring) {
                    var tmp = segment
                    while let s = tmp.range(of: "<think>") {
                        if s.lowerBound > tmp.startIndex {
                            // Strip any stray closing tags in plain text
                            let beforeText = String(tmp[..<s.lowerBound]).replacingOccurrences(of: "</think>", with: "")
                            finalPieces.append(ChatVM.Piece.text(beforeText))
                        }
                        tmp = tmp[s.upperBound...]
                        if let e = tmp.range(of: "</think>") {
                            let inner = String(tmp[..<e.lowerBound])
                            // Sanitize nested or stray think markers inside the box content
                            let sanitizedInner = inner
                                .replacingOccurrences(of: "<think>", with: "")
                                .replacingOccurrences(of: "</think>", with: "")
                            finalPieces.append(ChatVM.Piece.think(sanitizedInner, done: true))
                            tmp = tmp[e.upperBound...]
                        } else {
                            let partial = String(tmp)
                                .replacingOccurrences(of: "<think>", with: "")
                                .replacingOccurrences(of: "</think>", with: "")
                            finalPieces.append(ChatVM.Piece.think(partial, done: false))
                            tmp = tmp[tmp.endIndex...]
                        }
                    }
                    if !tmp.isEmpty {
                        let trailingText = String(tmp).replacingOccurrences(of: "</think>", with: "")
                        finalPieces.append(ChatVM.Piece.text(trailingText))
                    }
                }
                while let anchorRange = rest.range(of: noemaToolAnchorToken) {
                    if anchorRange.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<anchorRange.lowerBound]) }
                    rest = rest[anchorRange.upperBound...]
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                while let callTag = rest.range(of: "<tool_call>") {
                    if callTag.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<callTag.lowerBound]) }
                    rest = rest[callTag.upperBound...]
                    if let end = rest.range(of: "</tool_call>") {
                        rest = rest[end.upperBound...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                // Detect multiple TOOL_CALL markers
                while let callRange = rest.range(of: "TOOL_CALL:") {
                    if callRange.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<callRange.lowerBound]) }
                    var after = rest[callRange.upperBound...]
                    if let nextResp = (after.range(of: "<tool_response>") ?? after.range(of: "TOOL_RESULT:")) {
                        rest = after[nextResp.lowerBound...]
                    } else if let nl = after.firstIndex(of: "\n") {
                        rest = after[nl...]
                    } else {
                        rest = rest[rest.endIndex...]
                    }
                    // Use the current tool call index and increment for next one
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                        toolCallIndex += 1
                    }
                }
                
                // Detect bare JSON tool call objects and hide them inline
                // Looks for a JSON object containing either "tool_name" or legacy "name" along with "arguments"
                var searchStart = rest.startIndex
                scanJSON: while let braceStart = rest[searchStart...].firstIndex(of: "{") {
                    let maybeEnd = findMatchingBrace(in: rest, startingFrom: braceStart)
                    if let braceEnd = maybeEnd {
                        let candidate = rest[braceStart...braceEnd]
                        if (candidate.contains("\"tool_name\"") || candidate.contains("\"name\"")) && candidate.contains("\"arguments\"") {
                            // Emit text before the JSON block
                            if braceStart > rest.startIndex { appendTextWithThinks(rest[..<braceStart]) }
                            // Skip over the JSON block and insert a tool box placeholder
                            let afterEnd = rest.index(after: braceEnd)
                            rest = rest[afterEnd...]
                            finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                            if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                                toolCallIndex += 1
                            }
                            // Restart search at beginning of updated remainder
                            searchStart = rest.startIndex
                            continue scanJSON
                        }
                    } else {
                        // Incomplete JSON; if it looks like a tool call, show placeholder and hide the partial content
                        let hasNameKey = rest.range(of: "\"name\"")
                        let hasToolNameKey = rest.range(of: "\"tool_name\"")
                        let hasArgsKey = rest.range(of: "\"arguments\"")
                        if (hasNameKey != nil || hasToolNameKey != nil), let argsRange = hasArgsKey {
                            if (hasNameKey?.lowerBound ?? braceStart) >= braceStart || argsRange.lowerBound >= braceStart {
                                if braceStart > rest.startIndex { appendTextWithThinks(rest[..<braceStart]) }
                                // Drop everything after the braceStart for now (will be replaced as stream continues)
                                rest = rest[rest.endIndex...]
                                finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                                if toolCalls != nil && toolCallIndex < (toolCalls?.count ?? 0) - 1 {
                                    toolCallIndex += 1
                                }
                                break scanJSON
                            }
                        }
                        // Continue searching after this opening brace
                        searchStart = rest.index(after: braceStart)
                        continue scanJSON
                    }
                    // Continue searching after this opening brace if not matched
                    searchStart = rest.index(after: braceStart)
                }
                // Hide multiple tool_response blocks
                toolLoop: while let toolRange = rest.range(of: "<tool_response>") ?? rest.range(of: "TOOL_RESULT:") {
                    if toolRange.lowerBound > rest.startIndex { appendTextWithThinks(rest[..<toolRange.lowerBound]) }

                    let markerSlice = rest[toolRange]
                    var remainder = rest[toolRange.upperBound...]
                    var consumedPayload = false

                    if markerSlice.hasPrefix("<tool_response>") {
                        if let end = remainder.range(of: "</tool_response>") {
                            remainder = remainder[end.upperBound...]
                            consumedPayload = true
                        }
                    } else {
                        // TOOL_RESULT payload can be a JSON object or array; skip entire structure
                        var idx = remainder.startIndex
                        while idx < remainder.endIndex && remainder[idx].isWhitespace {
                            idx = remainder.index(after: idx)
                        }
                        if idx < remainder.endIndex {
                            if remainder[idx] == "[" {
                                if let close = findMatchingBracket(in: remainder, startingFrom: idx) {
                                    remainder = remainder[remainder.index(after: close)...]
                                    consumedPayload = true
                                }
                            } else if remainder[idx] == "{" {
                                if let close = findMatchingBrace(in: remainder, startingFrom: idx) {
                                    remainder = remainder[remainder.index(after: close)...]
                                    consumedPayload = true
                                }
                            } else {
                                if let newline = remainder[idx...].firstIndex(of: "\n") {
                                    remainder = remainder[newline...]
                                } else {
                                    remainder = remainder[remainder.endIndex...]
                                }
                                consumedPayload = true
                            }
                        } else {
                            remainder = remainder[idx...]
                            consumedPayload = true
                        }
                    }
                    // Tool response doesn't increment the index since it's for the same tool call
                    finalPieces.append(ChatVM.Piece.tool(toolCallIndex))
                    rest = remainder
                    if !consumedPayload { break toolLoop }
                }
                // Preserve all think blocks (and sanitize inner content)
                while let s = rest.range(of: "<think>") {
                    if s.lowerBound > rest.startIndex {
                        let before = String(rest[..<s.lowerBound]).replacingOccurrences(of: "</think>", with: "")
                        finalPieces.append(ChatVM.Piece.text(before))
                    }
                    
                    rest = rest[s.upperBound...]
                    if let e = rest.range(of: "</think>") {
                        let inner = String(rest[..<e.lowerBound])
                            .replacingOccurrences(of: "<think>", with: "")
                            .replacingOccurrences(of: "</think>", with: "")
                        finalPieces.append(ChatVM.Piece.think(inner, done: true))
                        rest = rest[e.upperBound...]
                    } else {
                        let partial = String(rest)
                            .replacingOccurrences(of: "<think>", with: "")
                            .replacingOccurrences(of: "</think>", with: "")
                        finalPieces.append(ChatVM.Piece.think(partial, done: false))
                        rest = rest[rest.endIndex...]
                    }
                }
                if !rest.isEmpty {
                    let tail = String(rest).replacingOccurrences(of: "</think>", with: "")
                    finalPieces.append(ChatVM.Piece.text(tail))
                }
            case .think:
                // This shouldn't happen from parseCodeBlocks
                finalPieces.append(piece)
            case .tool(_):
                // Render-time handled via ToolCallView; skip here
                break
            }
        }
        
        return finalPieces
    }
    
    
    // MARK: - Text or List rendering

    /// Cached output of the line-parsing + render-planning passes; pure
    /// function of the raw text, so safe to memoize across re-renders.
    private struct TextRenderPlan {
        let entries: [TextLineEntry]
        let units: [ChatMarkdownRenderUnit]
    }

    private static let renderPlanCache = TextComputationCache<TextRenderPlan>()

    private func renderPlan(for t: String) -> TextRenderPlan {
        Self.renderPlanCache.value(for: t) {
            let text = normalizeListFormatting(t)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return TextRenderPlan(entries: [], units: [])
            }
            let entries = parseTextEntries(from: text)
            let plannerEntries = entries.map { entry in
                switch entry {
                case .blank:
                    return ChatMarkdownPlannerEntry.blank
                case .thematicBreak:
                    return .thematicBreak
                case .heading(let level, let content):
                    return .heading(level: level, content: content)
                case .bullet(let marker, let content):
                    return .bullet(marker: marker, content: content)
                case .mathBlock(let source):
                    return .mathBlock(source)
                case .table:
                    return .table
                case .text(let line):
                    return .text(line)
                }
            }
#if os(macOS)
            let units = ChatMarkdownRenderPlanner.renderUnits(for: plannerEntries, isMacOS: true)
#else
            let units = ChatMarkdownRenderPlanner.renderUnits(for: plannerEntries, isMacOS: false)
#endif
            return TextRenderPlan(entries: entries, units: units)
        }
    }

    @ViewBuilder
    private func renderTextOrList(_ t: String) -> some View {
        // Enhanced rendering:
        // - Headings: lines starting with "# ", "## ", "### ", etc. get larger fonts
        // - Bullets: single-character markers ('-', '*', '+', '•') render with a leading dot
        // - Math/text runs are grouped into larger MathRichText blocks for smoother selection
        let plan = renderPlan(for: t)
        if plan.units.isEmpty {
            EmptyView()
        } else {
            let entries = plan.entries
            let units = plan.units
            let chatBlockMathStyle = BlockMathStyle.chat(bodyFontSize: preferredFontSize(.body))

            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(units.enumerated()), id: \.offset) { _, unit in
                    switch unit {
                    case .bulletBlock(let block):
                        MathRichText(source: block, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                            .font(chatBodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .textMathBlock(let block):
                        MathRichText(source: block, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                            .font(chatBodyFont)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .entryIndex(let idx):
                        switch entries[idx] {
                        case .blank:
                            Text("")
                        case .thematicBreak:
                            Divider()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        case .heading(let level, let content):
                            MathRichText(source: content, bodyFont: headingFont(for: level), bodyPointSize: headingPointSize(for: level), bodyWeight: .bold, blockMathStyle: chatBlockMathStyle)
                                .font(headingFont(for: level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .mathBlock(let source):
                            MathRichText(source: source, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                                .font(chatBodyFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .table(let headers, let alignments, let rows):
                            tableView(headers: headers, alignments: alignments, rows: rows)
                        case .text(let line):
                            MathRichText(source: line, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                                .font(chatBodyFont)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .bullet:
                            // Should not appear as individual entries because bullets are grouped.
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private enum TextLineEntry {
        case blank
        case thematicBreak
        case heading(level: Int, content: String)
        case bullet(marker: String, content: String)
        case mathBlock(String)
        case table(headers: [String], alignments: [TableColumnAlignment], rows: [[String]])
        case text(String)
    }

    private enum TextBlockDelimiter {
        case doubleDollar
        case bracket
    }

    private enum TableColumnAlignment {
        case leading
        case center
        case trailing

        var gridAlignment: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var frameAlignment: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }

        var textAlignment: TextAlignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }

    private func parseTextEntries(from text: String) -> [TextLineEntry] {
        func startDelimiter(for trimmed: String) -> TextBlockDelimiter? {
            switch trimmed {
            case "$$": return .doubleDollar
            case "\\[": return .bracket
            default: return nil
            }
        }

        func closes(_ trimmed: String, matching delimiter: TextBlockDelimiter) -> Bool {
            switch delimiter {
            case .doubleDollar: return trimmed == "$$"
            case .bracket: return trimmed == "\\]"
            }
        }

        let lines = text.components(separatedBy: .newlines)
        var entries: [TextLineEntry] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                entries.append(.blank)
                index += 1
                continue
            }

            if let table = parseTableBlock(startingAt: index, in: lines) {
                entries.append(.table(headers: table.headers, alignments: table.alignments, rows: table.rows))
                index += table.consumed
                continue
            }

            if let delimiter = startDelimiter(for: trimmed) {
                var blockLines: [String] = [line]
                var cursor = index + 1
                while cursor < lines.count {
                    let nextLine = lines[cursor]
                    blockLines.append(nextLine)
                    let nextTrimmed = nextLine.trimmingCharacters(in: .whitespaces)
                    if closes(nextTrimmed, matching: delimiter) {
                        cursor += 1
                        break
                    }
                    cursor += 1
                }
                entries.append(.mathBlock(blockLines.joined(separator: "\n")))
                index = cursor
                continue
            }

            if isThematicBreakLine(trimmed) {
                entries.append(.thematicBreak)
                index += 1
                continue
            }

            if let level = headingLevel(for: trimmed) {
                let content = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                entries.append(.heading(level: level, content: content))
                index += 1
                continue
            }

            if let (marker, content) = parseBulletLine(line) {
                entries.append(.bullet(marker: marker, content: content))
                index += 1
                continue
            }

            entries.append(.text(line))
            index += 1
        }

        return entries
    }

    private func isThematicBreakLine(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first else { return false }
        guard first == "-" || first == "_" || first == "*" else { return false }
        return compact.allSatisfy { $0 == first }
    }

    @ViewBuilder
    private func tableView(headers: [String], alignments: [TableColumnAlignment], rows: [[String]]) -> some View {
        let columns: [GridItem] = alignments.map { alignment in
            GridItem(.flexible(), spacing: 12, alignment: alignment.gridAlignment)
        }
        let chatBlockMathStyle = BlockMathStyle.chat(bodyFontSize: preferredFontSize(.body))

        VStack(spacing: 0) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    MathRichText(source: header, bodyFont: tableHeaderFont, bodyPointSize: 15, bodyWeight: .semibold, blockMathStyle: chatBlockMathStyle)
                        .font(tableHeaderFont)
                        .multilineTextAlignment(alignments[index].textAlignment)
                        .frame(maxWidth: .infinity, alignment: alignments[index].frameAlignment)
                }
            }
            .padding(.bottom, rows.isEmpty ? 0 : 10)

            if !rows.isEmpty {
                Divider()
                    .padding(.bottom, 10)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { columnIndex, value in
                        MathRichText(source: value, bodyFont: chatBodyFont, bodyPointSize: chatBodyPointSize, blockMathStyle: chatBlockMathStyle)
                            .font(chatBodyFont)
                            .multilineTextAlignment(alignments[columnIndex].textAlignment)
                            .frame(maxWidth: .infinity, alignment: alignments[columnIndex].frameAlignment)
                    }
                }
                if rowIndex < rows.count - 1 {
                    Divider()
                        .padding(.vertical, 10)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tableBackgroundColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tableBorderColor, lineWidth: 0.5)
        )
    }

    private func parseTableBlock(startingAt startIndex: Int, in lines: [String]) -> (consumed: Int, headers: [String], alignments: [TableColumnAlignment], rows: [[String]])? {
        guard let headerCells = parseTableRow(lines[startIndex]) else { return nil }
        let separatorIndex = startIndex + 1
        guard separatorIndex < lines.count,
              let alignments = parseTableAlignments(lines[separatorIndex], expectedCount: headerCells.count) else {
            return nil
        }

        var rows: [[String]] = []
        var cursor = separatorIndex + 1

        while cursor < lines.count {
            let candidate = lines[cursor]
            if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            guard let cells = parseTableRow(candidate), cells.count == headerCells.count else {
                break
            }
            rows.append(cells)
            cursor += 1
        }

        let consumed = 1 + 1 + rows.count
        return (consumed, headerCells, alignments, rows)
    }

    private func parseTableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var segments = trimmed.split(separator: "|", omittingEmptySubsequences: false).map { segment in
            segment.trimmingCharacters(in: .whitespaces)
        }

        if let first = segments.first, first.isEmpty { segments.removeFirst() }
        if let last = segments.last, last.isEmpty { segments.removeLast() }

        guard segments.count >= 2 else { return nil }

        // Require at least one non-empty column so we don't treat inline pipes as tables
        guard segments.contains(where: { !$0.isEmpty }) else { return nil }

        return segments
    }

    private func parseTableAlignments(_ line: String, expectedCount: Int) -> [TableColumnAlignment]? {
        guard let rawColumns = parseTableRow(line), rawColumns.count == expectedCount else { return nil }

        var alignments: [TableColumnAlignment] = []
        for column in rawColumns {
            let trimmed = column.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("-") else { return nil }

            let leadingColon = trimmed.hasPrefix(":")
            let trailingColon = trimmed.hasSuffix(":")
            let dashPortion = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashPortion.isEmpty, dashPortion.allSatisfy({ $0 == "-" }) else { return nil }

            let alignment: TableColumnAlignment
            if leadingColon && trailingColon {
                alignment = .center
            } else if trailingColon {
                alignment = .trailing
            } else {
                alignment = .leading
            }
            alignments.append(alignment)
        }

        return alignments
    }

    private func headingLevel(for line: String) -> Int? {
        // Recognize ATX-style headings: '#', '##', '###', up to 6
        guard line.first == "#" else { return nil }
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        // Must have a space after hashes to be a heading
        if count >= 1 && count <= 6 {
            let idx = line.index(line.startIndex, offsetBy: count)
            if idx < line.endIndex && line[idx].isWhitespace { return count }
        }
        return nil
    }
    
    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return .largeTitle
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }

    /// Point size matching `headingFont(for:)`, plumbed to the macOS renderer.
    private func headingPointSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return preferredFontSize(.largeTitle)
        case 2: return preferredFontSize(.title2)
        case 3: return preferredFontSize(.title3)
        default: return preferredFontSize(.headline)
        }
    }
    
    // Normalizes inline lists like " ...  1. Item  2. Item ..." to place each
    // item on its own line. Our rich text engine preserves paragraph breaks
    // only for double newlines, so we emit "\n\n" here.
    private func normalizeListFormatting(_ text: String) -> String {
        var s = text
        func replace(_ pattern: String, _ template: String) {
            if let rx = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = rx.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
            }
        }
        // Insert paragraph break before inline numbered items like "  2.", "  3)" or "  4]"
        replace(#"(?:(?<=^)|(?<=\n)|(?<=[:;]))\s*(?=\d{1,3}[\.\)\]]\s)"#, "\n\n")
        // Insert paragraph break before inline bullet markers like " - ", " * ", " + ", or " • "
        replace(#"(?:(?<=^)|(?<=\n)|(?<=[:;]))\s*(?=[\-\*\+•]\s)"#, "\n\n")
        // Ensure a single newline before a list marker becomes a paragraph break
        replace(#"\n(?=\s*(?:\d{1,3}[\.\)\]]\s|[\-\*\+•]\s))"#, "\n\n")
        // If a list follows a colon, break the line after the colon
        replace(#":\s+(?=(?:\d{1,3}[\.\)\]]\s|[\-\*\+•]\s))"#, ":\n\n")
        // Collapse any 3+ consecutive newlines into a double newline
        replace(#"\n{3,}"#, "\n\n")
        return s
    }
    
    // MARK: - List parsing helpers
    private struct TextBlock {
        let content: String
        let isList: Bool
        let marker: String?
    }
    
    private func parseTextBlocks(_ text: String) -> [TextBlock] {
        var blocks: [TextBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var currentTextBlock = ""
        
        for line in lines {
            if let (marker, content) = parseBulletLine(line) {
                // If we have accumulated text, add it as a text block
                if !currentTextBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blocks.append(TextBlock(content: currentTextBlock, isList: false, marker: nil))
                    currentTextBlock = ""
                }
                // Add the list item
                blocks.append(TextBlock(content: content, isList: true, marker: marker))
            } else {
                // Accumulate non-list lines
                currentTextBlock += (currentTextBlock.isEmpty ? "" : "\n") + line
            }
        }
        
        // Add any remaining text
        if !currentTextBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(TextBlock(content: currentTextBlock, isList: false, marker: nil))
        }
        
        return blocks
    }
    
    private func parseListItems(_ text: String) -> [(marker: String, content: String)] {
        var items: [(String, String)] = []
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            if let item = parseBulletLine(line) {
                items.append(item)
            }
        }
        
        return items
    }
    
    private func parseBulletLine(_ line: String) -> (marker: String, content: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        
        // Unordered bullets: -, *, +, •
        if trimmed.hasPrefix("- ") { return ("•", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("* ") { return ("•", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("+ ") { return ("•", String(trimmed.dropFirst(2))) }
        if trimmed.hasPrefix("• ") { return ("•", String(trimmed.dropFirst(2))) }
        
        // Ordered bullets: 1. 2) 3]
        if let dotIdx = trimmed.firstIndex(of: "."), dotIdx > trimmed.startIndex {
            let prefix = String(trimmed[..<dotIdx])
            if Int(prefix) != nil, trimmed[dotIdx...].hasPrefix(". ") {
                return (prefix + ".", String(trimmed[trimmed.index(dotIdx, offsetBy: 2)...]))
            }
        }
        if let parenIdx = trimmed.firstIndex(of: ")"), parenIdx > trimmed.startIndex {
            let prefix = String(trimmed[..<parenIdx])
            if Int(prefix) != nil, trimmed[parenIdx...].hasPrefix(") ") {
                return (prefix + ")", String(trimmed[trimmed.index(parenIdx, offsetBy: 2)...]))
            }
        }
        if let bracketIdx = trimmed.firstIndex(of: "]"), bracketIdx > trimmed.startIndex {
            let prefix = String(trimmed[..<bracketIdx])
            if Int(prefix) != nil, trimmed[bracketIdx...].hasPrefix("] ") {
                return (prefix + "]", String(trimmed[trimmed.index(bracketIdx, offsetBy: 2)...]))
            }
        }
        
        return nil
    }
    
    private func extractRemainingText(from text: String, afterListItems items: [(String, String)]) -> String {
        var remaining = ""
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            if parseBulletLine(line) == nil {
                remaining += (remaining.isEmpty ? "" : "\n") + line
            }
        }
        
        return remaining
    }
    
    @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @AppStorage("showGenerationDiagnostics") private var showGenerationDiagnostics = true
    
    // MARK: - Code block rendering
    private struct CodeBlockView: View {
        let code: String
        let language: String?
        @State private var copied = false
        
        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                // Header with language label and copy button
                HStack {
                    if let lang = language, !lang.isEmpty {
                        Text(lang)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: {
#if os(iOS)
                        UIPasteboard.general.string = code
#elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
#endif
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                            Text(copied ? "Copied!" : "Copy")
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                
                // Code content with darker background
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
#if os(macOS)
                        .textSelection(.enabled)
#endif
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(.systemGray6))
                .adaptiveCornerRadius(.small)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(Color(.systemGray5))
            .adaptiveCornerRadius(.medium)
            .overlay(
                RoundedRectangle(cornerRadius: UIConstants.cornerRadius)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
            )
        }
    }
    
    // Helper to find matching closing brace for a JSON object, honoring strings and escapes
    private func findMatchingBrace(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
        guard text[startIndex] == "{" else { return nil }
        var braceCount = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "{" { braceCount += 1 }
                else if char == "}" {
                    braceCount -= 1
                    if braceCount == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
    
    // Helper to find matching closing bracket for a JSON array, honoring strings and escapes
    private func findMatchingBracket(in text: Substring, startingFrom startIndex: Substring.Index) -> Substring.Index? {
        guard text[startIndex] == "[" else { return nil }
        var depth = 0
        var inString = false
        var escapeNext = false
        var idx = startIndex
        while idx < text.endIndex {
            let char = text[idx]
            if escapeNext {
                escapeNext = false
                idx = text.index(after: idx)
                continue
            }
            if char == "\\" && inString {
                escapeNext = true
                idx = text.index(after: idx)
                continue
            }
            if char == "\"" { inString.toggle() }
            if !inString {
                if char == "[" { depth += 1 }
                else if char == "]" {
                    depth -= 1
                    if depth == 0 { return idx }
                }
            }
            idx = text.index(after: idx)
        }
        return nil
    }
    
    private var chatBodyFont: Font {
#if os(macOS)
        return .system(size: 16, weight: .regular)
#else
        return .body
#endif
    }

    /// Point size matching `chatBodyFont`, plumbed to the macOS AppKit renderer.
    private var chatBodyPointSize: CGFloat {
#if os(macOS)
        return 16
#else
        return preferredFontSize(.body)
#endif
    }

    private var tableHeaderFont: Font {
#if os(macOS)
        return .system(size: 15, weight: .semibold)
#else
        return .system(size: 15, weight: .semibold)
#endif
    }

    private var tableBackgroundColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.06)
        }
        return Color.primary.opacity(0.05)
    }

    private var tableBorderColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.2 : 0.08)
    }

    private var isUserMessage: Bool {
        msg.role == "🧑‍💻"
    }

    private var messageHorizontalPadding: CGFloat {
        isUserMessage ? 12 : 0
    }

    private var messageVerticalPadding: CGFloat {
        isUserMessage ? 12 : 6
    }

    var bubbleColor: Color {
        if isUserMessage {
            return ChatTheme.userBubble(colorScheme)
        }
        return .clear
    }
    
    @ViewBuilder
    private func imagesView(paths: [String]) -> some View {
        let thumbSize = CGSize(width: 96, height: 96)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(paths.prefix(5).enumerated()), id: \.offset) { _, p in
                    let img = ImageThumbnailCache.shared.thumbnail(for: p, pointSize: thumbSize)
                    ZStack {
                        if let ui = img {
                            Image(platformImage: ui)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Rectangle().fill(Color.secondary.opacity(0.15))
                                .overlay(ProgressView().scaleEffect(0.6))
                        }
                    }
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipped()
                    .cornerRadius(12)
                    .drawingGroup(opaque: false)
                    .contentShape(Rectangle())
                    .onTapGesture { expandedImagePath = p }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private func mediaAttachmentsView(_ attachments: [ChatMediaAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                mediaAttachmentCard(attachment)
            }
        }
        .padding(.horizontal, 12)
    }

    private func mediaAttachmentCard(_ attachment: ChatMediaAttachment) -> some View {
        let saveFeedback = transcriptSaveFeedback[attachment.id]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: attachment.kind.iconName)
                    .foregroundStyle(Color.accentColor)
                Text(attachment.transcript?.displaySourceName ?? attachment.originalFilename)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if attachment.hasCompletedTranscript {
                    Button {
                        transcriptReviewAttachment = attachment
                    } label: {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .help(Text("Review Transcript"))

                    Menu {
                        Button {
                            saveTranscriptAttachment(attachment)
                        } label: {
                            Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                        }
                        Button {
                            existingDatasetSaveAttachment = attachment
                        } label: {
                            Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        if saveFeedback?.isSaving == true {
                            ProgressView()
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: "tray.and.arrow.down")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .disabled(saveFeedback?.isSaving == true || saveFeedback?.isSaved == true)
                    .help(Text("Save transcript to Stored"))
                }
            }

            if let mediaDetailLabel = attachment.mediaDetailLabel {
                Text(mediaDetailLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let transcript = attachment.transcript {
                Text(transcript.provenanceSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)

                Text(transcript.exportText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
                    .textSelection(.enabled)
            } else if let error = attachment.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }

            if let saveFeedback, let message = saveFeedback.message {
                Text(message)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(saveFeedback.isSaved ? Color.green : (saveFeedback.isSaving ? Color.secondary : Color.red))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment) {
        guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
        transcriptSaveFeedback[attachment.id] = .saving
        Task {
            let result = await vm.saveTranscriptAttachmentAsDataset(attachment)
            await MainActor.run {
                switch result {
                case .success(let dataset):
                    transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                case .failure(let error):
                    transcriptSaveFeedback[attachment.id] = .failed(
                        String.localizedStringWithFormat(
                            String(localized: "Transcript save failed: %@"),
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment, toExistingDataset dataset: LocalDataset) {
        guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
        transcriptSaveFeedback[attachment.id] = .saving
        Task {
            let result = await vm.saveTranscriptAttachment(attachment, toExistingDataset: dataset)
            await MainActor.run {
                switch result {
                case .success(let dataset):
                    transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                case .failure(let error):
                    transcriptSaveFeedback[attachment.id] = .failed(
                        String.localizedStringWithFormat(
                            String(localized: "Transcript save failed: %@"),
                            error.localizedDescription
                        )
                    )
                }
            }
        }
    }

    private struct AttachmentPreview: View {
        let path: String
        let onClose: () -> Void
        @Environment(\.dismiss) private var dismiss
        var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.95).ignoresSafeArea()
#if canImport(UIKit)
                if let ui = UIImage(contentsOfFile: path) {
                    Image(platformImage: ui)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .background(Color.black.opacity(0.001).ignoresSafeArea())
                } else {
                    Text("Unable to load image").foregroundColor(.white)
                }
#else
                if let ns = NSImage(contentsOfFile: path) {
                    Image(nsImage: ns)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                        .background(Color.black.opacity(0.001).ignoresSafeArea())
                } else {
                    Text("Unable to load image").foregroundColor(.white)
                }
#endif
                HStack {
                    Spacer()
                    Button(action: { onClose(); dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                            .padding(12)
                    }
                    .buttonStyle(.plain)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onClose(); dismiss() }
        }
    }

    private func displayedToolCall(_ call: ChatVM.Msg.ToolCall) -> ChatVM.Msg.ToolCall {
        guard call.toolName == "noema.web.retrieve" else { return call }

        if let err = msg.webError {
            return ChatVM.Msg.ToolCall(
                id: call.id,
                toolName: call.toolName,
                displayName: call.displayName,
                iconName: call.iconName,
                requestParams: call.requestParams,
                phase: .failed,
                externalToolCallID: call.externalToolCallID,
                result: call.result,
                error: err,
                timestamp: call.timestamp
            )
        }

        guard let hits = msg.webHits, !hits.isEmpty else { return call }

        let hitsArray: [[String: Any]] = hits.map { hit in
            [
                "title": hit.title,
                "url": hit.url,
                "snippet": hit.snippet,
                "engine": hit.engine,
                "score": hit.score
            ]
        }

        if let data = try? JSONSerialization.data(withJSONObject: hitsArray, options: .prettyPrinted),
           let jsonString = String(data: data, encoding: .utf8) {
            return ChatVM.Msg.ToolCall(
                id: call.id,
                toolName: call.toolName,
                displayName: call.displayName,
                iconName: call.iconName,
                requestParams: call.requestParams,
                phase: .completed,
                externalToolCallID: call.externalToolCallID,
                result: jsonString,
                error: nil,
                timestamp: call.timestamp
            )
        }

        return call
    }

    enum MissingToolFallbackKind: Equatable {
        case text
        case code
        case think
        case tool
        case promptProcessing
        case genericLoading
        case postToolWait
    }

    static func insertIndexForMissingToolEntries(in kinds: [MissingToolFallbackKind]) -> Int {
        let thinkIndices = kinds.enumerated().compactMap { index, kind -> Int? in
            kind == .think ? index : nil
        }
        if thinkIndices.count >= 2 {
            return thinkIndices[1]
        }
        if let firstThinkIndex = thinkIndices.first {
            return firstThinkIndex + 1
        }
        if let narrativeIndex = kinds.firstIndex(where: { $0 == .text || $0 == .code }) {
            return narrativeIndex
        }
        return kinds.endIndex
    }

    static func insertIndexForPromptProcessingEntry(in kinds: [MissingToolFallbackKind]) -> Int {
        if let lastToolIndex = kinds.lastIndex(of: .tool) {
            return lastToolIndex + 1
        }
        if let lastThinkIndex = kinds.lastIndex(of: .think) {
            return lastThinkIndex + 1
        }
        if let narrativeIndex = kinds.firstIndex(where: { $0 == .text || $0 == .code }) {
            return narrativeIndex
        }
        if let genericLoadingIndex = kinds.lastIndex(of: .genericLoading) {
            return genericLoadingIndex + 1
        }
        return kinds.endIndex
    }
    
    private struct RenderEntry: Identifiable {
        enum Kind {
            case text(String)
            case code(code: String, language: String?)
            case thinkExisting(key: String)
            case thinkNew(text: String, done: Bool, key: String)
            case tool(ChatVM.Msg.ToolCall)
            case promptProcessing(progress: Double)
            case genericLoading
            case postToolWait
        }

        let id: String
        let kind: Kind
        let topPadding: CGFloat
        let bottomPadding: CGFloat

        init(id: String, kind: Kind, topPadding: CGFloat, bottomPadding: CGFloat = 0) {
            self.id = id
            self.kind = kind
            self.topPadding = topPadding
            self.bottomPadding = bottomPadding
        }
    }

    @ViewBuilder
    private func piecesView(_ pieces: [ChatVM.Piece]) -> some View {
        let thinkOrdinals: [Int?] = {
            var ordinals = Array(repeating: Int?.none, count: pieces.count)
            var counter = 0
            for idx in pieces.indices {
                if pieces[idx].isThink {
                    ordinals[idx] = counter
                    counter += 1
                }
            }
            return ordinals
        }()

        let renderEntries: [RenderEntry] = {
            var results: [RenderEntry] = []
            var renderedToolCallIDs = Set<UUID>()

            for idx in pieces.indices {
                let piece = pieces[idx]
                let prevIsThink = idx > 0 ? pieces[idx - 1].isThink : false
                let prevIsTool = idx > 0 ? pieces[idx - 1].isTool : false

                switch piece {
                case .text(let t):
                    let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let topPadding: CGFloat = (prevIsThink || prevIsTool) ? 2 : 4
                    results.append(
                        RenderEntry(
                            id: "text-\(msg.id.uuidString)-\(idx)",
                            kind: .text(t),
                            topPadding: topPadding
                        )
                    )
                case .code(let code, let language):
                    results.append(
                        RenderEntry(
                            id: "code-\(msg.id.uuidString)-\(idx)",
                            kind: .code(code: code, language: language),
                            topPadding: 4
                        )
                    )
                case .think(let t, let done):
                    guard let thinkOrdinalIndex = thinkOrdinals[idx] else { continue }
                    let thinkKey = "message-\(msg.id.uuidString)-think-\(thinkOrdinalIndex)"

                    if vm.rollingThoughtViewModels[thinkKey] != nil {
                        results.append(
                            RenderEntry(
                                id: "think-existing-\(thinkKey)",
                                kind: .thinkExisting(key: thinkKey),
                                topPadding: 4
                            )
                        )
                    } else {
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { continue }
                        results.append(
                            RenderEntry(
                                id: "think-new-\(thinkKey)",
                                kind: .thinkNew(text: t, done: done, key: thinkKey),
                                topPadding: 4
                            )
                        )
                    }
                case .tool(let toolIndex):
                    guard let toolCalls = msg.toolCalls,
                          toolCalls.indices.contains(toolIndex) else { continue }

                    let originalCall = toolCalls[toolIndex]
                    let call = displayedToolCall(originalCall)
                    guard renderedToolCallIDs.insert(call.id).inserted else { continue }

                    results.append(
                        RenderEntry(
                            id: "tool-\(call.id.uuidString)",
                            kind: .tool(call),
                            topPadding: 4,
                            bottomPadding: 2
                        )
                    )
                }
            }
            // Ensure pending/completed tool calls render even when the model stream
            // did not emit inline TOOL_CALL/TOOL_RESULT markers in message text.
            if let toolCalls = msg.toolCalls {
                let hasParsedToolEntries = results.contains { entry in
                    if case .tool = entry.kind { return true }
                    return false
                }
                var missingToolEntries: [RenderEntry] = []
                for originalCall in toolCalls {
                    let call = displayedToolCall(originalCall)
                    guard renderedToolCallIDs.insert(call.id).inserted else { continue }
                    missingToolEntries.append(
                        RenderEntry(
                            id: "tool-\(call.id.uuidString)",
                            kind: .tool(call),
                            topPadding: 4,
                            bottomPadding: 2
                        )
                    )
                }
                if !missingToolEntries.isEmpty {
                    let insertIndex: Int
                    if !hasParsedToolEntries {
                        let kinds = results.map { entry -> MissingToolFallbackKind in
                            switch entry.kind {
                            case .text:
                                return .text
                            case .code:
                                return .code
                            case .thinkExisting, .thinkNew:
                                return .think
                            case .tool:
                                return .tool
                            case .promptProcessing:
                                return .promptProcessing
                            case .genericLoading:
                                return .genericLoading
                            case .postToolWait:
                                return .postToolWait
                            }
                        }
                        insertIndex = Self.insertIndexForMissingToolEntries(in: kinds)
                    } else {
                        // Out-of-band tool calls (no inline marker in text) slot in
                        // after the reasoning that *requested* them but before the
                        // reasoning/narrative that *reacted* to their result.
                        func isThinkEntry(_ kind: RenderEntry.Kind) -> Bool {
                            switch kind {
                            case .thinkExisting, .thinkNew:
                                return true
                            default:
                                return false
                            }
                        }
                        let lastParsedToolIndex = results.lastIndex { entry in
                            if case .tool = entry.kind { return true }
                            return false
                        }
                        let searchStart = lastParsedToolIndex.map { $0 + 1 } ?? results.startIndex
                        let thinkIndicesAfterTools = results.indices.filter {
                            $0 >= searchStart && isThinkEntry(results[$0].kind)
                        }
                        let trailingThinkIsStreaming: Bool = {
                            if case .think(_, let done)? = pieces.last, !done { return true }
                            return false
                        }()
                        let allMissingCallsResolved = missingToolEntries.allSatisfy { entry in
                            if case .tool(let call) = entry.kind {
                                return call.phase == .completed || call.phase == .failed
                            }
                            return true
                        }
                        if let lastThinkIndex = thinkIndicesAfterTools.last,
                           thinkIndicesAfterTools.count >= 2
                            || (trailingThinkIsStreaming && allMissingCallsResolved) {
                            // The final reasoning segment is the model reacting to
                            // the tool result — the call itself happened before it.
                            insertIndex = lastThinkIndex
                        } else {
                            insertIndex = results.firstIndex { entry in
                                switch entry.kind {
                                case .text, .code:
                                    return true
                                case .thinkExisting, .thinkNew, .tool, .promptProcessing, .genericLoading, .postToolWait:
                                    return false
                                }
                            } ?? results.endIndex
                        }
                    }
                    results.insert(contentsOf: missingToolEntries, at: insertIndex)
                }
            }
            if msg.shouldShowGenericLoadingIndicator {
                results.append(
                    RenderEntry(
                        id: "generic-loading-\(msg.id.uuidString)",
                        kind: .genericLoading,
                        // Clear the preceding tool card's drop shadow (radius 8,
                        // y 4) so the spinner doesn't sit half-buried under it.
                        topPadding: 12,
                        bottomPadding: 2
                    )
                )
            }
            if msg.shouldShowPromptProcessingCard, let promptProcessing = msg.promptProcessing {
                let kinds = results.map { entry -> MissingToolFallbackKind in
                    switch entry.kind {
                    case .text:
                        return .text
                    case .code:
                        return .code
                    case .thinkExisting, .thinkNew:
                        return .think
                    case .tool:
                        return .tool
                    case .promptProcessing:
                        return .promptProcessing
                    case .genericLoading:
                        return .genericLoading
                    case .postToolWait:
                        return .postToolWait
                    }
                }
                let insertIndex = Self.insertIndexForPromptProcessingEntry(in: kinds)
                results.insert(
                    RenderEntry(
                        id: "prompt-processing-\(msg.id.uuidString)",
                        kind: .promptProcessing(progress: promptProcessing.progress),
                        topPadding: 8,
                        bottomPadding: 2
                    ),
                    at: insertIndex
                )
            }
            // Append a small spinner after the last tool call while waiting
            // for the post-tool continuation to start streaming tokens.
            if msg.postToolWaiting, (!renderedToolCallIDs.isEmpty || (msg.toolCalls?.isEmpty == false)) {
                results.append(
                    RenderEntry(
                        id: "post-tool-wait-\(msg.id.uuidString)",
                        kind: .postToolWait,
                        // Clear the preceding tool card's drop shadow.
                        topPadding: 12,
                        bottomPadding: 2
                    )
                )
            }
            return results
        }()

        VStack(alignment: .leading, spacing: 0) {
            ForEach(renderEntries) { entry in
                switch entry.kind {
                case .text(let text):
                    renderTextOrList(text)
                        .padding(.top, entry.topPadding)
                case .code(let code, let language):
                    CodeBlockView(code: code, language: language)
                        .padding(.top, entry.topPadding)
                case .thinkExisting(let key):
                    if let viewModel = vm.rollingThoughtViewModels[key] {
                        RollingThoughtBox(viewModel: viewModel)
                            .padding(.top, entry.topPadding)
                    }
                case .thinkNew(let text, let done, let key):
                    let tempVM = RollingThoughtViewModel()
                    RollingThoughtBox(viewModel: tempVM)
                        .padding(.top, entry.topPadding)
                        .onAppear {
                            DispatchQueue.main.async {
                                tempVM.fullText = text
                                tempVM.updateRollingLines()
                                tempVM.phase = done ? .complete : .streaming
                                if vm.rollingThoughtViewModels[key] == nil {
                                    vm.rollingThoughtViewModels[key] = tempVM
                                }
                            }
                        }
                case .tool(let call):
                    ToolCallView(toolCall: call).equatable()
                        .padding(.top, entry.topPadding)
                        .padding(.bottom, entry.bottomPadding)
                case .promptProcessing(let progress):
                    ProcessingPromptCardView(progress: progress)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, entry.topPadding)
                        .padding(.bottom, entry.bottomPadding)
                case .genericLoading:
                    HStack {
                        ProgressView()
                            .scaleEffect(0.85)
                            .tint(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, entry.topPadding)
                    .padding(.bottom, entry.bottomPadding)
                case .postToolWait:
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.top, entry.topPadding)
                        .padding(.bottom, entry.bottomPadding)
                }
            }
        }
    }
    
    private func copyMessageToPasteboard() {
        let copyPayload = copyableMessageText()
#if os(iOS) || os(visionOS)
        UIPasteboard.general.string = copyPayload
#if os(iOS)
        Haptics.impact(.light)
#endif
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyPayload, forType: .string)
#endif
        copiedMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copiedMessage = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if copiedMessage {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showCopyPopup = false
                }
            }
        }
    }

    private func toggleMessageBookmark() {
        vm.toggleBookmark(messageID: msg.id)
#if os(iOS)
        Haptics.impact(.light)
#endif
    }

    private func pinMessageToScratchpad() {
        let text = copyableMessageText()
        vm.pinMessageTextToActiveScratchpad(text, role: msg.role, timestamp: msg.timestamp)
#if os(iOS)
        Haptics.impact(.light)
#endif
        pinnedToScratchpad = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            pinnedToScratchpad = false
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
    }

    private func branchFromMessage() {
        _ = vm.branchSession(fromMessageID: msg.id)
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
    }

    private var canRegenerateMessage: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && vm.canAcceptChatInput
            && !vm.isStreamingInAnotherSession
    }

    private var canAskWithAnotherModel: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && !vm.isStreamingInAnotherSession
    }

    private var canAuditMessage: Bool {
        (msg.role == "🤖" || msg.role.lowercased() == "assistant")
            && !msg.streaming
            && vm.canAcceptChatInput
            && !vm.isStreamingInAnotherSession
    }

    private func regenerateMessage() {
        guard canRegenerateMessage else { return }
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
        Task { await vm.regenerateAssistantResponse(messageID: msg.id) }
    }

    private func askWithAnotherModel() {
        guard canAskWithAnotherModel else { return }
        guard vm.prepareAskSamePromptWithAnotherModel(messageID: msg.id) else { return }
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
        UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
        tabRouter.selection = .explore
    }

    private func auditMessage() {
        guard canAuditMessage else { return }
#if os(iOS)
        Haptics.impact(.light)
#endif
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showCopyPopup = false
        }
        let prompt = String(localized: "Audit the previous answer for unsupported claims, missing caveats, possible errors, and places where the evidence is weak.")
        Task { await vm.sendMessage(prompt) }
    }

    private func copyableMessageText() -> String {
        let pieces = parse(msg.text, toolCalls: msg.toolCalls)
        var sections: [String] = []
        sections.reserveCapacity(pieces.count)

        var textAccumulator = ""

        func flushTextAccumulator() {
            let trimmed = textAccumulator.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let sanitized = textAccumulator.trimmingCharacters(in: .newlines)
                sections.append(sanitized)
            }
            textAccumulator.removeAll(keepingCapacity: true)
        }

        for piece in pieces {
            switch piece {
            case .text(let text):
                textAccumulator.append(text)
            case .code(let code, let language):
                flushTextAccumulator()
                let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedCode.isEmpty else { continue }
                let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let header = lang.isEmpty ? "```" : "```\(lang)"
                var block = header + "\n" + code
                if !code.hasSuffix("\n") {
                    block.append("\n")
                }
                block.append("```")
                sections.append(block)
            case .think, .tool:
                continue
            }
        }
        flushTextAccumulator()

        let combined = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty {
            return combined
        }

        return msg.text
            .replacingOccurrences(of: "<think>", with: "")
            .replacingOccurrences(of: "</think>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func datasetBadge(_ name: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Dataset")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.25), lineWidth: 0.8)
        )
    }

    @ViewBuilder
    private var privacyGuaranteeBadge: some View {
        if let descriptor = privacyBadgeDescriptor {
            HStack(spacing: 5) {
                Image(systemName: descriptor.iconName)
                    .font(.caption2.weight(.semibold))
                Text(descriptor.title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(descriptor.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(descriptor.tint.opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay(Capsule().stroke(descriptor.tint.opacity(0.26), lineWidth: 0.8))
            .accessibilityLabel(Text(descriptor.accessibilityLabel))
        }
    }

    @ViewBuilder
    private var evidenceReceiptButton: some View {
        if hasEvidenceReceipt {
            Button {
                showEvidenceSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.caption2.weight(.semibold))
                    Text("Evidence")
                        .font(.caption2.weight(.semibold))
                    Text(verbatim: "\(evidenceItemCount)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.14)))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08)))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.24), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(String.localizedStringWithFormat(NSLocalizedString("%d evidence items", comment: "Accessibility label for evidence receipt count"), evidenceItemCount)))
        } else if isAdvancedMode, shouldNudgeForMissingEvidence {
            Button(action: auditMessage) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.caption2.weight(.semibold))
                    Text("No Evidence")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10)))
                .overlay(Capsule().stroke(Color.orange.opacity(0.26), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Audit Evidence"))
        } else if isAdvancedMode, shouldShowModelOnlyUncertainty {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.shield")
                    .font(.caption2.weight(.semibold))
                Text("Model Only")
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.secondary.opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.22), lineWidth: 0.8))
            .accessibilityLabel(Text("Model-only answer. No sources were attached."))
        }
    }

    /// Generation-speed details shown only in Advanced mode: token count,
    /// throughput and time-to-first-token, presented inline with the timestamp
    /// as one quiet metadata line.
    private var perfParts: [String] {
        guard isAdvancedMode, showGenerationDiagnostics, msg.role != "🧑‍💻", !msg.streaming, let perf = msg.perf else { return [] }
        var out: [String] = []
        if perf.tokenCount > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%lld tokens"), Int64(perf.tokenCount)))
        }
        if perf.avgTokPerSec > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%.1f tok/s"), perf.avgTokPerSec))
        }
        if perf.timeToFirst > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%.2fs TFT"), perf.timeToFirst))
        }
        if perf.totalDuration > 0 {
            out.append(String.localizedStringWithFormat(String(localized: "%.2fs total"), perf.totalDuration))
        }
        return out
    }

    /// Single low-contrast footer line: timestamp, plus generation stats when
    /// diagnostics are enabled.
    private var messageMetadataRow: some View {
        HStack(spacing: 6) {
            Text(msg.timestamp, style: .time)
            ForEach(perfParts, id: \.self) { part in
                Text(verbatim: "·")
                Text(part)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .padding(msg.role == "🧑‍💻" ? .trailing : .leading, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var messageReceiptBadges: some View {
        if hasReceiptBadges {
            HStack(spacing: 6) {
                privacyGuaranteeBadge
                evidenceReceiptButton
            }
            .padding(msg.role == "🧑‍💻" ? .trailing : .leading, 12)
            .frame(maxWidth: .infinity, alignment: msg.role == "🧑‍💻" ? .trailing : .leading)
        }
    }

#if os(visionOS)
    private func pinMessage() {
        guard let sessionID = vm.activeSessionID else { return }
        let note = pinnedStore.pin(message: msg, in: sessionID)
        openWindow(id: VisionSceneID.pinnedCardWindow, value: note.id)
    }
#endif
    
    @ViewBuilder
    private func bubbleView(
        _ pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if msg.role == "🧑‍💻", let datasetName = datasetDisplayName {
                datasetBadge(datasetName)
            }

            if msg.role != "🧑‍💻", let ragInfo = msg.ragInjectionInfo {
                RAGDecisionBox(info: ragInfo)
                    .padding(.bottom, 4)
            }

            if !pieces.isEmpty
                || (msg.toolCalls?.isEmpty == false)
                || msg.shouldShowPromptProcessingCard
                || msg.shouldShowGenericLoadingIndicator
                || msg.postToolWaiting {
                piecesView(pieces)
            }
        }
        .padding(.horizontal, messageHorizontalPadding)
        .padding(.vertical, messageVerticalPadding)
        .frame(
            // Cap the user bubble so it reads as a chat bubble, not a banner.
            maxWidth: isUserMessage
                ? min(currentDeviceWidth() * 0.85, ChatTheme.userBubbleMaxWidth)
                : .infinity,
            alignment: isUserMessage ? .trailing : .leading
        )
        .background {
            if isUserMessage {
                RoundedRectangle(cornerRadius: ChatTheme.bubbleRadius, style: .continuous)
                    .fill(bubbleColor)
            }
        }
        .clipShape(
            RoundedRectangle(
                cornerRadius: isUserMessage ? ChatTheme.bubbleRadius : 0,
                style: .continuous
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: UIConstants.cornerRadius)
                .stroke(Color.accentColor.opacity(isSpotlighted ? 0.9 : 0), lineWidth: isSpotlighted ? 3 : 0)
        )
#if os(macOS)
        .textSelection(.enabled)
#endif
        .animation(.easeInOut(duration: 0.2), value: isSpotlighted)
    }

    @ViewBuilder
    private func messageContainer(
        pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        messageContainerBody(
            pieces: pieces,
            hasWebRetrieveCall: hasWebRetrieveCall,
            isSpotlighted: isSpotlighted
        )
#if os(macOS)
        .textSelection(.enabled)
#endif
    }

    private func messageContainerBody(
        pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        VStack(alignment: msg.role == "🧑‍💻" ? .trailing : .leading, spacing: 2) {
            if let paths = msg.imagePaths, !paths.isEmpty {
                imagesView(paths: paths)
            }
            if let mediaAttachments = msg.mediaAttachments, !mediaAttachments.isEmpty {
                mediaAttachmentsView(mediaAttachments)
            }

            HStack {
                if msg.role == "🧑‍💻" { Spacer() }

                bubbleView(pieces, hasWebRetrieveCall: hasWebRetrieveCall, isSpotlighted: isSpotlighted)

                if msg.role != "🧑‍💻" { Spacer() }
            }


            messageMetadataRow

            if msg.isBookmarked {
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                        .font(.caption2)
                    Text(LocalizedStringKey("Bookmarked"))
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(Color.accentColor)
                .padding(msg.role == "🧑‍💻" ? .trailing : .leading, 12)
                .accessibilityElement(children: .combine)
            }

            messageReceiptBadges
        }
        .macWindowDragDisabled()
#if os(macOS)
        .environment(\.messageHoverCopySuppression, $suppressHoverCopy)
#endif
    }

    @ViewBuilder
    private func popupContainer(
        pieces: [ChatVM.Piece],
        hasWebRetrieveCall: Bool,
        isSpotlighted: Bool
    ) -> some View {
        HStack {
            if msg.role == "🧑‍💻" { Spacer() }

            VStack(alignment: .leading, spacing: 12) {
                messageContainer(
                    pieces: pieces,
                    hasWebRetrieveCall: hasWebRetrieveCall,
                    isSpotlighted: isSpotlighted
                )
                .allowsHitTesting(false)
                .scaleEffect(1.02)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button(action: { copyMessageToPasteboard() }) {
                            Label(copiedMessage ? "Copied!" : "Copy", systemImage: copiedMessage ? "checkmark" : "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.accentColor.opacity(0.15))
                                .foregroundColor(.accentColor)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: toggleMessageBookmark) {
                            Label(
                                msg.isBookmarked ? LocalizedStringKey("Remove Bookmark") : LocalizedStringKey("Bookmark Message"),
                                systemImage: msg.isBookmarked ? "bookmark.slash" : "bookmark"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: pinMessageToScratchpad) {
                            Label(
                                pinnedToScratchpad ? LocalizedStringKey("Pinned to Scratchpad") : LocalizedStringKey("Pin to Scratchpad"),
                                systemImage: pinnedToScratchpad ? "checkmark" : "note.text.badge.plus"
                            )
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: branchFromMessage) {
                            Label("Branch", systemImage: "arrow.triangle.branch")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.12))
                                .foregroundColor(.primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        if canRegenerateMessage {
                            Button(action: regenerateMessage) {
                                Label("Regenerate", systemImage: "arrow.clockwise")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        if canAuditMessage {
                            Button(action: auditMessage) {
                                Label("Audit", systemImage: "checkmark.shield")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }

                        if canAskWithAnotherModel {
                            Button(action: askWithAnotherModel) {
                                Label("Try Model", systemImage: "rectangle.2.swap")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.secondary.opacity(0.12))
                                    .foregroundColor(.primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 12)
            .overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showCopyPopup = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: currentDeviceWidth() * 0.9)
            
            if msg.role != "🧑‍💻" { Spacer() }
        }
        .padding(.horizontal, 12)
        .transition(.scale.combined(with: .opacity))
    }
    
    var body: some View {
        let pieces = parse(msg.text, toolCalls: msg.toolCalls)
        let hasWebRetrieveCall = msg.toolCalls?.contains { $0.toolName == "noema.web.retrieve" } ?? false
        
        let isSpotlighted = vm.spotlightMessageID == msg.id

        ZStack(alignment: .center) {
            messageContainer(
                pieces: pieces,
                hasWebRetrieveCall: hasWebRetrieveCall,
                isSpotlighted: isSpotlighted
            )
            .opacity(showCopyPopup ? 0.25 : 1)
            .allowsHitTesting(!showCopyPopup)

            if showCopyPopup {
                ZStack {
                    Color.black.opacity(0.001)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showCopyPopup = false
                            }
                        }
                    
                    popupContainer(
                        pieces: pieces,
                        hasWebRetrieveCall: hasWebRetrieveCall,
                        isSpotlighted: isSpotlighted
                    )
                }
                .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: msg.role == "🧑‍💻" ? .trailing : .leading)
#if os(iOS)
        .onLongPressGesture(minimumDuration: 0.45) {
            copiedMessage = false
            performMediumImpact()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                showCopyPopup = true
            }
        }
#endif
#if os(macOS)
        .overlay(alignment: .bottomTrailing) {
            if hoverCopyVisible && !showCopyPopup && !suppressHoverCopy {
                HStack(spacing: 0) {
                    // Copy — shows label for feedback clarity
                    Button(action: copyMessageToPasteboard) {
                        HStack(spacing: 5) {
                            Image(systemName: copiedMessage ? "checkmark" : "doc.on.doc")
                            Text(copiedMessage ? "Copied" : "Copy")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(copiedMessage ? Color.green : Color.primary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy message")

                    Color.primary.opacity(0.1).frame(width: 1, height: 16)

                    Button(action: toggleMessageBookmark) {
                        Image(systemName: msg.isBookmarked ? "bookmark.fill" : "bookmark")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(msg.isBookmarked ? Color.primary.opacity(0.85) : Color.primary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(msg.isBookmarked ? "Remove Bookmark" : "Bookmark")
                    .accessibilityLabel(msg.isBookmarked ? "Remove Bookmark" : "Bookmark Message")

                    Button(action: pinMessageToScratchpad) {
                        Image(systemName: pinnedToScratchpad ? "checkmark" : "note.text.badge.plus")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(pinnedToScratchpad ? Color.primary.opacity(0.85) : Color.primary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(pinnedToScratchpad ? "Pinned to Scratchpad" : "Pin to Scratchpad")
                    .accessibilityLabel(pinnedToScratchpad ? "Pinned to Scratchpad" : "Pin to Scratchpad")

                    Button(action: branchFromMessage) {
                        Image(systemName: "arrow.triangle.branch")
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color.primary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Branch Conversation")
                    .accessibilityLabel("Branch Conversation")

                    if canRegenerateMessage {
                        Color.primary.opacity(0.1).frame(width: 1, height: 16)
                        Button(action: regenerateMessage) {
                            Image(systemName: "arrow.clockwise")
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Regenerate Response")
                        .accessibilityLabel("Regenerate Response")
                    }

                    if canAuditMessage {
                        Button(action: auditMessage) {
                            Image(systemName: "checkmark.shield")
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Audit Answer")
                        .accessibilityLabel("Audit Answer")
                    }

                    if canAskWithAnotherModel {
                        Button(action: askWithAnotherModel) {
                            Image(systemName: "rectangle.2.swap")
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                        .help("Ask with Another Model")
                        .accessibilityLabel("Ask with Another Model")
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .fixedSize()
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.regularMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: 2)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.14)) {
                hoverCopyVisible = hovering
            }
            if !hovering {
                suppressHoverCopy = false
            }
        }
#endif
#if os(visionOS)
        .overlay(alignment: msg.role == "🧑‍💻" ? .bottomTrailing : .bottomLeading) {
            if showInteractionOptions && !showCopyPopup {
                HStack(spacing: 10) {
                    Button(action: copyMessageToPasteboard) {
                        Image(systemName: copiedMessage ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy message")

                    Button(action: pinMessage) {
                        Image(systemName: "pin")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pin message")

                    Button(action: pinMessageToScratchpad) {
                        Image(systemName: pinnedToScratchpad ? "checkmark" : "note.text.badge.plus")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(pinnedToScratchpad ? "Pinned to Scratchpad" : "Pin to Scratchpad")

                    Button(action: branchFromMessage) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Branch Conversation")

                    if canRegenerateMessage {
                        Button(action: regenerateMessage) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Regenerate Response")
                    }

                    if canAuditMessage {
                        Button(action: auditMessage) {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Audit Answer")
                    }

                    if canAskWithAnotherModel {
                        Button(action: askWithAnotherModel) {
                            Image(systemName: "rectangle.2.swap")
                                .font(.system(size: 18, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ask with Another Model")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .offset(y: 26)
                .transition(.opacity)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                hoverActive = hovering
                if hovering {
                    showInteractionOptions = true
                } else if !isPressingMessage {
                    showInteractionOptions = false
                }
            }
        }
        .onChangeCompat(of: isPressingMessage) { _, pressing in
            withAnimation(.easeInOut(duration: 0.18)) {
                if pressing {
                    showInteractionOptions = true
                } else if !hoverActive {
                    showInteractionOptions = false
                }
            }
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .updating($isPressingMessage) { current, state, _ in
                    state = current
                }
        )
#endif
        .onChangeCompat(of: showCopyPopup) { _, newValue in
            if !newValue {
                copiedMessage = false
            }
#if os(visionOS)
            if newValue {
                showInteractionOptions = false
            }
#endif
        }
        .onChangeCompat(of: msg.text) { _, _ in
            if showCopyPopup {
                copiedMessage = false
            }
        }
        .onChangeCompat(of: vm.msgs) { _, _ in
            if showCopyPopup {
                showCopyPopup = false
            }
        }
#if os(iOS) || os(visionOS)
        .fullScreenCover(isPresented: Binding(get: { expandedImagePath != nil }, set: { if !$0 { expandedImagePath = nil } })) {
            if let p = expandedImagePath {
                AttachmentPreview(path: p) { expandedImagePath = nil }
            }
        }
#else
        .sheet(isPresented: Binding(get: { expandedImagePath != nil }, set: { if !$0 { expandedImagePath = nil } })) {
            if let p = expandedImagePath {
                AttachmentPreview(path: p) { expandedImagePath = nil }
                    .frame(minWidth: 560, minHeight: 420)
            }
        }
#endif
        .sheet(item: $transcriptReviewAttachment) { attachment in
            TranscriptReviewSheet(
                attachment: attachment,
                allowsEditing: true,
                onSaveEdits: { title, transcriptText in
                    vm.updateMessageMediaTranscript(
                        messageID: msg.id,
                        attachmentID: attachment.id,
                        title: title,
                        transcriptText: transcriptText
                    )
                },
                onQuickAction: { action in
                    copyTranscriptToPasteboard(action.prompt(for: attachment.transcript?.displaySourceName ?? attachment.originalFilename))
                },
                onSaveNewDataset: {
                    saveTranscriptAttachment(attachment)
                },
                onSaveExistingDataset: {
                    existingDatasetSaveAttachment = attachment
                }
            )
        }
        .sheet(item: $existingDatasetSaveAttachment) { attachment in
            TranscriptDatasetPickerSheet(datasets: vm.datasetManager?.datasets ?? []) { dataset in
                saveTranscriptAttachment(attachment, toExistingDataset: dataset)
            }
        }
        .sheet(isPresented: $showEvidenceSheet) {
            MessageEvidenceSheet(message: msg)
        }
#if os(visionOS)
        .contextMenu {
            Button {
                copyMessageToPasteboard()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            Button {
                toggleMessageBookmark()
            } label: {
                Label(msg.isBookmarked ? "Remove Bookmark" : "Bookmark Message", systemImage: msg.isBookmarked ? "bookmark.slash" : "bookmark")
            }
            Button {
                pinMessage()
            } label: {
                Label("Pin", systemImage: "pin")
            }
            Button {
                pinMessageToScratchpad()
            } label: {
                Label("Pin to Scratchpad", systemImage: "note.text.badge.plus")
            }
            Button {
                branchFromMessage()
            } label: {
                Label("Branch", systemImage: "arrow.triangle.branch")
            }
            if canRegenerateMessage {
                Button {
                    regenerateMessage()
                } label: {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
            }
            if canAuditMessage {
                Button {
                    auditMessage()
                } label: {
                    Label("Audit", systemImage: "checkmark.shield")
                }
            }
            if canAskWithAnotherModel {
                Button {
                    askWithAnotherModel()
                } label: {
                    Label("Try Model", systemImage: "rectangle.2.swap")
                }
            }
        }
#endif
    }

    private struct MessageEvidenceSheet: View {
        let message: ChatVM.Msg
        @Environment(\.dismiss) private var dismiss

        private var retrievedChunks: [String] {
            (message.retrievedContext ?? "")
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }

        private var citationCount: Int { message.citations?.count ?? 0 }
        // Exclude the `noema.web.retrieve` call from the tool-call tally; web
        // searches are represented by their results (`webCount`) so the call
        // itself isn't double-counted. Other tool calls each count as one.
        private var toolCount: Int { message.toolCalls?.filter { $0.toolName != "noema.web.retrieve" }.count ?? 0 }
        private var webCount: Int { message.webHits?.count ?? 0 }
        private var imageCount: Int { message.imagePaths?.count ?? 0 }
        private var mediaCount: Int { message.mediaAttachments?.count ?? 0 }

        // RAG surfaces the same chunks as citations, the joined retrievedContext,
        // and the ragInjectionInfo summary. Count them once (as the chunk count)
        // so the total matches the number of retrieved chunks.
        private var ragChunkCount: Int { message.citations?.count ?? retrievedChunks.count }

        private var evidenceItemCount: Int {
            ragChunkCount + toolCount + webCount + imageCount + mediaCount
        }

        var body: some View {
#if os(macOS)
            // macOS sheets collapse a NavigationStack+List to near-zero height;
            // use an explicit header + sized list instead.
            VStack(spacing: 0) {
                HStack {
                    Text("Evidence")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Done") {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                Divider().opacity(0.5)
                List {
                    summarySection
                    retrievalSection
                    citationsSection
                    retrievedContextSection
                    toolCallsSection
                    webResultsSection
                    attachmentsSection
                }
                .listStyle(.inset)
            }
            .frame(minWidth: 520, idealWidth: 600, maxWidth: 680, minHeight: 440, idealHeight: 560, maxHeight: 680)
#else
            NavigationStack {
                List {
                    summarySection
                    retrievalSection
                    citationsSection
                    retrievedContextSection
                    toolCallsSection
                    webResultsSection
                    attachmentsSection
                }
                .navigationTitle(Text("Evidence"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
#endif
        }

        @ViewBuilder
        private var summarySection: some View {
            Section {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    summaryChip(title: "Evidence", value: String(evidenceItemCount), icon: "list.bullet.rectangle")
                    summaryChip(title: "Citations", value: String(citationCount), icon: "quote.bubble")
                    summaryChip(title: "Tool Calls", value: String(toolCount), icon: "wrench.and.screwdriver")
                    summaryChip(title: "Web Results", value: String(webCount), icon: "globe")
                    summaryChip(title: "Attachments", value: String(imageCount + mediaCount), icon: "paperclip")
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Evidence Summary")
            }
        }

        @ViewBuilder
        private var retrievalSection: some View {
            if let info = message.ragInjectionInfo {
                Section {
                    detailRow("Dataset", value: info.datasetName)
                    detailRow("Method", value: retrievalMethodText(info.method))
                    detailRow("Stage", value: retrievalStageText(info.stage))
                    detailRow("Chunks", value: "\(info.injectedChunkCount) / \(info.retrievedChunkCount)")
                    detailRow("Injected Tokens", value: "\(info.injectedContextTokens)")
                    detailRow("Prompt Budget", value: "\(info.contextBudgetTokens)")
                    detailRow("Reserved Response", value: "\(info.reservedResponseTokens)")
                    if !info.decisionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        previewBlock(title: "Decision", text: info.decisionReason)
                    }
                } header: {
                    Text("Retrieval Decision")
                }
            }
        }

        @ViewBuilder
        private var citationsSection: some View {
            if let citations = message.citations, !citations.isEmpty {
                Section {
                    ForEach(Array(citations.enumerated()), id: \.offset) { index, citation in
                        CitationRow(index: index + 1, citation: citation)
                    }
                } header: {
                    Text("Citations")
                }
            }
        }

        @ViewBuilder
        private var retrievedContextSection: some View {
            // RAG surfaces the same chunks as citations, so only show the raw
            // retrieved context when there are no citations — otherwise it just
            // duplicates the Citations section above.
            if (message.citations?.isEmpty ?? true), !retrievedChunks.isEmpty {
                Section {
                    ForEach(Array(retrievedChunks.enumerated()), id: \.offset) { index, chunk in
                        previewBlock(title: "#\(index + 1)", text: chunk)
                    }
                } header: {
                    Text("Retrieved Context")
                }
            }
        }

        @ViewBuilder
        private var toolCallsSection: some View {
            // Web searches are surfaced in their own Web Results section, so drop
            // the `noema.web.retrieve` call here to match the Tool Calls tally.
            let toolCalls = (message.toolCalls ?? []).filter { $0.toolName != "noema.web.retrieve" }
            if !toolCalls.isEmpty {
                Section {
                    ForEach(toolCalls) { tool in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                Image(systemName: tool.iconName)
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text(verbatim: tool.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(verbatim: tool.phase.rawValue.capitalized)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(tool.phase == .failed ? .orange : .secondary)
                            }
                            let entries = ToolCallViewSupport.parameterSummaryEntries(
                                from: tool.requestParams,
                                maxEntries: 3,
                                maxValueLength: 80
                            )
                            if !entries.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Parameters")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    ForEach(entries) { entry in
                                        detailRow(Text(verbatim: entry.key), value: entry.value)
                                    }
                                }
                            }
                            if let error = tool.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                                previewBlock(title: "Error", text: error, tint: .orange)
                            } else if let result = tool.result?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty {
                                previewBlock(title: "Result", text: ToolCallViewSupport.formatRawResult(result))
                            } else {
                                detailRow("Result", value: String(localized: "No result"))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Tool Calls")
                }
            }
        }

        @ViewBuilder
        private var webResultsSection: some View {
            if let webHits = message.webHits, !webHits.isEmpty {
                Section {
                    ForEach(webHits, id: \.id) { hit in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: hit.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            HStack(spacing: 10) {
                                detailPill(title: "Engine", value: hit.engine)
                                detailPill(title: "Score", value: String(format: "%.2f", hit.score))
                            }
                            if !hit.snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text(verbatim: compactPreview(hit.snippet))
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)
                            }
                            if let url = URL(string: hit.url) {
                                Link(destination: url) {
                                    Label("URL", systemImage: "link")
                                        .font(.caption)
                                        .lineLimit(1)
                                }
                            } else {
                                detailRow("URL", value: hit.url)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Web Results")
                }
            }
        }

        @ViewBuilder
        private var attachmentsSection: some View {
            if imageCount > 0 || mediaCount > 0 {
                Section {
                    if let imagePaths = message.imagePaths, !imagePaths.isEmpty {
                        ForEach(Array(imagePaths.enumerated()), id: \.offset) { index, path in
                            HStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Images")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(verbatim: URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "#\(index + 1)" : URL(fileURLWithPath: path).lastPathComponent)
                                        .font(.footnote)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    if let mediaAttachments = message.mediaAttachments, !mediaAttachments.isEmpty {
                        ForEach(mediaAttachments) { attachment in
                            HStack(spacing: 10) {
                                Image(systemName: attachment.kind.iconName)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: attachment.transcript?.displaySourceName ?? attachment.originalFilename)
                                        .font(.footnote.weight(.semibold))
                                        .lineLimit(1)
                                    Text(verbatim: [attachment.kind.title, attachment.mediaDetailLabel].compactMap(\.self).joined(separator: " / "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Attachments")
                }
            }
        }

        private func summaryChip(title: LocalizedStringKey, value: String, icon: String) -> some View {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value)
                        .font(.caption.monospacedDigit().weight(.bold))
                    Text(title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }

        private func detailRow(_ label: LocalizedStringKey, value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }

        private func detailRow(_ label: Text, value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                label
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: value)
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }

        private func detailPill(title: LocalizedStringKey, value: String) -> some View {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.caption2.monospacedDigit().weight(.semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.10)))
        }

        private func previewBlock(title: LocalizedStringKey, text: String, tint: Color = .secondary) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint)
                Text(verbatim: compactPreview(text))
                    .font(.footnote)
                    .foregroundStyle(tint)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func retrievalMethodText(_ method: ChatVM.Msg.RAGInjectionInfo.Method?) -> String {
            switch method {
            case .fullContent:
                return String(localized: "Full Content")
            case .rag:
                return String(localized: "RAG")
            case .none:
                return String(localized: "Unknown")
            }
        }

        private func retrievalStageText(_ stage: ChatVM.Msg.RAGInjectionInfo.Stage) -> String {
            switch stage {
            case .deciding:
                return String(localized: "Deciding")
            case .chosen:
                return String(localized: "Chosen")
            case .injected:
                return String(localized: "Injected")
            }
        }

        private func compactPreview(_ text: String, limit: Int = 420) -> String {
            let cleaned = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard cleaned.count > limit else { return cleaned }
            return String(cleaned.prefix(limit)) + "..."
        }

        /// A single citation in the evidence sheet. Tapping the row toggles
        /// between a compact preview and the full chunk text.
        private struct CitationRow: View {
            let index: Int
            let citation: ChatVM.Msg.Citation
            @State private var expanded = false

            var body: some View {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(verbatim: "#\(index)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.accentColor)
                        Text(verbatim: sourceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let score = citation.score {
                            Text(String(format: "%.2f", score))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: expanded ? citation.text : preview)
                        .font(.footnote)
                        .lineLimit(expanded ? nil : 4)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                }
            }

            private var sourceLabel: String {
                if let source = citation.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty {
                    return source
                }
                return String(localized: "No source")
            }

            private var preview: String {
                let cleaned = citation.text
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                guard cleaned.count > 420 else { return cleaned }
                return String(cleaned.prefix(420)) + "..."
            }
        }
    }

    struct ChatView: View {
        @EnvironmentObject var vm: ChatVM
        @EnvironmentObject var modelManager: AppModelManager
        @EnvironmentObject var datasetManager: DatasetManager
        @EnvironmentObject var tabRouter: TabRouter
        @EnvironmentObject var walkthrough: GuidedWalkthroughManager
        @AppStorage("isAdvancedMode") private var isAdvancedMode = false
    @AppStorage("showGenerationDiagnostics") private var showGenerationDiagnostics = true
#if os(macOS)
        @State private var inputFocused = false
#else
        @FocusState private var inputFocused: Bool
#endif
        @State private var showSidebar = false
        @State private var sessionToDelete: ChatVM.Session?
        @State private var shouldAutoScrollToBottom: Bool = true
        // Suggestion overlay state
        @State private var suggestionTriplet: [String] = ChatSuggestions.nextThree()
        @State private var suggestionsSessionID: UUID?
        @State private var showModelRequiredAlert = false
        @State private var showContextOverflowAlert = false
        @State private var showMemoryPromptBudgetAlert = false
        @State private var showRuntimeInfo = false
        @State private var quickLoadInProgress: LocalModel.ID?
        /// Local draft text for the input box. Using @State instead of @Binding to
        /// vm.prompt means keystrokes do NOT fire ChatVM.objectWillChange, so the
        /// whole message list (including every MessageView / ToolCallView) is never
        /// re-rendered while the user is typing.
        @State private var draftText: String = ""
        @State private var chatRecallQuery = ""
        @State private var showScratchpad = false
        @State private var scratchpadDraft = ""
        @State private var showChatInstructions = false
        @State private var chatInstructionsDraft = ""
        @State private var showChatSnapshot = false
        @State private var showChatExportPack = false
        @State private var showContextPlan = false
#if os(macOS)
        @EnvironmentObject private var macChatChrome: MacChatChromeState
        @State private var advancedSettings = ModelSettings()
        @State private var suppressSidebarSave = false
        /// True while the first send of a fresh chat is gliding the composer
        /// from the centered canvas down to the bottom bar. The actual send is
        /// deferred until this animation finishes — prompt prefill saturates
        /// CPU/GPU and would starve the animation to a few frames otherwise.
        @State private var macComposerHandOff = false
#endif

        private struct BookmarkedMessageReference: Identifiable {
            let session: ChatVM.Session
            let message: ChatVM.Msg

            var id: UUID { message.id }
        }

        private struct ChatRecallResult: Identifiable {
            let session: ChatVM.Session
            let message: ChatVM.Msg
            let score: Int

            var id: String { "\(session.id.uuidString)-\(message.id.uuidString)" }
        }

        private struct ChatSnapshotRow: Identifiable {
            let id = UUID()
            let title: String
            let value: String
        }

        private struct ContextPlanRow: Identifiable {
            let id: UUID
            let roleTitle: String
            let preview: String
            let tokenCount: Int
            let statusKey: String
            let tint: Color
        }

        private var inputFocusBinding: Binding<Bool> {
            Binding(
                get: { inputFocused },
                set: { inputFocused = $0 }
            )
        }
        
        
        private struct ChatInputBox: View {
            @Binding var text: String
            var focus: Binding<Bool>
            @Binding var showModelRequiredAlert: Bool
            let send: () -> Void
            let stop: () -> Void
            let stopAfterParagraph: () -> Void
            let canStop: Bool
            let stopAfterParagraphPending: Bool
            @EnvironmentObject var vm: ChatVM
            @EnvironmentObject var modelManager: AppModelManager
            @EnvironmentObject var tabRouter: TabRouter
            @Environment(\.horizontalSizeClass) private var horizontalSizeClass
            @ObservedObject private var settings = SettingsStore.shared
            @AppStorage("chatStatusBarExpanded") private var statusBarExpanded = false
            @AppStorage("isAdvancedMode") private var isAdvancedMode = false
            @AppStorage("showGenerationDiagnostics") private var showGenerationDiagnostics = true
            @State private var showSmallCtxAlert: Bool = false
            @State private var measuredHeight: CGFloat = 0
            @State private var recentlyAddedImageURL: URL?
            @State private var pendingImageFeedbackTask: Task<Void, Never>?
            @State private var transcriptSaveFeedback: [ChatMediaAttachment.ID: TranscriptSaveFeedback] = [:]
            @State private var transcriptReviewAttachment: ChatMediaAttachment?
            @State private var pendingRemovalAttachment: ChatMediaAttachment?
            @State private var existingDatasetSaveAttachment: ChatMediaAttachment?
            @State private var remoteUploadConfirmationAttachment: ChatMediaAttachment?
#if os(iOS)
            @AppStorage(ChatSendBehavior.storageKey) private var chatSendBehaviorRaw = ChatSendBehavior.defaultValue.rawValue
            @AppStorage("compactChatModeEnabled") private var compactChatModeEnabled = false
#endif
            private struct InputHeightPreferenceKey: PreferenceKey {
                static var defaultValue: CGFloat { 0 }
                static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
            }
            // Keep the input aligned with surrounding buttons; slightly shorter on macOS.
            private var usesCompactComposer: Bool {
#if os(iOS)
                compactChatModeEnabled && horizontalSizeClass == .compact
#else
                false
#endif
            }

            private var controlHeight: CGFloat {
#if os(macOS)
                return 40
#elseif os(iOS)
                return usesCompactComposer ? 42 : 48
#else
                return 48
#endif
            }
            // Let the composer grow up to 2x its base control height, then rely on
            // the text input's internal scrolling for additional lines.
            private var inputMaxHeight: CGFloat {
                controlHeight * 2
            }
            private var inputVerticalPadding: CGFloat {
#if os(macOS)
                return 4
#else
                return usesCompactComposer ? 3 : 4
#endif
            }
            private var inputBottomInset: CGFloat {
#if os(macOS)
                return 4
#else
                return usesCompactComposer ? 1 : 2
#endif
            }
            private var inputOuterVerticalPadding: CGFloat {
#if os(macOS)
                return 8
#else
                return usesCompactComposer ? 1 : 2
#endif
            }

            private var accessoryRowSpacing: CGFloat {
                usesCompactComposer ? 5 : 8
            }

            private var resolvedHeight: CGFloat {
                let minContent = max(controlHeight - (inputOuterVerticalPadding * 2), 0)
                let maxContent = max(inputMaxHeight - (inputOuterVerticalPadding * 2), minContent)
                // Fallback for explicit line breaks so growth still works even if
                // measurement lags during rapid edits.
                let explicitLineCount = max(1, text.replacingOccurrences(of: "\r\n", with: "\n")
                    .split(separator: "\n", omittingEmptySubsequences: false).count)
                let estimatedFromLines = CGFloat(explicitLineCount) * 22 + (inputVerticalPadding * 2) + inputBottomInset
                let measuredOrEstimated = max(measuredHeight, estimatedFromLines)
                let clamped = min(max(measuredOrEstimated, minContent), maxContent)
                return clamped
            }

            private var composerContainerHeight: CGFloat {
                resolvedHeight + (inputOuterVerticalPadding * 2)
            }

            private var composerCornerRadius: CGFloat {
#if os(macOS)
                let expandedRadius: CGFloat = 16
#else
                let expandedRadius = UIConstants.largeCornerRadius
#endif
                return UIConstants.adaptiveComposerCornerRadius(
                    currentHeight: composerContainerHeight,
                    collapsedHeight: controlHeight,
                    expandedHeight: inputMaxHeight,
                    expandedRadius: expandedRadius
                )
            }

            private var measurementText: String {
                text.isEmpty ? "Ask…" : text + " "
            }

            private var hasActiveChatModel: Bool { vm.canAcceptChatInput }

            private var hasText: Bool {
                !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            private struct RuntimeStatus {
                let title: String
                let detail: String
                let icon: String
                let tint: Color
            }

            private struct ContextMeterSnapshot {
                let typedTokens: Int
                let historyTokens: Int
                let retrievalTokens: Int
                let imageTokens: Int
                let reservedResponseTokens: Int
                let usablePromptTokens: Int

                var usedTokens: Int {
                    typedTokens + historyTokens + retrievalTokens + imageTokens
                }

                var fraction: Double {
                    guard usablePromptTokens > 0 else { return 0 }
                    return min(1, Double(usedTokens) / Double(usablePromptTokens))
                }

                var tint: Color {
                    if fraction >= 0.92 { return .red }
                    if fraction >= 0.75 { return .orange }
                    return .green
                }
            }

            private var runtimeStatus: RuntimeStatus {
                if vm.loading || vm.stillLoading {
                    return RuntimeStatus(
                        title: String(localized: "Loading model"),
                        detail: modelManager.loadedModel?.name ?? String(localized: "Preparing runtime"),
                        icon: "hourglass",
                        tint: .orange
                    )
                }

                if let model = resolvedLoadedModel {
                    let format = vm.loadedModelFormat?.displayName ?? model.format.displayName
                    let title = vm.canAcceptChatInput ? String(localized: "Ready") : String(localized: "Model selected")
                    return RuntimeStatus(
                        title: title,
                        detail: "\(model.name) · \(format)",
                        icon: vm.canAcceptChatInput ? "checkmark.circle.fill" : "circle.dashed",
                        tint: vm.canAcceptChatInput ? .green : .gray
                    )
                }

                if vm.canAcceptChatInput {
                    return RuntimeStatus(
                        title: String(localized: "Remote ready"),
                        detail: String(localized: "Connected backend"),
                        icon: "network",
                        tint: .green
                    )
                }

                return RuntimeStatus(
                    title: String(localized: "No model loaded"),
                    detail: String(localized: "Select a model to start chatting."),
                    icon: "exclamationmark.circle",
                    tint: .gray
                )
            }

            private var resolvedLoadedModel: LocalModel? {
                if let model = modelManager.loadedModel {
                    return model
                }
                guard let url = vm.loadedModelURL else { return nil }
                return modelManager.downloadedModels.first { candidate in
                    candidate.url == url || candidate.url.path == url.path
                }
            }

            private var latestRAGInfo: ChatVM.Msg.RAGInjectionInfo? {
                vm.streamMsgs.reversed().first { $0.ragInjectionInfo != nil }?.ragInjectionInfo
            }

            private var contextMeterSnapshot: ContextMeterSnapshot {
                let budget = ChatVM.promptBudget(for: vm.contextLimit)
                let activeMessages = Array(vm.streamMsgs.suffix(10))
                let historyTokens = activeMessages.reduce(0) { total, message in
                    total + estimatedTokenCount(message.text)
                }
                let mediaTranscriptTokens = vm.pendingMediaAttachments.reduce(0) { total, attachment in
                    total + estimatedTokenCount(attachment.transcript?.effectiveTranscriptText ?? "")
                }
                let typedTokens = estimatedTokenCount(text) + mediaTranscriptTokens
                let retrievalTokens = latestRAGInfo?.injectedContextTokens ?? 0
                let imageTokens = vm.pendingImageURLs.count * 576

                return ContextMeterSnapshot(
                    typedTokens: typedTokens,
                    historyTokens: historyTokens,
                    retrievalTokens: retrievalTokens,
                    imageTokens: imageTokens,
                    reservedResponseTokens: budget.reservedResponseTokens,
                    usablePromptTokens: budget.usablePromptTokens
                )
            }

            private var hasCompletedMediaTranscript: Bool {
                vm.pendingMediaAttachments.contains(where: \.hasCompletedTranscript)
            }

            private var canKeyboardSubmit: Bool {
                (hasText || hasCompletedMediaTranscript) && !canStop && !vm.isStreamingInAnotherSession && !(vm.loading || vm.stillLoading)
            }

            private var chatSendBehavior: ChatSendBehavior {
#if os(iOS)
                ChatSendBehavior.from(chatSendBehaviorRaw)
#else
                .defaultValue
#endif
            }

#if canImport(UIKit)
            private var submitConfiguration: MobileBottomAnchoredTextEditor.SubmitConfiguration? {
#if os(iOS)
                MobileBottomAnchoredTextEditor.SubmitConfiguration(
                    behavior: chatSendBehavior,
                    canSubmit: canKeyboardSubmit,
                    onSubmit: triggerSendFromKeyboard
                )
#else
                nil
#endif
            }
#endif

            private var composerAccessibilityHint: LocalizedStringKey {
#if os(iOS)
                LocalizedStringKey(chatSendBehavior.accessibilityHintKey)
#else
                "Double-tap Return to insert a new line. Use the Send button to send."
#endif
            }

            private func triggerSendFromKeyboard() {
                guard canKeyboardSubmit else { return }
                performSend()
            }

            private func performSend() {
                let isChatReady = hasActiveChatModel

                guard isChatReady else {
                    showModelRequiredAlert = true
                    focus.wrappedValue = false
                    return
                }
                guard !vm.isStreamingInAnotherSession else {
                    vm.crossSessionSendBlocked = true
                    focus.wrappedValue = false
                    return
                }
                if UIConstants.showMultimodalUI && vm.supportsImageInput && !vm.pendingImageURLs.isEmpty && vm.contextLimit < 5000 {
                    showSmallCtxAlert = true
                    return
                }
                send()
                text = ""
            }

            /// Extracted so `composerRow` stays type-checkable; macOS uses a clean
            /// filled circle while iOS/visionOS keep the glass pill treatment.
            @ViewBuilder
            private func sendButtonLabel(canSend: Bool) -> some View {
#if os(macOS)
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: controlHeight - 8, height: controlHeight - 8)
                    .background(
                        Circle().fill(
                            canSend
                                ? Color.accentColor
                                : Color.primary.opacity(0.08)
                        )
                    )
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: controlHeight, height: controlHeight)
                    .contentShape(Circle())
#else
                let sendShape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: controlHeight, height: controlHeight)
                    .background(
                        sendShape
                            .fill(Color.clear)
                            .glassifyIfAvailable(in: sendShape)
                            .overlay(
                                sendShape.fill(
                                    canSend
                                        ? Color.accentColor.opacity(0.36)
                                        : Color.white.opacity(0.06)
                                )
                            )
                            .overlay(
                                sendShape.strokeBorder(
                                    canSend
                                        ? Color.accentColor.opacity(0.44)
                                        : Color.white.opacity(0.22),
                                    lineWidth: 0.8
                                )
                            )
                            .shadow(
                                color: canSend ? Color.accentColor.opacity(0.28) : .clear,
                                radius: canSend ? 10 : 0,
                                y: canSend ? 5 : 0
                            )
                    )
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
#endif
            }


            var body: some View {
#if os(macOS)
                macUnifiedInputContainer
#else
                VStack(spacing: accessoryRowSpacing) {
                    statusBarRow
                    composerRow
                }
#endif
            }

#if os(macOS)
            /// One clean composer surface: the input row sits on a single card
            /// and the runtime status collapses into a quiet footer line.
            private var macUnifiedInputContainer: some View {
                VStack(spacing: 0) {
                    composerRow
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 2)
                    statusBarRow
                }
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous)
                        .fill(ChatTheme.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous)
                        .stroke(ChatTheme.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: ChatTheme.composerRadius, style: .continuous))
                .shadow(color: Color.black.opacity(0.04), radius: 10, x: 0, y: 3)
            }
#endif

            @ViewBuilder
            private var statusBarRow: some View {
                if usesCompactComposer {
                    compactComposerStatusRow
                } else {
                    runtimeStatusBar
                }
            }

            private var composerRow: some View {
                HStack(alignment: .center, spacing: 8) {
#if os(macOS)
                    VisionAttachmentButton(
                        showWebSearchOption: false,
                        showPythonOption: false,
                        showPlusIcon: true,
                        onModelRequiredTap: {
                            showModelRequiredAlert = true
                            focus.wrappedValue = false
                        }
                    )
                        .guideHighlight(.chatWebSearch)
                        .frame(width: controlHeight, height: controlHeight)
#endif
#if os(iOS) || os(visionOS)
                    VisionAttachmentButton(
                        showWebSearchOption: false,
                        showPythonOption: false,
                        showPlusIcon: true,
                        onModelRequiredTap: {
                            showModelRequiredAlert = true
                            focus.wrappedValue = false
                        }
                    )
                        .guideHighlight(.chatWebSearch)
                        .frame(width: controlHeight, height: controlHeight)
#endif
                    let isChatReady = hasActiveChatModel
                    let isComposerBusy = vm.loading || vm.stillLoading
                    VStack(spacing: accessoryRowSpacing) {
                        // Images displayed above the text field
                        if UIConstants.showMultimodalUI && vm.supportsImageInput && !vm.pendingImageURLs.isEmpty {
                            pendingImagesTray
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if !vm.pendingMediaAttachments.isEmpty || vm.audioRecordingError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            pendingMediaTray
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        
                        // Input area with vision attachments and multi-line text entry
                        HStack(spacing: 12) {
                            ZStack(alignment: .topLeading) {
#if os(iOS) || os(visionOS)
                                MobileBottomAnchoredTextEditor(
                                    text: $text,
                                    focus: focus,
                                    isDisabled: isComposerBusy,
                                    topInset: inputVerticalPadding,
                                    bottomInset: inputVerticalPadding + inputBottomInset,
                                    font: .preferredFont(forTextStyle: .body),
                                    submitConfiguration: submitConfiguration
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(maxHeight: resolvedHeight, alignment: .topLeading)
                                    .padding(.horizontal, 4)
                                    .disabled(isComposerBusy)
                                    .accessibilityLabel(Text("Message input"))
                                    .accessibilityIdentifier("message-input")
                                    .accessibilityHint(composerAccessibilityHint)

                                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    HStack {
                                        Text("Ask…")
                                            .foregroundColor(.secondary)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.top, inputVerticalPadding)
                                    .padding(.bottom, inputVerticalPadding + inputBottomInset)
                                    .frame(maxWidth: .infinity, maxHeight: resolvedHeight, alignment: .topLeading)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                                }
#else
                                MacAutoScrollingTextEditor(
                                    text: $text,
                                    focus: focus,
                                    isDisabled: isComposerBusy,
                                    topInset: inputVerticalPadding,
                                    bottomInset: inputVerticalPadding + inputBottomInset,
                                    font: .systemFont(ofSize: NSFont.systemFontSize)
                                )
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .frame(maxHeight: resolvedHeight, alignment: .topLeading)
                                    .padding(.horizontal, 4)
                                    .background(Color.clear)
                                    .accessibilityLabel(Text("Message input"))
                                    .accessibilityIdentifier("message-input")
                                    .accessibilityHint("Double-tap Return to insert a new line. Use the Send button to send.")

                                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("Ask…")
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.top, inputVerticalPadding)
                                        .frame(maxWidth: .infinity, maxHeight: resolvedHeight, alignment: .topLeading)
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
#endif
                                // Invisible measurement text keeps the control compact until content grows.
                                Text(measurementText)
                                    .font(.body)
                                    .lineLimit(nil)
                                    .padding(.horizontal, 4)
                                    .padding(.top, inputVerticalPadding)
                                    .padding(.bottom, inputVerticalPadding + inputBottomInset)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .background(
                                        GeometryReader { proxy in
                                            Color.clear.preference(key: InputHeightPreferenceKey.self, value: proxy.size.height)
                                        }
                                    )
                                    .hidden()
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)

                            }
                            .onPreferenceChange(InputHeightPreferenceKey.self) { measuredHeight = $0 }
                            .padding(.horizontal, 10)
                            .padding(.vertical, inputOuterVerticalPadding)
                            .frame(minHeight: controlHeight,
                                   maxHeight: inputMaxHeight,
                                   alignment: .topLeading)
                            .frame(height: composerContainerHeight, alignment: .topLeading)
                            .clipShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                            // macOS gets no inner stroke or glass — the editor sits
                            // flush on the single composer card instead of nesting
                            // surfaces.
#if !os(macOS)
                            .glassPill(cornerRadius: composerCornerRadius)
#endif
                            .frame(maxWidth: .infinity)
#if os(iOS) || os(visionOS)
                            .overlay {
                                if !isChatReady {
                                    RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous)
                                        .fill(Color.clear)
                                        .contentShape(RoundedRectangle(cornerRadius: composerCornerRadius, style: .continuous))
                                        .onTapGesture {
                                            showModelRequiredAlert = true
                                            focus.wrappedValue = false
                                        }
                                }
                            }
#endif

#if canImport(AVFoundation)
                            voiceRecordButton(isDisabled: isComposerBusy)
#endif
                        }
                    }
                    // Value-scoped: only fires when attachments are added/removed,
                    // so typing never re-animates the row (see note below the HStack).
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.pendingImageURLs.count)
                    .animation(.spring(response: 0.4, dampingFraction: 0.85), value: vm.pendingMediaAttachments.count)
                    if canStop {
                        Button(action: stop) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: controlHeight, height: controlHeight)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.red)
                                )
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain) // Avoid default gray button chrome behind the custom red pill
                        .accessibilityLabel(Text("Stop generating"))
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    } else {
                        let canSend = isChatReady
                            && !isComposerBusy
                            && !vm.isStreamingInAnotherSession
                            && (hasText || hasCompletedMediaTranscript)
                        Button(action: {
                            performSend()
                        }) {
                            sendButtonLabel(canSend: canSend)
                        }
                        .accessibilityIdentifier("chat-send-button")
                        .buttonStyle(.plain)
                        .disabled((!hasText && !hasCompletedMediaTranscript) || vm.isStreamingInAnotherSession || isComposerBusy)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                // Avoid animating the entire input row on every keystroke,
                // which caused attachment thumbnails to flicker.
                // The animations below are value-scoped to the send/stop swap only;
                // keystrokes don't change `canStop`, so they can't re-trigger it.
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: canStop)
                .alert("Finish current response", isPresented: Binding(
                    get: { vm.crossSessionSendBlocked },
                    set: { vm.crossSessionSendBlocked = $0 }
                )) {
                    Button("OK", role: .cancel) { vm.crossSessionSendBlocked = false }
                } message: {
                    Text("Wait for the response in your other chat to finish before sending a new message.")
                }
                .alert("Small context may cause image crash", isPresented: $showSmallCtxAlert) {
                    Button("Send Anyway") {
                        send()
                        text = ""
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Context length is under 5000 tokens. With images and multi-sequence decoding (n_seq_max=16), per-sequence memory can be too small, leading to a crash. Increase context to at least 8192 in Model Settings.")
                }
                .alert("Load a model to chat", isPresented: $showModelRequiredAlert) {
                    Button(LocalizedStringKey("Open Stored")) {
                        tabRouter.selection = .stored
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(LocalizedStringKey("Open Stored to choose a model to run locally or connect to a remote endpoint."))
                }
                .confirmationDialog(
                    Text(LocalizedStringKey("Remove unsaved transcript?")),
                    isPresented: Binding(
                        get: { pendingRemovalAttachment != nil },
                        set: { if !$0 { pendingRemovalAttachment = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(LocalizedStringKey("Remove"), role: .destructive) {
                        if let attachment = pendingRemovalAttachment {
                            vm.removePendingMediaAttachment(id: attachment.id)
                        }
                        pendingRemovalAttachment = nil
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) {
                        pendingRemovalAttachment = nil
                    }
                } message: {
                    Text(LocalizedStringKey("This transcript has not been sent or saved yet."))
                }
                .confirmationDialog(
                    Text(LocalizedStringKey("Upload media for remote transcription?")),
                    isPresented: Binding(
                        get: { remoteUploadConfirmationAttachment != nil },
                        set: { if !$0 { remoteUploadConfirmationAttachment = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(LocalizedStringKey("Upload and Transcribe")) {
                        if let attachment = remoteUploadConfirmationAttachment {
                            TranscriptionSettings.confirmRemoteUpload()
                            vm.beginTranscribingPendingMediaAttachment(id: attachment.id)
                        }
                        remoteUploadConfirmationAttachment = nil
                    }
                    Button(LocalizedStringKey("Cancel"), role: .cancel) {
                        remoteUploadConfirmationAttachment = nil
                    }
                } message: {
                    Text(LocalizedStringKey("Remote ASR sends the selected media to your configured audio-language endpoint. Use it only with endpoints you trust."))
                }
                .sheet(item: $transcriptReviewAttachment) { attachment in
                    TranscriptReviewSheet(
                        attachment: latestPendingAttachment(matching: attachment) ?? attachment,
                        allowsEditing: true,
                        onSaveEdits: { title, transcriptText in
                            vm.updatePendingMediaTranscript(id: attachment.id, title: title, transcriptText: transcriptText)
                        },
                        onQuickAction: { action in
                            performTranscriptQuickAction(action, for: latestPendingAttachment(matching: attachment) ?? attachment)
                        },
                        onSaveNewDataset: {
                            if let latest = latestPendingAttachment(matching: attachment) {
                                saveTranscriptAttachment(latest)
                            }
                        },
                        onSaveExistingDataset: {
                            existingDatasetSaveAttachment = latestPendingAttachment(matching: attachment) ?? attachment
                        }
                    )
                }
                .sheet(item: $existingDatasetSaveAttachment) { attachment in
                    TranscriptDatasetPickerSheet(datasets: vm.datasetManager?.datasets ?? []) { dataset in
                        if let latest = latestPendingAttachment(matching: attachment) {
                            saveTranscriptAttachment(latest, toExistingDataset: dataset)
                        } else {
                            saveTranscriptAttachment(attachment, toExistingDataset: dataset)
                        }
                    }
                }
                .onChangeCompat(of: vm.pendingImageURLs) { oldURLs, newURLs in
                    handlePendingImagesChange(from: oldURLs, to: newURLs)
                }
                .onDisappear {
                    pendingImageFeedbackTask?.cancel()
                }
            }

            private var statusModelName: String? {
                if let remote = modelManager.activeRemoteSession {
                    return remote.modelName
                }
                if let model = resolvedLoadedModel {
                    return model.name
                }
                return nil
            }

            /// Collapsible "Ready · Model" status box shown directly above the composer.
            /// Mirrors the input bar's liquid-glass treatment so it stays legible against
            /// the bottom gradient, and tucks the tool/context detail away until expanded.
            /// On macOS this renders as a quiet single-line footer inside the composer card.
            private var statusTitleFont: Font {
#if os(macOS)
                .caption2.weight(.medium)
#else
                .caption.weight(.semibold)
#endif
            }

            private var statusDetailFont: Font {
#if os(macOS)
                .caption2
#else
                .caption
#endif
            }

            private var statusRowVerticalPadding: CGFloat {
#if os(macOS)
                7
#else
                9
#endif
            }

            private var runtimeStatusBar: some View {
                let status = runtimeStatus
                let snapshot = contextMeterSnapshot
                let showsBudget = snapshot.usablePromptTokens > 0 && vm.modelLoaded
                return VStack(spacing: 0) {
                    Button {
                        // No withAnimation here: statusBarExpanded is @AppStorage, whose
                        // update can land outside the transaction. The scoped
                        // .animation(value:) on the container drives the animation instead.
                        statusBarExpanded.toggle()
                    } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(status.tint)
                                .frame(width: 7, height: 7)
                            Text(verbatim: status.title)
                                .font(statusTitleFont)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                            if let name = statusModelName {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.35))
                                    .frame(width: 1, height: 11)
                                Text(verbatim: name)
                                    .font(statusDetailFont)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 6)
                            if showsBudget {
                                Text(verbatim: "\(Self.shortTokenLabel(snapshot.usedTokens)) / \(Self.shortTokenLabel(snapshot.usablePromptTokens))")
                                    .font(statusDetailFont.monospacedDigit())
                                    .foregroundStyle(snapshot.tint.opacity(0.85))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(statusBarExpanded ? 180 : 0))
                                // Slightly bouncier than the container so the chevron
                                // feels like it leads the expansion.
                                .animation(.spring(response: 0.35, dampingFraction: 0.65), value: statusBarExpanded)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, statusRowVerticalPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(localized: "Runtime status: %@, %@"), status.title, status.detail)))
                    .accessibilityHint(Text(statusBarExpanded
                        ? String(localized: "Collapse tool and context details")
                        : String(localized: "Expand tool and context details")))

                    if statusBarExpanded {
                        VStack(alignment: .leading, spacing: 12) {
                            Divider().opacity(0.4)
                            toolsSection
                            contextBudgetMeter
                        }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .move(edge: .top))
                                    .combined(with: .scale(scale: 0.96, anchor: .top)),
                                removal: .opacity
                                    .combined(with: .move(edge: .top))
                                    .combined(with: .scale(scale: 0.97, anchor: .top))
                                    .animation(.spring(response: 0.32, dampingFraction: 0.9))
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity)
#if !os(macOS)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .glassPill(cornerRadius: 20)
#endif
                // Animate as one coherent unit so labels don't jitter mid-resize, and
                // bind the animation to the value itself — @AppStorage changes don't
                // reliably animate via withAnimation alone.
                .geometryGroup()
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: statusBarExpanded)
            }

            private var runtimeStatusPill: some View {
                let status = runtimeStatus
                return HStack(spacing: 7) {
                    Image(systemName: status.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(status.tint)
                    Text(verbatim: status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(verbatim: status.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Capsule(style: .continuous)
                        .fill(status.tint.opacity(0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(status.tint.opacity(0.20), lineWidth: 0.8)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String.localizedStringWithFormat(String(localized: "Runtime status: %@, %@"), status.title, status.detail)))
            }

            private var compactComposerStatusRow: some View {
                let snapshot = contextMeterSnapshot
                let percent = Int((snapshot.fraction * 100).rounded())
                let usedTokens = snapshot.usedTokens
                let usableTokens = max(0, snapshot.usablePromptTokens)
                let showTokenCounts = isAdvancedMode && showGenerationDiagnostics
                let showContextGauge = vm.modelLoaded
                let isAFM = vm.loadedModelFormat == .afm
                return HStack(spacing: 6) {
                    runtimeStatusPill
                        .layoutPriority(1)
                    if !isAFM {
                    Menu {
                        toolPermissionMenuItems
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "wrench.and.screwdriver")
                                .font(.system(size: 11, weight: .semibold))
                            Text(verbatim: "\(vm.activeToolPermissions.enabledCount)/4")
                                .font(.caption2.monospacedDigit().weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String.localizedStringWithFormat(
                        String(localized: "Chat tools: %d of 4 allowed"),
                        vm.activeToolPermissions.enabledCount
                    )))
                    } // if !isAFM

                    if showContextGauge {
                        HStack(spacing: 4) {
                            Image(systemName: "gauge.with.dots.needle.50percent")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(snapshot.tint)
                            if showTokenCounts {
                                Text(verbatim: "\(usedTokens)/\(usableTokens)")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                            } else {
                                Text(verbatim: "\(percent)%")
                                    .font(.caption2.monospacedDigit().weight(.semibold))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(snapshot.tint.opacity(0.10)))
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(snapshot.tint.opacity(0.18), lineWidth: 0.7)
                        )
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "Context used: %lld of %lld tokens (%d%%)"),
                            Int64(usedTokens), Int64(usableTokens), percent
                        )))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            @ViewBuilder
            private var toolPermissionMenuItems: some View {
                let isAFM = vm.loadedModelFormat == .afm
                if !isAFM {
                    Toggle(isOn: toolPermissionBinding(.webSearch)) {
                        Label(LocalizedStringKey("Web Search"), systemImage: "globe")
                    }
                    .disabled(!settings.webSearchEnabled)

                    Toggle(isOn: toolPermissionBinding(.python)) {
                        Label(LocalizedStringKey("Python"), systemImage: "terminal")
                    }
                    .disabled(!settings.pythonEnabled || !PythonRuntime.status().isAvailable)

                    Toggle(isOn: toolPermissionBinding(.memory)) {
                        Label(LocalizedStringKey("Memory"), systemImage: "brain")
                    }
                    .disabled(!settings.memoryEnabled)
                }

                Toggle(isOn: toolPermissionBinding(.datasetRetrieval)) {
                    Label(LocalizedStringKey("Dataset Retrieval"), systemImage: "doc.text.magnifyingglass")
                }

                Divider()

                Button {
                    vm.setAllToolPermissionsForActiveSession(enabled: true)
                } label: {
                    Label(LocalizedStringKey("Allow All Tools"), systemImage: "checkmark.circle")
                }

                Button {
                    vm.setAllToolPermissionsForActiveSession(enabled: false)
                } label: {
                    Label(LocalizedStringKey("Block Chat Tools"), systemImage: "slash.circle")
                }
            }

            private var toolsSection: some View {
                let isAFM = vm.loadedModelFormat == .afm
                let permissions = vm.activeToolPermissions
                let webAvailable = !isAFM && settings.webSearchEnabled
                let pythonAvailable = !isAFM && settings.pythonEnabled && PythonRuntime.status().isAvailable
                let memoryAvailable = !isAFM && settings.memoryEnabled
                let ragAvailable = vm.activeSessionDataset?.isIndexed == true

                // A tool counts as "on" only when it is both selected and currently usable.
                // AFM suppresses web/python/memory entirely — only RAG context injection remains.
                let webOn = settings.webSearchArmed && webAvailable
                let pythonOn = settings.pythonArmed && pythonAvailable
                let memoryOn = permissions.memory && memoryAvailable
                let ragOn = permissions.datasetRetrieval && ragAvailable
                let activeCount = [webOn, pythonOn, memoryOn, ragOn].filter { $0 }.count

                return VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(LocalizedStringKey("Tools"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        Text(String.localizedStringWithFormat(
                            String(localized: "%d of 4 on"),
                            activeCount
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        // Always show all chips; for AFM the web/python/memory chips are grayed out
                        // (available=false) rather than hidden so users can see they exist.
                        toolToggleChip(title: String(localized: "Web"), systemImage: "globe",
                                       isOn: settings.webSearchArmed, available: webAvailable) {
                            let newValue = !settings.webSearchArmed
                            settings.webSearchArmed = newValue
                            vm.setToolPermissionForActiveSession(.webSearch, enabled: newValue)
                        }
                        toolToggleChip(title: String(localized: "Python"), systemImage: "terminal",
                                       isOn: settings.pythonArmed, available: pythonAvailable) {
                            let newValue = !settings.pythonArmed
                            settings.pythonArmed = newValue
                            vm.setToolPermissionForActiveSession(.python, enabled: newValue)
                        }
                        toolToggleChip(title: String(localized: "Memory"), systemImage: "brain",
                                       isOn: permissions.memory, available: memoryAvailable) {
                            vm.setToolPermissionForActiveSession(.memory, enabled: !permissions.memory)
                        }
                        toolToggleChip(title: String(localized: "RAG"), systemImage: "doc.text.magnifyingglass",
                                       isOn: permissions.datasetRetrieval, available: ragAvailable) {
                            vm.setToolPermissionForActiveSession(.datasetRetrieval, enabled: !permissions.datasetRetrieval)
                        }
                    }
                    if isAFM {
                        Text(LocalizedStringKey("Web search, Python, and Memory are not available with Apple Foundation Models."))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            private func toolToggleChip(
                title: String,
                systemImage: String,
                isOn: Bool,
                available: Bool,
                toggle: @escaping () -> Void
            ) -> some View {
                let enabled = isOn && available
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
                return Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        toggle()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: systemImage)
                            .font(.system(size: 14, weight: .semibold))
                        Text(verbatim: title)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                    .background(shape.fill(enabled ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08)))
                    .overlay(shape.stroke(enabled ? Color.accentColor.opacity(0.30) : Color.secondary.opacity(0.12), lineWidth: 0.8))
                    .opacity(available ? 1 : 0.5)
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .accessibilityLabel(Text(title))
                .accessibilityAddTraits(enabled ? .isSelected : [])
            }

            private func toolPermissionBinding(_ kind: ChatVM.ChatToolPermissionKind) -> Binding<Bool> {
                Binding(
                    get: {
                        let permissions = vm.activeToolPermissions
                        switch kind {
                        case .webSearch: return permissions.webSearch
                        case .python: return permissions.python
                        case .memory: return permissions.memory
                        case .datasetRetrieval: return permissions.datasetRetrieval
                        }
                    },
                    set: { enabled in
                        vm.setToolPermissionForActiveSession(kind, enabled: enabled)
                    }
                )
            }

            private var contextBudgetMeter: some View {
                let snapshot = contextMeterSnapshot
                return VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(snapshot.tint)
                        Text(LocalizedStringKey("Context"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        Text(
                            String.localizedStringWithFormat(
                                String(localized: "%@ / %@ used"),
                                Self.shortTokenLabel(snapshot.usedTokens),
                                Self.shortTokenLabel(snapshot.usablePromptTokens)
                            )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.secondary.opacity(0.16))
                            Capsule(style: .continuous)
                                .fill(snapshot.tint.opacity(0.72))
                                .frame(width: max(4, proxy.size.width * snapshot.fraction))
                        }
                    }
                    .frame(height: 5)

                    HStack(spacing: 8) {
                        contextMeterChip(title: String(localized: "History"), value: snapshot.historyTokens)
                        contextMeterChip(title: String(localized: "Retrieval"), value: snapshot.retrievalTokens)
                        contextMeterChip(title: String(localized: "Images"), value: snapshot.imageTokens)
                        contextMeterChip(title: String(localized: "Reserve"), value: snapshot.reservedResponseTokens)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(String.localizedStringWithFormat(
                    String(localized: "Context budget: %@ of %@ used"),
                    Self.shortTokenLabel(snapshot.usedTokens),
                    Self.shortTokenLabel(snapshot.usablePromptTokens)
                )))
            }

            private func contextMeterChip(title: String, value: Int) -> some View {
                HStack(spacing: 3) {
                    Text(verbatim: title)
                        .font(.system(size: 9, weight: .semibold))
                    Text(verbatim: Self.shortTokenLabel(value))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            }

            private func estimatedTokenCount(_ value: String) -> Int {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return 0 }
                let wordEstimate = trimmed.split { $0.isWhitespace || $0.isNewline }.count
                let charEstimate = Int(ceil(Double(trimmed.count) / 4.0))
                return max(1, max(wordEstimate, charEstimate))
            }

            private static func shortTokenLabel(_ value: Int) -> String {
                if value >= 10_000 {
                    return String(format: "%.1fk", Double(value) / 1000.0)
                }
                if value >= 1_000 {
                    return String(format: "%.1fk", Double(value) / 1000.0)
                }
                return "\(value)"
            }

            private var pendingImagesWithIndices: [(index: Int, url: URL)] {
                Array(vm.pendingImageURLs.prefix(5).enumerated()).map { (index: $0.offset, url: $0.element) }
            }

            /// Compact attachment tray: one quiet surface, tight rows, no
            /// oversized glass card.
            private var pendingMediaTray: some View {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if let error = vm.audioRecordingError, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            audioRecordingErrorRow(error)
                            if !vm.pendingMediaAttachments.isEmpty {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                        }
                        ForEach(Array(vm.pendingMediaAttachments.enumerated()), id: \.element.id) { index, attachment in
                            pendingMediaRow(attachment)
                            if index < vm.pendingMediaAttachments.count - 1 {
                                Divider()
                                    .padding(.vertical, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 220)
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous)
                        .fill(ChatTheme.cardSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous)
                                .strokeBorder(ChatTheme.hairline, lineWidth: 1)
                        )
                )
                .clipShape(RoundedRectangle(cornerRadius: ChatTheme.controlRadius, style: .continuous))
            }

#if canImport(AVFoundation)
            private func voiceRecordButton(isDisabled: Bool) -> some View {
                let isRecording = vm.isRecordingAudio
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

                return Button {
                    Task { await vm.toggleAudioRecording() }
                } label: {
                    ZStack {
                        Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 17, weight: .semibold))
                        if isRecording {
                            VStack {
                                Spacer()
                                recordingLevelBars
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                    .frame(width: controlHeight, height: controlHeight)
                    .background(
                        shape
                            .fill(Color.clear)
                            .glassifyIfAvailable(in: shape)
                            .overlay(
                                shape.fill(
                                    isRecording
                                        ? Color.red.opacity(0.34)
                                        : Color.white.opacity(0.06)
                                )
                            )
                            .overlay(
                                shape.strokeBorder(
                                    isRecording
                                        ? Color.red.opacity(0.52)
                                        : Color.white.opacity(0.22),
                                    lineWidth: 0.8
                                )
                            )
                    )
                    .foregroundStyle(isRecording ? Color.white : Color.secondary)
                    .overlay(alignment: .top) {
                        if isRecording, let started = vm.audioRecordingStartedAt {
                            TimelineView(.periodic(from: started, by: 1)) { context in
                                Text(Self.recordingElapsedLabel(from: started, to: context.date))
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(Color.red.opacity(0.7))
                                    )
                                    .offset(y: -8)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .accessibilityLabel(Text(LocalizedStringKey(isRecording ? "Stop Recording" : "Record Audio")))
                .accessibilityHint(Text(LocalizedStringKey("Record a voice note for transcription.")))
            }

            private var recordingLevelBars: some View {
                HStack(spacing: 2) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.78))
                            .frame(width: 3, height: max(3, CGFloat(vm.audioRecordingLevel) * CGFloat(index + 2) * 4))
                    }
                }
                .frame(height: 18, alignment: .bottom)
                .accessibilityHidden(true)
            }

            private static func recordingElapsedLabel(from start: Date, to now: Date) -> String {
                let elapsed = max(0, Int(now.timeIntervalSince(start)))
                return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            }
#endif

            private func audioRecordingErrorRow(_ message: String) -> some View {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white, Color.red)
                            .frame(width: 28, height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.red.opacity(0.10))
                            )

                        Text(message)
                            .font(.caption)
                            .foregroundStyle(Color.red)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            vm.audioRecordingError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Circle().fill(Color.primary.opacity(0.06)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(LocalizedStringKey("Dismiss")))
                    }

                    recoveryActionsRow(message: message, attachment: nil)
                }
            }

            private func pendingMediaRow(_ attachment: ChatMediaAttachment) -> some View {
                VStack(alignment: .leading, spacing: 8) {
                    mediaHeader(for: attachment)

                    // "Ready to transcribe" is implied by the Transcribe button;
                    // only surface standalone status text when something is wrong.
                    if attachment.status == .failed, attachment.status.showsStandaloneStatusLabel {
                        Text(mediaStatusText(attachment))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if attachment.status == .transcribing,
                       let partial = attachment.partialTranscript,
                       !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(partial)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(ChatTheme.quietSurface)
                            )
                    }

                    if let transcript = attachment.transcript {
                        Text(transcript.provenanceSummary)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    mediaActionRow(for: attachment)
                }
                .accessibilityElement(children: .combine)
            }

            private func mediaHeader(for attachment: ChatMediaAttachment) -> some View {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: attachment.kind.iconName)
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(Color.accentColor)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.accentColor.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(attachment.transcript?.displaySourceName ?? attachment.originalFilename)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if let mediaDetailLabel = attachment.mediaDetailLabel {
                            Text(mediaDetailLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 8)

                    Button {
                        if attachment.hasCompletedTranscript && transcriptSaveFeedback[attachment.id]?.isSaved != true {
                            pendingRemovalAttachment = attachment
                        } else {
                            vm.removePendingMediaAttachment(id: attachment.id)
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.primary.opacity(0.06)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(LocalizedStringKey("Remove")))
                }
            }

            private func mediaStatusBadge(_ status: ChatMediaTranscriptionStatus) -> some View {
                Text(LocalizedStringKey(mediaStatusBadgeKey(status)))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(mediaStatusBadgeForeground(status))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(mediaStatusBadgeBackground(status))
                    )
            }

            private func mediaStatusBadgeKey(_ status: ChatMediaTranscriptionStatus) -> String {
                status.badgeLocalizationKey
            }

            private func mediaStatusBadgeForeground(_ status: ChatMediaTranscriptionStatus) -> Color {
                switch status {
                case .failed:
                    return .red
                case .completed:
                    return .green
                case .transcribing:
                    return .accentColor
                case .notStarted:
                    return .secondary
                }
            }

            private func mediaStatusBadgeBackground(_ status: ChatMediaTranscriptionStatus) -> Color {
                switch status {
                case .failed:
                    return Color.red.opacity(0.12)
                case .completed:
                    return Color.green.opacity(0.12)
                case .transcribing:
                    return Color.accentColor.opacity(0.12)
                case .notStarted:
                    return Color.primary.opacity(0.06)
                }
            }

            @ViewBuilder
            private func mediaActionRow(for attachment: ChatMediaAttachment) -> some View {
                if attachment.status == .transcribing {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text(LocalizedStringKey("Transcribing..."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        cancelTranscriptionButton(for: attachment)
                    }
                } else if attachment.hasCompletedTranscript {
                    let saveFeedback = transcriptSaveFeedback[attachment.id]
                    VStack(alignment: .leading, spacing: 8) {
                        ViewThatFits(in: .horizontal) {
                            completedTranscriptActionsWide(for: attachment, saveFeedback: saveFeedback)
                            completedTranscriptActionsStacked(for: attachment, saveFeedback: saveFeedback)
                        }

                        if let saveFeedback, let message = saveFeedback.message {
                            Text(message)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(saveFeedback.isSaved ? Color.green : (saveFeedback.isSaving ? Color.secondary : Color.red))
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else if attachment.status != .completed {
                    VStack(alignment: .leading, spacing: 8) {
                        if let error = attachment.errorMessage, attachment.status == .failed {
                            recoveryActionsRow(message: error, attachment: attachment)
                        }

                        HStack {
                            Spacer(minLength: 0)
                            Button {
                                beginTranscribingWithRemoteConfirmation(attachment)
                            } label: {
                                Label {
                                    Text(LocalizedStringKey("Transcribe"))
                                } icon: {
                                    Image(systemName: "waveform")
                                }
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }

            private func completedTranscriptActionsWide(for attachment: ChatMediaAttachment, saveFeedback: TranscriptSaveFeedback?) -> some View {
                HStack(spacing: 8) {
                    transcriptTextActionButton(title: "Summarize", systemImage: "text.bubble") {
                        performTranscriptQuickAction(.summarize, for: attachment)
                    }

                    transcriptTextActionButton(title: "Review", systemImage: "doc.text.magnifyingglass") {
                        transcriptReviewAttachment = attachment
                    }

                    Spacer(minLength: 0)

                    transcriptMoreActionsMenu(for: attachment)
                    transcriptSaveMenu(for: attachment, saveFeedback: saveFeedback)
                }
            }

            private func completedTranscriptActionsStacked(for attachment: ChatMediaAttachment, saveFeedback: TranscriptSaveFeedback?) -> some View {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        transcriptTextActionButton(title: "Summarize", systemImage: "text.bubble") {
                            performTranscriptQuickAction(.summarize, for: attachment)
                        }

                        transcriptTextActionButton(title: "Review", systemImage: "doc.text.magnifyingglass") {
                            transcriptReviewAttachment = attachment
                        }
                    }

                    HStack(spacing: 10) {
                        Spacer(minLength: 0)
                        transcriptMoreActionsMenu(for: attachment)
                        transcriptSaveMenu(for: attachment, saveFeedback: saveFeedback)
                    }
                }
            }

            private func cancelTranscriptionButton(for attachment: ChatMediaAttachment) -> some View {
                Button {
                    vm.cancelPendingMediaTranscription(id: attachment.id)
                } label: {
                    Label {
                        Text(LocalizedStringKey("Cancel"))
                    } icon: {
                        Image(systemName: "xmark.circle")
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            private func transcriptTextActionButton(
                title: LocalizedStringKey,
                systemImage: String,
                minWidth: CGFloat? = nil,
                action: @escaping () -> Void
            ) -> some View {
                Button(action: action) {
                    Label {
                        Text(title)
                    } icon: {
                        Image(systemName: systemImage)
                    }
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minWidth: minWidth)
            }

            private func transcriptIconActionLabel(systemImage: String) -> some View {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 20)
            }

            private func transcriptMoreActionsMenu(for attachment: ChatMediaAttachment) -> some View {
                Menu {
                    ForEach(TranscriptQuickAction.allCases.filter { $0 != .summarize && $0 != .ask }) { action in
                        Button {
                            performTranscriptQuickAction(action, for: attachment)
                        } label: {
                            Label(action.titleKey, systemImage: action.iconName)
                        }
                    }
                } label: {
                    transcriptIconActionLabel(systemImage: "ellipsis")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(Text(LocalizedStringKey("More actions")))
                .help(Text("More actions"))
            }

            private func transcriptSaveMenu(for attachment: ChatMediaAttachment, saveFeedback: TranscriptSaveFeedback?) -> some View {
                Menu {
                    Button {
                        saveTranscriptAttachment(attachment)
                    } label: {
                        Label(LocalizedStringKey("Save to Stored"), systemImage: "tray.and.arrow.down")
                    }
                    Button {
                        existingDatasetSaveAttachment = attachment
                    } label: {
                        Label(LocalizedStringKey("Save to existing dataset"), systemImage: "folder.badge.plus")
                    }
                } label: {
                    if saveFeedback?.isSaving == true {
                        ProgressView()
                            .scaleEffect(0.55)
                            .frame(width: 26, height: 20)
                    } else {
                        transcriptIconActionLabel(systemImage: saveFeedback?.isSaved == true ? "checkmark" : "tray.and.arrow.down")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(saveFeedback?.isSaving == true || saveFeedback?.isSaved == true)
                .accessibilityLabel(Text(LocalizedStringKey("Save transcript")))
                .help(Text("Save transcript to Stored"))
            }

            private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment) {
                guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
                transcriptSaveFeedback[attachment.id] = .saving
                Task {
                    let result = await vm.saveTranscriptAttachmentAsDataset(attachment)
                    await MainActor.run {
                        switch result {
                        case .success(let dataset):
                            transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                        case .failure(let error):
                            transcriptSaveFeedback[attachment.id] = .failed(
                                String.localizedStringWithFormat(
                                    String(localized: "Transcript save failed: %@"),
                                    error.localizedDescription
                                )
                            )
                        }
                    }
                }
            }

            private func saveTranscriptAttachment(_ attachment: ChatMediaAttachment, toExistingDataset dataset: LocalDataset) {
                guard transcriptSaveFeedback[attachment.id]?.isSaving != true else { return }
                transcriptSaveFeedback[attachment.id] = .saving
                Task {
                    let result = await vm.saveTranscriptAttachment(attachment, toExistingDataset: dataset)
                    await MainActor.run {
                        switch result {
                        case .success(let dataset):
                            transcriptSaveFeedback[attachment.id] = .saved(dataset.name)
                        case .failure(let error):
                            transcriptSaveFeedback[attachment.id] = .failed(
                                String.localizedStringWithFormat(
                                    String(localized: "Transcript save failed: %@"),
                                    error.localizedDescription
                                )
                            )
                        }
                    }
                }
            }

            private func latestPendingAttachment(matching attachment: ChatMediaAttachment) -> ChatMediaAttachment? {
                vm.pendingMediaAttachments.first { $0.id == attachment.id }
            }

            private func performTranscriptQuickAction(_ action: TranscriptQuickAction, for attachment: ChatMediaAttachment) {
                let title = attachment.transcript?.displaySourceName ?? attachment.originalFilename
                text = action.prompt(for: title)
                if action == .ask {
                    focus.wrappedValue = true
                } else {
                    performSend()
                }
            }

            private func beginTranscribingWithRemoteConfirmation(_ attachment: ChatMediaAttachment) {
                if TranscriptionSettings.selectedEngineID == .audioLanguageModel,
                   !TranscriptionSettings.hasConfirmedRemoteUpload {
                    remoteUploadConfirmationAttachment = attachment
                    return
                }
                vm.beginTranscribingPendingMediaAttachment(id: attachment.id)
            }

            @ViewBuilder
            private func recoveryActionsRow(message: String, attachment: ChatMediaAttachment?) -> some View {
                let actions = ASRRecoveryAction.actions(
                    for: message,
                    includeRetry: attachment != nil,
                    includeRemoteEndpoint: TranscriptionSettings.selectedEngineID == .audioLanguageModel
                )
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(actions) { action in
                            Button {
                                handleRecoveryAction(action, attachment: attachment)
                            } label: {
                                Label(action.titleKey, systemImage: action.iconName)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }

            private func handleRecoveryAction(_ action: ASRRecoveryAction, attachment: ChatMediaAttachment?) {
                switch action {
                case .retry:
                    if let attachment {
                        beginTranscribingWithRemoteConfirmation(attachment)
                    }
                case .openSettings, .chooseLocale, .downloadWhisperModel, .configureEndpoint:
                    tabRouter.selection = .settings
                }
            }

            private func mediaStatusText(_ attachment: ChatMediaAttachment) -> String {
                switch attachment.status {
                case .notStarted:
                    return String(localized: "Ready to transcribe")
                case .transcribing:
                    return String(localized: "Transcribing...")
                case .completed:
                    return String(localized: "Transcript ready")
                case .failed:
                    return attachment.errorMessage ?? String(localized: "Transcription failed")
                }
            }

            private var pendingImagesTray: some View {
                VStack(alignment: .leading, spacing: 6) {
                    let estimate = pendingImageBudgetEstimate
                    HStack(spacing: 8) {
                        Label(LocalizedStringKey("Images"), systemImage: "photo.stack")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(pendingImageBudgetTint(estimate.status))
                        Text(verbatim: "\(estimate.imageCount)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(pendingImageBudgetSummary(estimate))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(pendingImagesWithIndices, id: \.url.path) { item in
                                pendingImageTile(index: item.index, url: item.url)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: UIConstants.largeCornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemBackground).opacity(0.72))
                        .overlay(
                            RoundedRectangle(cornerRadius: UIConstants.largeCornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.8)
                        )
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: vm.pendingImageURLs.count)
            }

            private var pendingImageBudgetEstimate: ImagePromptBudgetEstimate {
                let totalBytes = vm.pendingImageURLs.reduce(Int64(0)) { total, url in
                    total + pendingImageFileSizeBytes(for: url)
                }
                return ImagePromptBudgetEstimator.estimate(
                    imageCount: vm.pendingImageURLs.count,
                    totalFileBytes: totalBytes,
                    usablePromptTokens: ChatVM.promptBudget(for: vm.contextLimit).usablePromptTokens
                )
            }

            private func pendingImageBudgetSummary(_ estimate: ImagePromptBudgetEstimate) -> String {
                let totalSize = estimate.totalFileBytes > 0
                    ? ByteCountFormatter.string(fromByteCount: estimate.totalFileBytes, countStyle: .file)
                    : String(localized: "Size unknown")
                return String.localizedStringWithFormat(
                    String(localized: "%@ · %@ img tok"),
                    totalSize,
                    Self.shortTokenLabel(estimate.estimatedPromptTokens)
                )
            }

            private func pendingImageBudgetTint(_ status: ImagePromptBudgetEstimate.Status) -> Color {
                switch status {
                case .comfortable: return .green
                case .tight: return .orange
                case .overBudget: return .red
                }
            }

            @ViewBuilder
            private func pendingImageTile(index: Int, url: URL) -> some View {
                let thumbnail = vm.pendingThumbnail(for: url)
                let isRecentlyAdded = (recentlyAddedImageURL == url)

                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .topTrailing) {
                        pendingImageContent(thumbnail)
                            .frame(width: 88, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
                            )
                            .overlay(alignment: .bottomTrailing) {
                                if isRecentlyAdded {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(Color.white, Color.green)
                                        .padding(6)
                                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                                }
                            }

                        Button(action: { vm.removePendingImage(at: index) }) {
                            Image(systemName: "xmark")
                                .foregroundColor(.white)
                                .font(.system(size: 10, weight: .black))
                                .padding(6)
                                .background(
                                    Circle()
                                        .fill(Color.black.opacity(0.72))
                                        .overlay(
                                            Circle().strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                                        )
                                )
                                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(pendingImageDimensionLabel(thumbnail))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(pendingImageBudgetLabel(for: url))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 88, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text(pendingImagePreflightAccessibilityLabel(thumbnail: thumbnail, url: url)))
                }
                .frame(width: 88, alignment: .leading)
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                    removal: .scale(scale: 0.92).combined(with: .opacity)
                ))
            }

            private func pendingImageDimensionLabel(_ thumbnail: UIImage?) -> String {
                guard let size = thumbnail?.size else { return String(localized: "Preparing image") }
                let scale = max(thumbnail?.scale ?? 1, 1)
                let width = max(1, Int((size.width * scale).rounded()))
                let height = max(1, Int((size.height * scale).rounded()))
                return "\(width)x\(height)"
            }

            private func pendingImageBudgetLabel(for url: URL) -> String {
                let fileSize = pendingImageFileSizeLabel(for: url)
                return String.localizedStringWithFormat(
                    String(localized: "%@ · %@ img tok"),
                    fileSize,
                    Self.shortTokenLabel(576)
                )
            }

            private func pendingImageFileSizeLabel(for url: URL) -> String {
                let bytes = pendingImageFileSizeBytes(for: url)
                guard bytes > 0 else {
                    return String(localized: "Size unknown")
                }
                return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            }

            private func pendingImageFileSizeBytes(for url: URL) -> Int64 {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? NSNumber else {
                    return 0
                }
                return max(0, size.int64Value)
            }

            private func pendingImagePreflightAccessibilityLabel(thumbnail: UIImage?, url: URL) -> String {
                String.localizedStringWithFormat(
                    String(localized: "Image preflight: %@, %@."),
                    pendingImageDimensionLabel(thumbnail),
                    pendingImageBudgetLabel(for: url)
                )
            }

            @ViewBuilder
            private func pendingImageContent(_ thumbnail: UIImage?) -> some View {
                if let ui = thumbnail {
                    Image(platformImage: ui)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.15))
                        .overlay(
                            ProgressView().scaleEffect(0.6)
                        )
                }
            }

            private func handlePendingImagesChange(from oldURLs: [URL], to newURLs: [URL]) {
                let previous = Set(oldURLs)
                guard let latestAdded = newURLs.last(where: { !previous.contains($0) }) else { return }

                pendingImageFeedbackTask?.cancel()
#if os(iOS)
                Haptics.impact(.light)
#endif
                withAnimation(.spring(response: 0.28, dampingFraction: 0.72)) {
                    recentlyAddedImageURL = latestAdded
                }

                pendingImageFeedbackTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        if recentlyAddedImageURL == latestAdded {
                            recentlyAddedImageURL = nil
                        }
                    }
                }
            }

        }
        
        var body: some View {
            NavigationStack {
#if os(macOS)
                macChatContainer
#else
                ZStack(alignment: .leading) {
                    chatContent
                        .guideHighlight(.chatCanvas)
                    if showSidebar {
                        Color.black.opacity(0.3)
                            .ignoresSafeArea()
                            .onTapGesture { withAnimation { showSidebar = false } }
                            // Fade the scrim in step with the sidebar slide instead of popping.
                            .transition(.opacity)
                        sidebar
                            .frame(width: currentDeviceWidth() * 0.48)
                            .transition(.move(edge: .leading))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
#if os(iOS) || os(visionOS)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        modelHeader
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        let slots = adaptiveTrailingSlots
                        HStack(spacing: 6) {
                            if slots >= 2 { sidebarToolbarButton }
                            moreToolbarMenu(includeSidebar: slots < 2, includeNewChat: slots == 0)
                            if slots >= 1 { newChatToolbarButton }
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
#endif
#endif
            }
#if os(macOS)
            .navigationTitle("Chat")
#endif
            .alert(item: $datasetManager.embedAlert) { info in
                Alert(title: Text(info.message))
            }
            .alert("Context Length Exceeded", isPresented: $showContextOverflowAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.contextOverflowAlertBody)
            }
            .alert(vm.memoryPromptBudgetAlertTitle, isPresented: $showMemoryPromptBudgetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.memoryPromptBudgetAlertBody)
            }
            .sheet(isPresented: $showRuntimeInfo) {
                ChatRuntimeInfoSheet()
                    .environmentObject(vm)
                    .environmentObject(modelManager)
            }
            .sheet(isPresented: $showScratchpad) {
                ChatScratchpadSheet(
                    text: $scratchpadDraft,
                    titleKey: "Private Scratchpad",
                    placeholderKey: "Notes for this chat",
                    clearTitleKey: "Clear Scratchpad",
                    onCancel: { showScratchpad = false },
                    onSave: {
                        vm.setScratchpadForActiveSession(scratchpadDraft)
                        showScratchpad = false
                    },
                    onClear: {
                        scratchpadDraft = ""
                        vm.setScratchpadForActiveSession("")
                        showScratchpad = false
                    }
                )
            }
            .sheet(isPresented: $showChatInstructions) {
                ChatScratchpadSheet(
                    text: $chatInstructionsDraft,
                    titleKey: "Chat Instructions",
                    placeholderKey: "Instructions for this chat",
                    clearTitleKey: "Clear Instructions",
                    onCancel: { showChatInstructions = false },
                    onSave: {
                        vm.setChatInstructionsForActiveSession(chatInstructionsDraft)
                        showChatInstructions = false
                    },
                    onClear: {
                        chatInstructionsDraft = ""
                        vm.setChatInstructionsForActiveSession("")
                        showChatInstructions = false
                    }
                )
            }
            .sheet(isPresented: $showChatSnapshot) {
                ChatSnapshotSheet(
                    rows: chatSnapshotRows,
                    exportText: chatSnapshotExportText
                )
            }
            .sheet(isPresented: $showChatExportPack) {
                ChatExportPackSheet(
                    noteTitle: sessionDisplayTitle(for: vm.sessions.first { $0.id == vm.activeSessionID } ?? ChatVM.Session(title: "", messages: [], date: Date())),
                    markdownNote: chatMarkdownNoteText,
                    citationsJSON: chatCitationsJSONText,
                    promptReceipt: chatSnapshotExportText,
                    generationReplayJSON: chatGenerationReplayJSONText
                )
            }
            .sheet(isPresented: $showContextPlan) {
                ChatContextPlanSheet(
                    rows: contextPlanRows,
                    summary: contextPlanSummary
                )
            }
            .overlay(alignment: .top) {
                if let active = modelManager.activeDataset,
                   datasetManager.indexingDatasetID == active.datasetID {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        let status = datasetManager.processingStatus[active.datasetID]
                        if let s = status, s.stage != .completed {
                            let etaStr: String = {
                                if let e = s.etaSeconds, e > 0 { return String(format: "~%dm %02ds", Int(e)/60, Int(e)%60) }
                                return "…"
                            }()
                            Text("Indexing: \(Int(s.progress * 100))% · \(etaStr)").font(.caption2)
                        } else {
                            Text("Indexing dataset…").font(.caption2)
                        }
                    }
                    .padding(8)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
                }
            }
#if os(macOS)
            .onAppear { syncSidebarSettings() }
            .onChange(of: modelManager.loadedModel?.id) { _ in syncSidebarSettings() }
            .onReceive(modelManager.$modelSettings) { _ in syncSidebarSettings() }
            .onChange(of: advancedSettings) { newValue in
                guard !suppressSidebarSave else { return }
                persistSidebarSettings(newValue)
            }
            .onChange(of: isAdvancedMode) { newValue in
                if !newValue {
                    withAnimation(.easeInOut(duration: 0.2)) { macChatChrome.showAdvancedControls = false }
                }
            }
#endif
        }

#if os(macOS)
        private var macChatContainer: some View {
            HStack(spacing: 0) {
                macChatDrawer
                Divider()
                chatContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if isAdvancedMode && macChatChrome.showAdvancedControls {
                    AdvancedSettingsSidebar(
                        settings: $advancedSettings,
                        model: modelManager.loadedModel,
                        models: modelManager.downloadedModels,
                        hide: { withAnimation(.easeInOut(duration: 0.2)) { macChatChrome.showAdvancedControls = false } }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }

        private var macChatDrawer: some View {
            ZStack(alignment: .topLeading) {
                AppTheme.sidebarBackground
                    .glassifyIfAvailable(in: Rectangle())
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("Chats")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        ChatToolbarIconButton(systemImage: "plus", help: "New Chat") {
                            vm.startNewSession()
                        }
                        .guideHighlight(.chatNewChatButton)
                    }
                    .padding(.horizontal, ChatTheme.spacingL)
                    .padding(.top, ChatTheme.spacingM)
                    .padding(.bottom, 6)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(vm.sessions) { session in
                                drawerRow(for: session)
                                    .contentShape(Rectangle())
                                    .onTapGesture { vm.select(session) }
                                    .contextMenu {
                                        Button(session.isFavorite ? "Remove Favorite" : "Favorite") {
                                            vm.toggleFavorite(session)
                                        }
                                        Button(role: .destructive) {
                                            sessionToDelete = session
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.horizontal, 8)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 264)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .guideHighlight(.chatSidebar)
            .confirmationDialog(
                "Delete chat \(sessionToDelete.map { drawerTitle(for: $0) } ?? "New chat")?",
                isPresented: Binding(
                    get: { sessionToDelete != nil },
                    set: { if !$0 { sessionToDelete = nil } }
                )
            ) {
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        vm.delete(session)
                    }
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionToDelete = nil
                }
            }
        }

        private struct HideMacListBackgroundIfAvailable: ViewModifier {
            func body(content: Content) -> some View {
                if #available(macOS 13, *) {
                    content.scrollContentBackground(.hidden)
                } else {
                    content
                }
            }
        }

        private func drawerRow(for session: ChatVM.Session) -> some View {
            MacChatDrawerRow(
                title: drawerTitle(for: session),
                preview: drawerPreview(for: session) ?? "",
                isSelected: session.id == vm.activeSessionID,
                isFavorite: session.isFavorite
            )
        }

        /// One chat row in the macOS drawer: quiet by default, a pale neutral
        /// wash on hover, and a subtle (non-accent) selection state.
        private struct MacChatDrawerRow: View {
            let title: String
            let preview: String
            let isSelected: Bool
            let isFavorite: Bool

            @State private var hovering = false

            var body: some View {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(isSelected ? .medium : .regular))
                            .lineLimit(1)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.75)))

                        if isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.yellow.opacity(0.8))
                        }

                        Spacer(minLength: 0)
                    }

                    Text(preview.isEmpty ? " " : preview)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .opacity(preview.isEmpty ? 0 : 1)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, ChatTheme.spacingM)
                .background(
                    RoundedRectangle(cornerRadius: ChatTheme.controlRadius - 2, style: .continuous)
                        .fill(isSelected
                              ? ChatTheme.selectionSurface
                              : (hovering ? ChatTheme.hoverSurface : Color.clear))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ChatTheme.controlRadius - 2, style: .continuous)
                        .stroke(ChatTheme.hairline.opacity(isSelected ? 1 : 0), lineWidth: 1)
                )
                .onHover { hovering = $0 }
            }
        }

        private func drawerPreview(for session: ChatVM.Session) -> String? {
            func stripThinkBlocks(_ text: String) -> String {
                var result = text

                while let start = result.range(of: "<think>", options: .caseInsensitive) {
                    if let end = result.range(of: "</think>", options: .caseInsensitive, range: start.upperBound..<result.endIndex) {
                        result.removeSubrange(start.lowerBound..<end.upperBound)
                    } else {
                        result.removeSubrange(start.lowerBound..<result.endIndex)
                        break
                    }
                }

                return result.replacingOccurrences(of: "</think>", with: "", options: .caseInsensitive)
            }

            func condense(_ text: String) -> String? {
                let sanitized = stripThinkBlocks(text)
                let condensed = sanitized
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")

                guard !condensed.isEmpty else { return nil }

                if condensed.count > 80 {
                    let prefix = condensed.prefix(77)
                    return prefix + "…"
                }
                return condensed
            }

            var fallback: String?

            for message in session.messages.reversed() {
                let roleLowercased = message.role.lowercased()
                guard roleLowercased != "system" else { continue }
                if message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }

                let isAssistant = roleLowercased == "assistant" || message.role == "🤖"
                if isAssistant {
                    if let finalText = vm.finalAnswerText(for: message),
                       let condensed = condense(finalText) {
                        return condensed
                    }
                    continue
                }

                if fallback == nil {
                    fallback = condense(message.text)
                }
            }

            return fallback
        }

        private func drawerTitle(for session: ChatVM.Session) -> String {
            let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "New chat" : trimmed
        }

        private func syncSidebarSettings() {
            guard let model = modelManager.loadedModel else {
                suppressSidebarSave = true
                advancedSettings = ModelSettings()
                DispatchQueue.main.async { suppressSidebarSave = false }
                return
            }
            let latest = modelManager.settings(for: model)
            suppressSidebarSave = true
            advancedSettings = latest
            DispatchQueue.main.async { suppressSidebarSave = false }
        }

        private func persistSidebarSettings(_ settings: ModelSettings) {
            guard let model = modelManager.loadedModel else { return }
            modelManager.updateSettings(settings, for: model)
            vm.applyEnvironmentVariables(from: settings)
        }
#endif

        private var scrollBottomInset: CGFloat {
#if os(macOS)
            return 16
#else
            // The input stack is a safeAreaInset now, so the viewport already
            // ends above it — this is just breathing room under the last message.
            return 12
#endif
        }

        private var hasActiveChatModel: Bool { vm.hasActiveChatModel }

        private var bookmarkedMessages: [BookmarkedMessageReference] {
            vm.sessions.flatMap { session in
                session.messages
                    .filter { $0.isBookmarked && $0.role.lowercased() != "system" }
                    .map { BookmarkedMessageReference(session: session, message: $0) }
            }
        }

        private var chatRecallResults: [ChatRecallResult] {
            let terms = recallSearchTerms(from: chatRecallQuery)
            guard !terms.isEmpty else { return [] }

            return vm.sessions.flatMap { session in
                session.messages.compactMap { message -> ChatRecallResult? in
                    guard message.role.lowercased() != "system" else { return nil }
                    let text = recallSearchText(for: message)
                    guard !text.isEmpty else { return nil }

                    let searchable = "\(sessionDisplayTitle(for: session)) \(message.role) \(text)"
                        .lowercased()
                    var score = 0
                    for term in terms {
                        if searchable.contains(term) {
                            score += term.count >= 5 ? 5 : 3
                            score += searchable.components(separatedBy: term).count - 1
                        }
                    }
                    if message.isBookmarked { score += 2 }
                    guard score > 0 else { return nil }
                    return ChatRecallResult(session: session, message: message, score: score)
                }
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.message.timestamp > rhs.message.timestamp
            }
            .prefix(12)
            .map { $0 }
        }

        private func sessionDisplayTitle(for session: ChatVM.Session) -> String {
            let trimmed = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "New chat") : trimmed
        }

        private var activeScratchpadHasText: Bool {
            !vm.activeScratchpad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private var activeChatInstructionsHasText: Bool {
            !vm.activeChatInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        private var chatModeBinding: Binding<ChatVM.ChatMode> {
            Binding(
                get: { vm.activeChatMode },
                set: { vm.setChatModeForActiveSession($0) }
            )
        }

        private var answerStyleBinding: Binding<ChatVM.AnswerStyle> {
            Binding(
                get: { vm.activeAnswerStyle },
                set: { vm.setAnswerStyleForActiveSession($0) }
            )
        }

        private var chatSnapshotRows: [ChatSnapshotRow] {
            let session = vm.sessions.first { $0.id == vm.activeSessionID }
            let modelName = modelManager.activeRemoteSession?.modelName
                ?? modelManager.loadedModel?.name
                ?? String(localized: "No model loaded")
            let backend = modelManager.activeRemoteSession?.backendName
                ?? modelManager.loadedModel?.format.displayName
                ?? String(localized: "None")
            let datasetName = vm.activeSessionDataset?.name ?? String(localized: "No dataset")
            let modeTitle = String(localized: String.LocalizationValue(vm.activeChatMode.titleKey))
            let answerStyleTitle = String(localized: String.LocalizationValue(vm.activeAnswerStyle.titleKey))
            let instructionsStatus = activeChatInstructionsHasText ? String(localized: "Set") : String(localized: "Inherited")
            let permissionCount = vm.activeToolPermissions.enabledCount
            let messageCount = vm.msgs.filter { $0.role.lowercased() != "system" }.count
            let prompt = vm.systemPromptText
            let settingsSummary = activeSettingsSummary()

            return [
                ChatSnapshotRow(title: String(localized: "Created"), value: Date().formatted(date: .abbreviated, time: .shortened)),
                ChatSnapshotRow(title: String(localized: "Chat"), value: sessionDisplayTitle(for: session ?? ChatVM.Session(title: "", messages: [], date: Date()))),
                ChatSnapshotRow(title: String(localized: "Active Model"), value: modelName),
                ChatSnapshotRow(title: String(localized: "Backend"), value: backend),
                ChatSnapshotRow(title: String(localized: "Chat Mode"), value: modeTitle),
                ChatSnapshotRow(title: String(localized: "Answer Style"), value: answerStyleTitle),
                ChatSnapshotRow(title: String(localized: "Chat Instructions"), value: instructionsStatus),
                ChatSnapshotRow(title: String(localized: "Active Dataset"), value: datasetName),
                ChatSnapshotRow(title: String(localized: "Tool Permissions"), value: "\(permissionCount) / 4"),
                ChatSnapshotRow(title: String(localized: "Message Count"), value: "\(messageCount)"),
                ChatSnapshotRow(title: String(localized: "System Prompt Fingerprint"), value: "len=\(prompt.count) hash=\(ChatVM.diagnosticHash(for: prompt))"),
                ChatSnapshotRow(title: String(localized: "Settings Summary"), value: settingsSummary)
            ]
        }

        private var chatSnapshotExportText: String {
            var lines = [String(localized: "Chat Snapshot")]
            lines.append(String(repeating: "-", count: 24))
            for row in chatSnapshotRows {
                lines.append("\(row.title): \(row.value)")
            }
            return lines.joined(separator: "\n")
        }

        private var chatMarkdownNoteText: String {
            let session = vm.sessions.first { $0.id == vm.activeSessionID }
            let title = sessionDisplayTitle(for: session ?? ChatVM.Session(title: "", messages: [], date: Date()))
            var lines: [String] = ["# \(title)", ""]
            lines.append("Generated: \(Date().formatted(date: .abbreviated, time: .shortened))")
            lines.append("")
            lines.append("## Snapshot")
            for row in chatSnapshotRows {
                lines.append("- \(row.title): \(row.value)")
            }
            lines.append("")
            lines.append("## Conversation")

            let visibleMessages = vm.msgs.filter { $0.role.lowercased() != "system" }
            if visibleMessages.isEmpty {
                lines.append("")
                lines.append("_\(String(localized: "No messages"))_")
            } else {
                for message in visibleMessages {
                    let roleTitle = markdownRoleTitle(for: message)
                    let text = markdownMessageText(for: message)
                    guard !text.isEmpty else { continue }
                    lines.append("")
                    lines.append("### \(roleTitle) - \(message.timestamp.formatted(date: .omitted, time: .shortened))")
                    lines.append("")
                    lines.append(text)
                    if let citations = message.citations, !citations.isEmpty {
                        lines.append("")
                        lines.append("Citations:")
                        for (index, citation) in citations.enumerated() {
                            let source = (citation.source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            let score = citation.score.map { String(format: "%.3f", $0) } ?? String(localized: "n/a")
                            lines.append("\(index + 1). \(source.isEmpty ? String(localized: "Unknown Source") : source) (score \(score))")
                        }
                    }
                }
            }

            return lines.joined(separator: "\n")
        }

        private var chatCitationsJSONText: String {
            let formatter = ISO8601DateFormatter()
            let messages: [[String: Any]] = vm.msgs.enumerated().compactMap { index, message in
                guard let citations = message.citations, !citations.isEmpty else { return nil }
                return [
                    "message_index": index,
                    "message_id": message.id.uuidString,
                    "role": markdownRoleTitle(for: message),
                    "timestamp": formatter.string(from: message.timestamp),
                    "citations": citations.enumerated().map { citationIndex, citation in
                        var citationPayload: [String: Any] = [
                            "index": citationIndex + 1,
                            "source": citation.source ?? "",
                            "text": citation.text
                        ]
                        if let score = citation.score {
                            citationPayload["score"] = score
                        }
                        return citationPayload
                    }
                ]
            }
            let payload: [String: Any] = [
                "chat_title": sessionDisplayTitle(for: vm.sessions.first { $0.id == vm.activeSessionID } ?? ChatVM.Session(title: "", messages: [], date: Date())),
                "exported_at": formatter.string(from: Date()),
                "messages": messages
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return "{\n  \"messages\" : []\n}"
            }
            return text
        }

        private var chatGenerationReplayJSONText: String {
            let formatter = ISO8601DateFormatter()
            let session = vm.sessions.first { $0.id == vm.activeSessionID }
            let visibleMessages: [[String: Any]] = vm.msgs.enumerated().compactMap { index, message in
                guard message.role.lowercased() != "system" else { return nil }
                var payload: [String: Any] = [
                    "index": index,
                    "id": message.id.uuidString,
                    "role": markdownRoleTitle(for: message),
                    "timestamp": formatter.string(from: message.timestamp),
                    "text": markdownMessageText(for: message)
                ]
                if let datasetID = message.datasetID, !datasetID.isEmpty {
                    payload["dataset_id"] = datasetID
                }
                if let datasetName = message.datasetName, !datasetName.isEmpty {
                    payload["dataset_name"] = datasetName
                }
                if let perf = message.perf {
                    payload["timings"] = [
                        "token_count": perf.tokenCount,
                        "avg_tokens_per_second": perf.avgTokPerSec,
                        "time_to_first_token_seconds": perf.timeToFirst,
                        "latency_samples_ms": perf.latencySamplesMs
                    ]
                }
                if let promptProcessing = message.promptProcessing {
                    payload["prompt_processing"] = [
                        "progress": promptProcessing.progress
                    ]
                }
                if let rag = message.ragInjectionInfo {
                    var ragPayload: [String: Any] = [
                        "dataset_name": rag.datasetName,
                        "stage": rag.stage.rawValue,
                        "requested_max_chunks": rag.requestedMaxChunks,
                        "retrieved_chunk_count": rag.retrievedChunkCount,
                        "injected_chunk_count": rag.injectedChunkCount,
                        "trimmed_chunk_count": rag.trimmedChunkCount,
                        "partial_chunk_injected": rag.partialChunkInjected,
                        "configured_context_tokens": rag.configuredContextTokens,
                        "reserved_response_tokens": rag.reservedResponseTokens,
                        "context_budget_tokens": rag.contextBudgetTokens,
                        "injected_context_tokens": rag.injectedContextTokens,
                        "decision_reason": rag.decisionReason
                    ]
                    if let method = rag.method {
                        ragPayload["method"] = method.rawValue
                    }
                    if let estimate = rag.fullContentEstimateTokens {
                        ragPayload["full_content_estimate_tokens"] = estimate
                    }
                    payload["rag"] = ragPayload
                }
                if let citations = message.citations, !citations.isEmpty {
                    payload["citations"] = citations.enumerated().map { citationIndex, citation in
                        var citationPayload: [String: Any] = [
                            "index": citationIndex + 1,
                            "text": citation.text,
                            "source": citation.source ?? ""
                        ]
                        if let score = citation.score {
                            citationPayload["score"] = score
                        }
                        return citationPayload
                    }
                }
                if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                    payload["tool_calls"] = toolCalls.map { toolCall in
                        var toolPayload: [String: Any] = [
                            "id": toolCall.id.uuidString,
                            "tool_name": toolCall.toolName,
                            "display_name": toolCall.displayName,
                            "phase": toolCall.phase.rawValue,
                            "timestamp": formatter.string(from: toolCall.timestamp),
                            "request_params": jsonReadyDictionary(toolCall.requestParams.mapValues { $0.value })
                        ]
                        if let externalID = toolCall.externalToolCallID {
                            toolPayload["external_tool_call_id"] = externalID
                        }
                        if let result = toolCall.result {
                            toolPayload["result"] = result
                        }
                        if let error = toolCall.error {
                            toolPayload["error"] = error
                        }
                        return toolPayload
                    }
                }
                if let webHits = message.webHits, !webHits.isEmpty {
                    payload["web_hits"] = webHits.map { hit in
                        [
                            "id": hit.id,
                            "title": hit.title,
                            "snippet": hit.snippet,
                            "url": hit.url,
                            "engine": hit.engine,
                            "score": hit.score
                        ]
                    }
                }
                if let webError = message.webError, !webError.isEmpty {
                    payload["web_error"] = webError
                }
                if let imagePaths = message.imagePaths, !imagePaths.isEmpty {
                    payload["image_count"] = imagePaths.count
                    payload["image_names"] = imagePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                }
                if let attachments = message.mediaAttachments, !attachments.isEmpty {
                    payload["media_attachment_count"] = attachments.count
                }
                payload["used_web_search"] = message.usedWebSearch ?? false
                payload["used_remote_backend"] = message.usedRemoteBackend ?? false
                if let backend = message.remoteBackendName, !backend.isEmpty {
                    payload["remote_backend_name"] = backend
                }
                if let model = message.remoteModelName, !model.isEmpty {
                    payload["remote_model_name"] = model
                }
                return payload
            }

            let payload: [String: Any] = [
                "schema": "noema.generation_replay",
                "schema_version": 1,
                "exported_at": formatter.string(from: Date()),
                "chat_title": sessionDisplayTitle(for: session ?? ChatVM.Session(title: "", messages: [], date: Date())),
                "prompt_receipt": chatSnapshotRows.map { ["title": $0.title, "value": $0.value] },
                "messages": visibleMessages
            ]
            guard JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else {
                return "{\n  \"schema\" : \"noema.generation_replay\",\n  \"messages\" : []\n}"
            }
            return text
        }

        private func jsonReadyDictionary(_ dictionary: [String: Any]) -> [String: Any] {
            dictionary.mapValues { jsonReadyValue($0) }
        }

        private func jsonReadyValue(_ value: Any) -> Any {
            switch value {
            case let string as String:
                return string
            case let bool as Bool:
                return bool
            case let int as Int:
                return int
            case let double as Double:
                return double
            case let float as Float:
                return Double(float)
            case let dictionary as [String: Any]:
                return dictionary.mapValues { jsonReadyValue($0) }
            case let array as [Any]:
                return array.map { jsonReadyValue($0) }
            default:
                return String(describing: value)
            }
        }

        private func markdownRoleTitle(for message: ChatVM.Msg) -> String {
            let role = message.role.lowercased()
            if role == "assistant" || message.role == "🤖" {
                return String(localized: "Assistant")
            }
            if role == "user" || message.role == "🧑‍💻" {
                return String(localized: "User")
            }
            return message.role
        }

        private func markdownMessageText(for message: ChatVM.Msg) -> String {
            let role = message.role.lowercased()
            let text: String?
            if role == "assistant" || message.role == "🤖" {
                text = vm.finalAnswerText(for: message)
            } else {
                text = message.text
            }
            return (text ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private var contextPlanRows: [ContextPlanRow] {
            let messages = vm.msgs.filter { $0.role.lowercased() != "system" }
            let usableBudget = ChatVM.promptBudget(for: vm.contextLimit).usablePromptTokens
            var used = 0
            var keptIDs = Set<UUID>()

            for message in messages.reversed() {
                let tokens = estimatedContextTokens(for: message)
                if used + tokens <= usableBudget || keptIDs.isEmpty {
                    keptIDs.insert(message.id)
                    used += tokens
                }
            }

            return messages.map { message in
                let kept = keptIDs.contains(message.id)
                return ContextPlanRow(
                    id: message.id,
                    roleTitle: markdownRoleTitle(for: message),
                    preview: contextPlanPreview(for: message),
                    tokenCount: estimatedContextTokens(for: message),
                    statusKey: kept ? "Kept" : "At risk",
                    tint: kept ? .green : .orange
                )
            }
        }

        private var contextPlanSummary: String {
            let rows = contextPlanRows
            let used = rows.filter { $0.statusKey == "Kept" }.reduce(0) { $0 + $1.tokenCount }
            let budget = ChatVM.promptBudget(for: vm.contextLimit).usablePromptTokens
            return String.localizedStringWithFormat(
                String(localized: "%@ of %@ estimated"),
                shortTokenLabel(used),
                shortTokenLabel(budget)
            )
        }

        private func contextPlanPreview(for message: ChatVM.Msg) -> String {
            let text = markdownMessageText(for: message)
            let condensed = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !condensed.isEmpty else { return String(localized: "Empty message") }
            if condensed.count > 120 {
                return String(condensed.prefix(117)) + "..."
            }
            return condensed
        }

        private func estimatedContextTokens(for message: ChatVM.Msg) -> Int {
            var total = estimatedTokenCount(markdownMessageText(for: message)) + 8
            if let retrievedContext = message.retrievedContext {
                total += estimatedTokenCount(retrievedContext)
            }
            if let citations = message.citations, !citations.isEmpty {
                total += citations.reduce(0) { $0 + estimatedTokenCount($1.text) }
            }
            if let imagePaths = message.imagePaths {
                total += imagePaths.count * 576
            }
            if let mediaAttachments = message.mediaAttachments {
                total += mediaAttachments.reduce(0) { partial, attachment in
                    partial + estimatedTokenCount(attachment.transcript?.effectiveTranscriptText ?? "")
                }
            }
            return max(1, total)
        }

        private func estimatedTokenCount(_ value: String) -> Int {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return 0 }
            let wordEstimate = trimmed.split { $0.isWhitespace || $0.isNewline }.count
            let charEstimate = Int(ceil(Double(trimmed.count) / 4.0))
            return max(1, max(wordEstimate, charEstimate))
        }

        private func shortTokenLabel(_ value: Int) -> String {
            if value >= 1_000 {
                return String(format: "%.1fk", Double(value) / 1000.0)
            }
            return "\(value)"
        }

        private func activeSettingsSummary() -> String {
            let settings = vm.loadedModelSettings
                ?? modelManager.loadedModel.map { modelManager.settings(for: $0) }
            guard let settings else { return String(localized: "None") }
            let context = Int(settings.contextLength.rounded())
            let gpu = settings.gpuLayers < 0 ? String(localized: "Auto") : "\(settings.gpuLayers)"
            return "ctx=\(context), temp=\(String(format: "%.2f", settings.temperature)), top-p=\(String(format: "%.2f", settings.topP)), gpu=\(gpu)"
        }

        private func openScratchpad() {
            scratchpadDraft = vm.activeScratchpad
            showScratchpad = true
        }

        private func openChatInstructions() {
            chatInstructionsDraft = vm.activeChatInstructions
            showChatInstructions = true
        }

        private func bookmarkPreview(for message: ChatVM.Msg) -> String {
            let sourceText = recallSearchText(for: message)
            let condensed = sourceText
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !condensed.isEmpty else { return String(localized: "Empty message") }
            if condensed.count > 90 {
                return String(condensed.prefix(87)) + "..."
            }
            return condensed
        }

        private func recallSearchTerms(from query: String) -> [String] {
            let parts = query
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.count >= 2 }
            var seen = Set<String>()
            return parts.filter { seen.insert($0).inserted }
        }

        private func recallSearchText(for message: ChatVM.Msg) -> String {
            let visible = message.trimmedVisibleAssistantText
            return visible.isEmpty ? message.text : visible
        }

        private func openMessage(session: ChatVM.Session, messageID: UUID) {
            shouldAutoScrollToBottom = false
            vm.select(session)
            withAnimation { showSidebar = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                vm.focus(onMessageWithID: messageID)
            }
        }

        private func openBookmark(_ bookmark: BookmarkedMessageReference) {
            openMessage(session: bookmark.session, messageID: bookmark.message.id)
        }

        private func openRecallResult(_ result: ChatRecallResult) {
            openMessage(session: result.session, messageID: result.message.id)
        }

        // MARK: - Chat status pills

        /// Shared capsule chrome for the status pills above the transcript,
        /// matching the dataset pill's tinted-glass look.
        private func statusPillBackground(tint: Color, secondary: Color) -> some View {
            Capsule()
                .fill(tint.opacity(0.22))
                .glassifyIfAvailable(in: Capsule())
                .overlay(
                    Capsule().fill(
                        LinearGradient(
                            colors: [tint.opacity(0.35), secondary.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                )
                .overlay(
                    Capsule().strokeBorder(tint.opacity(0.48), lineWidth: 0.9)
                )
        }

        /// Status row above the transcript: active dataset, context overflow,
        /// and memory budget pills. Scrolls horizontally so multiple pills
        /// never clip on narrow screens.
        @ViewBuilder
        private var chatStatusPillRow: some View {
            let hasModel = modelManager.activeRemoteSession != nil || modelManager.loadedModel != nil
            let overflowBanner = hasModel ? vm.contextOverflowBanner : nil
            let memoryNotice = hasModel ? vm.memoryPromptBudgetNoticeText : nil
            if vm.activeSessionDataset != nil || overflowBanner != nil || memoryNotice != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let ds = vm.activeSessionDataset {
                            datasetStatusPill(ds)
                        }
                        if let banner = overflowBanner {
                            contextOverflowPill(banner)
                        }
                        if let memoryNotice {
                            memoryBudgetPill(memoryNotice)
                        }
                    }
                    .padding(.horizontal, UIConstants.defaultPadding)
                    .padding(.vertical, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }

        private func datasetStatusPill(_ ds: LocalDataset) -> some View {
            Menu {
                Button(role: .destructive) {
                    vm.setDatasetForActiveSession(nil)
                } label: {
                    Label(LocalizedStringKey("Stop Using Dataset"), systemImage: "xmark.circle")
                }
                Button {
                    openStoredDatasetDetails(ds)
                } label: {
                    Label("See details", systemImage: "info.circle")
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                    Text("Using \(ds.name)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.9)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusPillBackground(tint: .blue, secondary: .cyan))
                .shadow(color: Color.blue.opacity(0.25), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }

        private func contextOverflowPill(_ banner: ChatVM.ContextOverflowBannerState) -> some View {
            let isStop = banner.strategy.isHardStop
            let tint: Color = isStop ? .red : .orange
            let secondary: Color = isStop ? .orange : .yellow
            return HStack(spacing: 0) {
                Button {
                    showContextOverflowAlert = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: banner.strategy.pillSymbolName)
                            .font(.caption.weight(.semibold))
                        Text(LocalizedStringKey(banner.strategy.pillTitleKey))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(LocalizedStringKey(banner.strategy.pillTitleKey)))
                .accessibilityHint(Text("Shows details about the context window."))

                Button {
                    vm.dismissActiveContextOverflowBanner()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.85)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Dismiss context warning"))
            }
            .foregroundStyle(.white)
            .background(statusPillBackground(tint: tint, secondary: secondary))
            .shadow(color: tint.opacity(0.25), radius: 8, x: 0, y: 4)
        }

        private func memoryBudgetPill(_ notice: String) -> some View {
            Button {
                showMemoryPromptBudgetAlert = true
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "bookmark.slash.fill")
                        .font(.caption.weight(.semibold))
                    Text(notice)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(statusPillBackground(tint: .yellow, secondary: .orange))
                .shadow(color: Color.yellow.opacity(0.25), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(notice)
        }

        private var chatContent: some View {
            return VStack(spacing: 0) {
#if os(macOS)
                macChatToolbar
#endif
                chatStatusPillRow

#if os(macOS)
                // The composer is the SAME structural node in both states, so
                // the hand-off animates only its position — no matched-geometry
                // duplicate, no NSTextView remount, focus carries over.
                if isMacNewChatCanvas {
                    Spacer(minLength: ChatTheme.spacingXL)
                    Text("How can I help you today?")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.bottom, 30)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    conversationScrollArea
                        .transition(.opacity)
                }
                macComposerStack
                if isMacNewChatCanvas {
                    macSuggestionPills
                        .padding(.top, 22)
                        .transition(.opacity)
                    Spacer(minLength: ChatTheme.spacingXL)
                    Spacer(minLength: 0)
                }
#else
                conversationScrollArea
#if !os(iOS)
                nonMacDesktopComposerStack
#endif
#endif
            }
#if os(macOS)
            // One coherent spring drives the hero→bottom composer hand-off.
            .animation(.spring(response: 0.42, dampingFraction: 0.9), value: isMacNewChatCanvas)
#endif
            .onAppear {
                // Pick suggestions when entering a new empty chat (only once)
                let isEmpty = vm.msgs.first(where: { $0.role != "system" }) == nil
                if isEmpty {
                    suggestionTriplet = ChatSuggestions.nextThree(datasetName: vm.activeSessionDataset?.name)
                    suggestionsSessionID = vm.activeSessionID
                }
            }
            .onChangeCompat(of: vm.activeSessionID) { _, newID in
                showContextOverflowAlert = false
#if os(macOS)
                macComposerHandOff = false
#endif
                // Rotate suggestions per new session if starting empty
                let isEmpty = vm.msgs.first(where: { $0.role != "system" }) == nil
                if isEmpty && newID != suggestionsSessionID {
                    suggestionTriplet = ChatSuggestions.nextThree(datasetName: vm.activeSessionDataset?.name)
                    suggestionsSessionID = newID
                }
            }
            .onChangeCompat(of: vm.activeSessionDataset?.datasetID) { _, _ in
                let isEmpty = vm.msgs.first(where: { $0.role != "system" }) == nil
                if isEmpty {
                    suggestionTriplet = ChatSuggestions.nextThree(datasetName: vm.activeSessionDataset?.name)
                    suggestionsSessionID = vm.activeSessionID
                }
            }
#if os(iOS)
            // Decorative bottom glow. Stays an overlay (anchored to the full
            // chat bounds, behind the input stack) and never intercepts touches.
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    let menuBarOffset = max(proxy.safeAreaInsets.bottom, 52)
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.18), location: 0.0),
                            .init(color: Color.white.opacity(0.11), location: 0.22),
                            .init(color: Color.white.opacity(0.06), location: 0.52),
                            .init(color: Color.white.opacity(0.03), location: 0.78),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .bottom,
                        endPoint: .top
                    )
                    .frame(maxWidth: .infinity)
                    .frame(height: 620)
                    .offset(y: menuBarOffset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea(edges: .bottom)
                .allowsHitTesting(false)
            }
            // The input stack is a safe-area inset (NOT an overlay) so the
            // ScrollView's viewport ends above it: `scrollTo(_, anchor: .bottom)`
            // and manual scrolling both land the last message's bottom —
            // badges, perf footer — fully visible above the status bar +
            // composer, while content still scrolls beneath the glass.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                let isIndexing = datasetManager.indexingDatasetID != nil
                VStack(spacing: 0) {
                    if isIndexing {
                        VStack(spacing: 4) {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.8)
                                Text("Dataset indexing in progress...")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text("You can keep chatting while indexing finishes")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.bottom, 4)
                    }

                    ChatInputBox(text: $draftText, focus: inputFocusBinding,
                                 showModelRequiredAlert: $showModelRequiredAlert,
                                 send: { let text = draftText; draftText = ""; Task { await vm.sendMessage(text) } },
                                 stop: { vm.stop() },
                                 stopAfterParagraph: { vm.requestStopAfterParagraph() },
                                 canStop: vm.isStreaming,
                                 stopAfterParagraphPending: vm.stopAfterParagraphRequested)
                    .guideHighlight(.chatInput)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
            }
#endif
            .alert("Load Failed", isPresented: Binding(get: { vm.loadError != nil }, set: { _ in vm.loadError = nil })) {
                if vm.pendingETRepairCandidate != nil {
                    Button("Repair") {
                        Task { await vm.repairPendingETArtifacts() }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(vm.loadError ?? "")
            }
            // Keep draftText in sync when ChatVM sets prompt externally — e.g.
            // branch creation pre-fills the input, or a blocked send restores it.
            .onChangeCompat(of: vm.prompt) { _, newPrompt in
                if draftText != newPrompt { draftText = newPrompt }
            }
            // Value-scoped: only animates the status pill row appearing/disappearing.
            .animation(.easeInOut(duration: 0.2), value: vm.contextOverflowBanner)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }

        private var conversationScrollArea: some View {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.msgs.filter { $0.role != "system" }) { m in
                                StreamingAwareMessageView(msg: m, store: vm.streamingStore)
                                    .id(m.id)
                            }
                            // Drives auto-scroll from the streaming store so the view
                            // follows tokens smoothly without re-rendering the whole list.
                            StreamingScrollAnchor(store: vm.streamingStore, proxy: proxy, enabled: shouldAutoScrollToBottom)
                        }
#if os(macOS)
                        // Constrain the conversation to a readable column with
                        // generous breathing room on either side.
                        .padding(.vertical, ChatTheme.spacingL)
                        .padding(.horizontal, ChatTheme.conversationHorizontalInset)
                        .frame(maxWidth: ChatTheme.conversationMaxWidth + ChatTheme.conversationHorizontalInset * 2)
                        .frame(maxWidth: .infinity)
#else
                        .padding()
#endif
                        .padding(.bottom, scrollBottomInset)
#if os(macOS)
                        .background(
                            MacChatScrollObserver { nearBottom, userInitiated in
                                if nearBottom {
                                    if !shouldAutoScrollToBottom {
                                        shouldAutoScrollToBottom = true
                                    }
                                } else if userInitiated {
                                    shouldAutoScrollToBottom = false
                                }
                            }
                            .frame(width: 0, height: 0)
                        )
#endif
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
#if canImport(UIKit) && !os(visionOS)
                    // On iOS/iPadOS, stop auto-scrolling when the user drags the list.
                    // Avoid attaching this drag gesture on macOS so text selection remains uninterrupted.
                    .simultaneousGesture(DragGesture().onChanged { _ in shouldAutoScrollToBottom = false })
#endif
#if !os(macOS)
                    // Centered suggestions overlay for brand-new empty chats
                    // (macOS uses the dedicated new-chat canvas instead).
                    .overlay(alignment: .center) {
                        let isEmptyChat = vm.msgs.first(where: { $0.role != "system" }) == nil
                        let hasPendingMediaSurface = !vm.pendingMediaAttachments.isEmpty
                            || vm.audioRecordingError?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        let showsSuggestions = isEmptyChat && !hasPendingMediaSurface && !vm.isStreaming && !vm.loading
                        Group {
                            if showsSuggestions {
                                SuggestionsOverlay(
                                    suggestions: suggestionTriplet,
                                    enabled: hasActiveChatModel,
                                    onTap: { text in
                                        guard hasActiveChatModel else { return }
                                        guard !vm.isStreamingInAnotherSession else {
                                            vm.crossSessionSendBlocked = true
                                            return
                                        }
                                        suggestionTriplet = []
                                        Task { await vm.sendMessage(text) }
                                    },
                                    onDisabledTap: {
                                        inputFocused = false
                                        showModelRequiredAlert = true
                                    }
                                )
                                .transition(.opacity.combined(with: .scale))
                            }
                        }
                        // The gating state changes outside withAnimation (vm publishes),
                        // so bind the animation to the value or the transition never fires.
                        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showsSuggestions)
                    }
#endif
                    .overlay(alignment: .bottomTrailing) {
                        let showsJumpToBottom = !shouldAutoScrollToBottom && vm.isStreaming
                        Group {
                            if showsJumpToBottom {
                                Button {
                                    if let id = vm.msgs.last?.id {
                                        withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                                    }
                                    shouldAutoScrollToBottom = true
                                } label: {
                                    Image(systemName: "arrow.down")
                                        .font(.caption)
                                        .padding(10)
                                        .background(.thinMaterial)
                                        .clipShape(Circle())
                                }
                                .padding(.trailing, 16)
                                // The input stack is a safeAreaInset, so the
                                // overlay's bottom already sits above it.
                                .padding(.bottom, 12)
                                .transition(.scale(scale: 0.6).combined(with: .opacity))
                            }
                        }
                        // Driven by drag gestures / vm state, never withAnimation —
                        // animate on the value so the button doesn't pop in.
                        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: showsJumpToBottom)
                    }
                    .onTapGesture {
                        let wasInputFocused = inputFocused
                        DispatchQueue.main.async {
                            // Ignore taps that transferred focus into the composer
                            // during the same gesture pass.
                            if !wasInputFocused && inputFocused {
                                return
                            }
                            inputFocused = false
                            hideKeyboard()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .thinkToggled)) { note in
                        guard let info = note.userInfo,
                              let idStr = info["messageId"] as? String,
                              let uuid = UUID(uuidString: idStr) else { return }
                        // Scroll to the message that had its think box closed
                        withAnimation {
                            proxy.scrollTo(uuid, anchor: .top)
                        }
                    }
                    .onChangeCompat(of: vm.spotlightMessageID) { _, id in
                        guard let id else { return }
                        withAnimation {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                    .onChangeCompat(of: vm.msgs) { _, msgs in
                        if shouldAutoScrollToBottom, let id = msgs.last?.id {
                            // Critically damped spring while streaming: matches
                            // StreamingScrollAnchor's follow animation so the
                            // pinned view glides instead of snapping. (Instant
                            // scroll was only needed before the anchor was
                            // throttled to ~12 Hz.)
                            if vm.isStreaming {
                                withAnimation(.spring(response: 0.28, dampingFraction: 1.0)) {
                                    proxy.scrollTo(id, anchor: .bottom)
                                }
                            } else {
                                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                            }
                        }
                    }
                }
        }

        /// The composer instance shared by every desktop placement (hero canvas
        /// and bottom bar) so its bindings and identity stay consistent.
        private var composerCore: some View {
            ChatInputBox(text: $draftText, focus: inputFocusBinding,
                         showModelRequiredAlert: $showModelRequiredAlert,
                         send: { sendCurrentDraft() },
                         stop: { vm.stop() },
                         stopAfterParagraph: { vm.requestStopAfterParagraph() },
                         canStop: vm.isStreaming,
                         stopAfterParagraphPending: vm.stopAfterParagraphRequested)
                .guideHighlight(.chatInput)
        }

        private func sendCurrentDraft() {
            let text = draftText
            draftText = ""
#if os(macOS)
            if isMacNewChatCanvas {
                sendWithMacHandOff(text)
                return
            }
#endif
            Task { await vm.sendMessage(text) }
        }

        @ViewBuilder
        private var indexingNotice: some View {
            if datasetManager.indexingDatasetID != nil {
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.8)
                        Text("Dataset indexing in progress...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("You can keep chatting while indexing finishes")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.bottom)
            }
        }

#if os(macOS)
        /// True when the active chat has no visible conversation yet — the
        /// composer is centered on a hero canvas until the first send.
        private var isMacNewChatCanvas: Bool {
            !macComposerHandOff
                && vm.msgs.first(where: { $0.role != "system" }) == nil
                && !vm.isStreaming
        }

        /// First send in a fresh chat: collapse the hero canvas and let the
        /// composer slide to the bottom *before* inference starts. Prompt
        /// prefill saturates CPU and GPU, so an animation overlapping it drops
        /// to single frames — the short deferral keeps the hand-off fluid.
        private func sendWithMacHandOff(_ text: String) {
            macComposerHandOff = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                await vm.sendMessage(text)
                macComposerHandOff = false
            }
        }

        /// Compact, quiet starter prompts under the hero composer.
        @ViewBuilder
        private var macSuggestionPills: some View {
            if !suggestionTriplet.isEmpty && !vm.loading {
                VStack(spacing: ChatTheme.spacingS) {
                    ForEach(suggestionTriplet.prefix(3), id: \.self) { suggestion in
                        Button {
                            guard hasActiveChatModel else {
                                inputFocused = false
                                showModelRequiredAlert = true
                                return
                            }
                            guard !vm.isStreamingInAnotherSession else {
                                vm.crossSessionSendBlocked = true
                                return
                            }
                            suggestionTriplet = []
                            sendWithMacHandOff(suggestion)
                        } label: {
                            Text(suggestion)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, ChatTheme.spacingM)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(ChatTheme.quietSurface))
                                .overlay(Capsule().stroke(ChatTheme.hairline, lineWidth: 1))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .opacity(hasActiveChatModel ? 1 : 0.55)
                    }
                }
                .frame(maxWidth: ChatTheme.heroComposerMaxWidth)
            }
        }

        /// The composer bar: centered narrow on the new-chat canvas, aligned
        /// with the conversation column once a chat is underway. One node in
        /// both states — only its width and position animate.
        private var macComposerStack: some View {
            VStack(spacing: 0) {
                composerCore
                    .frame(maxWidth: isMacNewChatCanvas
                           ? ChatTheme.heroComposerMaxWidth
                           : ChatTheme.conversationMaxWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ChatTheme.conversationHorizontalInset)
                    .padding(.top, ChatTheme.spacingM)
                    .padding(.bottom, ChatTheme.spacingM)
                indexingNotice
            }
        }
#endif

#if os(visionOS)
        /// visionOS keeps the previous bottom composer arrangement.
        @ViewBuilder
        private var nonMacDesktopComposerStack: some View {
            composerCore
                .padding()
            indexingNotice
        }
#endif

        private func openStoredDatasetDetails(_ dataset: LocalDataset) {
            tabRouter.pendingStoredDatasetID = dataset.datasetID
#if os(iOS) || os(visionOS)
            withAnimation(.easeInOut(duration: 0.2)) {
                tabRouter.selection = .stored
            }
#else
            tabRouter.selection = .stored
#endif
        }

#if os(macOS)
        private var macChatToolbar: some View {
            VStack(spacing: 0) {
                HStack(spacing: ChatTheme.spacingS) {
                    MacModelSelectorBar()
                        .frame(minWidth: 260, idealWidth: 360, maxWidth: 420)
                    Spacer()
                    ChatToolbarIconButton(systemImage: "info.circle", help: "Runtime Information") {
                        showRuntimeInfo = true
                    }
                    ChatToolbarIconButton(systemImage: "square.and.pencil", help: "New Chat") {
                        vm.startNewSession()
                    }
                    .guideHighlight(.chatNewChatButton)
                }
                .padding(.horizontal, ChatTheme.spacingL)
                .frame(height: 46)
                AppTheme.separator.frame(height: 1)
            }
            .background(AppTheme.windowBackground)
            .macWindowDragDisabled()
            // Ensure toolbar sits visually above background visuals.
            .zIndex(2)
        }
#endif

        // MARK: - Adaptive top bar

        /// Estimated widths used to decide how many trailing icons fit beside the model name.
        private static let toolbarIconSlotWidth: CGFloat = 44   // one toolbar icon button + spacing
        /// Nav-bar insets, glass-capsule padding, and the gap between the leading and
        /// trailing groups. Underestimating this makes the system collapse the trailing
        /// buttons into its own nested "•••" overflow (a second tap to reach the menu),
        /// so err high.
        private static let toolbarChromeWidth: CGFloat = 104
        private static let modelChipChromeWidth: CGFloat = 18   // disclosure chevron + spacing
        private static let minModelChipWidth: CGFloat = 90

        private var currentModelDisplayName: String {
            if let remote = modelManager.activeRemoteSession { return remote.modelName }
            if let loaded = modelManager.loadedModel { return loaded.name }
            return String(localized: "No model")
        }

        /// Precise rendered width of a string in the model-name font, computed synchronously
        /// so the toolbar can size itself without a measurement/relayout pass.
        private func modelNameDisplayWidth(_ name: String) -> CGFloat {
#if canImport(UIKit)
            let base = UIFont.preferredFont(forTextStyle: .subheadline)
            let font = UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(.traitBold) ?? base.fontDescriptor,
                              size: base.pointSize)
#else
            let font = NSFont.preferredFont(forTextStyle: .subheadline)
#endif
            return ceil((name as NSString).size(withAttributes: [.font: font]).width)
        }

        /// Upper bound for the model-name chip so the trailing controls that stay inline
        /// always have room — preventing the system's own nested overflow.
        private var maxModelNameWidth: CGFloat {
            let inlineButtons = CGFloat(adaptiveTrailingSlots + 1)  // More (•••) is always inline
            let total = currentDeviceWidth()
            return max(Self.minModelChipWidth,
                       total - Self.toolbarChromeWidth - inlineButtons * Self.toolbarIconSlotWidth)
        }

        /// Trailing tier beside the model name: 2 = sidebar + More + New inline,
        /// 1 = More + New (sidebar folds into More), 0 = More only (New Chat folds too).
        private var adaptiveTrailingSlots: Int {
            let total = currentDeviceWidth()
            let available = total - Self.toolbarChromeWidth
            let nameWidth = modelNameDisplayWidth(currentModelDisplayName) + Self.modelChipChromeWidth
            if nameWidth + 3 * Self.toolbarIconSlotWidth <= available { return 2 }
            if Self.minModelChipWidth + 2 * Self.toolbarIconSlotWidth <= available { return 1 }
            return 0
        }

        @ViewBuilder
        private var sidebarToolbarButton: some View {
            Button {
                withAnimation { showSidebar.toggle() }
            } label: {
                Image(systemName: "line.3.horizontal")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .guideHighlight(.chatSidebarButton)
        }

        @ViewBuilder
        private var chatModePickers: some View {
            Picker(LocalizedStringKey("Chat Mode"), selection: chatModeBinding) {
                ForEach(ChatVM.ChatMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.titleKey)).tag(mode)
                }
            }
            Divider()
            Picker(LocalizedStringKey("Answer Style"), selection: answerStyleBinding) {
                ForEach(ChatVM.AnswerStyle.allCases) { style in
                    Text(LocalizedStringKey(style.titleKey)).tag(style)
                }
            }
        }

        @ViewBuilder
        private var newChatToolbarButton: some View {
            Button { vm.startNewSession() } label: { Image(systemName: "plus") }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
                .guideHighlight(.chatNewChatButton)
        }

        /// Single flat overflow menu. Folds in the sidebar/new-chat controls when they
        /// don't fit as inline icons, so options always open directly (never a nested menu).
        @ViewBuilder
        private func moreToolbarMenu(includeSidebar: Bool, includeNewChat: Bool) -> some View {
            Menu {
                if includeNewChat {
                    Button { vm.startNewSession() } label: {
                        Label("New Chat", systemImage: "plus")
                    }
                }
                if includeSidebar {
                    Button {
                        withAnimation { showSidebar.toggle() }
                    } label: {
                        Label("Chat History", systemImage: "line.3.horizontal")
                    }
                }
                Button { showRuntimeInfo = true } label: {
                    Label("Runtime Information", systemImage: "info.circle")
                }
                Button { showContextPlan = true } label: {
                    Label("Context Plan", systemImage: "list.bullet.rectangle")
                }
                Divider()
                Button { openScratchpad() } label: {
                    Label("Private Scratchpad", systemImage: activeScratchpadHasText ? "note.text" : "note.text.badge.plus")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .accessibilityLabel(Text("More options"))
        }

        private var modelHeader: some View {
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    if let remote = modelManager.activeRemoteSession {
                        Menu {
                            Section(remote.backendName) {
                                Button(role: .destructive) {
                                    performMediumImpact()
                                    AppSoundPlayer.play(.loadPress)
                                    vm.deactivateRemoteSession()
                                } label: {
                                    Label(LocalizedStringKey("Disconnect"), systemImage: "eject")
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                remoteConnectionIndicator(for: remote)
                                Text(remote.modelName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: maxModelNameWidth, alignment: .leading)
                        }
                        .menuIndicator(.hidden)
                    } else if let loaded = modelManager.loadedModel {
                        Menu {
                            Button(role: .destructive) {
                                performMediumImpact()
                                AppSoundPlayer.play(.loadPress)
                                modelManager.loadedModel = nil
                                Task { await vm.unload() }
                            } label: {
                                Label(LocalizedStringKey("Unload Model"), systemImage: "eject")
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(loaded.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: maxModelNameWidth, alignment: .leading)
                        }
                        .menuIndicator(.hidden)
                    } else {
                        let favourites = quickLoadFavourites
                        let recents = quickLoadRecents
                        Menu {
                            if favourites.isEmpty && recents.isEmpty {
                                Button(LocalizedStringKey("Open Model Library")) {
                                    tabRouter.selection = .explore
                                    UserDefaults.standard.set(ExploreSection.models.rawValue, forKey: "exploreSection")
                                }
                            } else {
                                if !favourites.isEmpty {
                                    Section(LocalizedStringKey("Favorites")) {
                                        ForEach(favourites, id: \.id) { model in
                                            Button {
                                                quickLoadIfPossible(model)
                                            } label: {
                                                quickLoadLabel(for: model, isFavourite: true)
                                            }
                                        }
                                    }
                                }
                                if !recents.isEmpty {
                                    Section(LocalizedStringKey("Recent")) {
                                        ForEach(recents, id: \.id) { model in
                                            Button {
                                                quickLoadIfPossible(model)
                                            } label: {
                                                quickLoadLabel(for: model, isFavourite: false)
                                            }
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(LocalizedStringKey("No model >"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .menuIndicator(.hidden)
                        .disabled(vm.loading)
                    }
                }

            }
        }
        
        private func remoteConnectionBadge(for session: ActiveRemoteSession) -> some View {
            let color: Color
            switch session.transport {
            case .cloudRelay:
                color = .teal
            case .lan:
                color = .green
            case .direct:
                color = .blue
            }
            return HStack(spacing: 6) {
                Image(systemName: session.transport.symbolName)
                Text(session.transport.label)
                if session.streamingEnabled {
                    Image(systemName: "waveform")
                }
            }
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundColor(color)
            .accessibilityLabel("Connection via \(session.transport.label)")
        }
        
        
        @ViewBuilder
        private func remoteConnectionIndicator(for session: ActiveRemoteSession) -> some View {
            if session.endpointType == .noemaRelay {
                let color: Color = {
                    switch session.transport {
                    case .cloudRelay: return .teal
                    case .lan: return .green
                    case .direct: return .blue
                    }
                }()
                HStack(spacing: 4) {
                    Image(systemName: session.transport.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                    if session.streamingEnabled {
                        Image(systemName: "waveform")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .padding(6)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
                .accessibilityLabel("Connection via \(session.transport.label)")
            } else {
                remoteConnectionBadge(for: session)
            }
        }

        private var quickLoadFavourites: [LocalModel] {
            modelManager.favouriteModels(limit: modelManager.favouriteCapacity)
        }
        
        private var quickLoadRecents: [LocalModel] {
            let favouriteIDs = Set(quickLoadFavourites.map(\.id))
            return modelManager.recentModels(limit: 3, excludingIDs: favouriteIDs)
        }
        
        @ViewBuilder
        private func quickLoadLabel(for model: LocalModel, isFavourite: Bool) -> some View {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(quickLoadSubtitle(for: model))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: isFavourite ? "star.fill" : "clock")
                    .foregroundColor(isFavourite ? .yellow : .secondary)
            }
        }
        
        private func quickLoadSubtitle(for model: LocalModel) -> String {
            var parts: [String] = []
            if !model.quant.isEmpty {
                parts.append(model.quant)
            }
            parts.append(model.format.displayName)
            parts.append(quickLoadContextEstimate(for: model))
            parts.append(quickLoadMemoryEstimate(for: model))
            return parts.joined(separator: " · ")
        }

        private func quickLoadContextEstimate(for model: LocalModel) -> String {
            let settings = modelManager.settings(for: model)
            let context = Int(settings.contextLength.rounded())
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: context), number: .decimal)
            return String.localizedStringWithFormat(String(localized: "%@ ctx"), formatted)
        }

        private func quickLoadMemoryEstimate(for model: LocalModel) -> String {
            let settings = modelManager.settings(for: model)
            let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
            let layerHint: Int? = model.totalLayers > 0 ? model.totalLayers : nil
            let kvCacheEstimate = model.format == .gguf
                ? ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
                : .f16F16
            let estimate = ModelRAMAdvisor.estimateAndBudget(
                format: model.format,
                sizeBytes: sizeBytes,
                contextLength: Int(settings.contextLength),
                layerCount: layerHint,
                moeInfo: model.moeInfo,
                kvCacheEstimate: kvCacheEstimate
            )
            let estimateText = ByteCountFormatter.string(fromByteCount: estimate.estimate, countStyle: .memory)
            if let budget = estimate.budget, estimate.estimate > budget {
                return String.localizedStringWithFormat(String(localized: "~%@ over budget"), estimateText)
            }
            return String.localizedStringWithFormat(String(localized: "~%@ load"), estimateText)
        }
        
        private func quickLoadIfPossible(_ model: LocalModel) {
            guard quickLoadInProgress == nil else { return }
            guard !vm.loading else { return }
            quickLoad(model)
        }
        
        private func quickLoad(_ model: LocalModel) {
            quickLoadInProgress = model.id
            Task { @MainActor in
                defer { quickLoadInProgress = nil }
                
                if model.format == .et {
                    var settings = modelManager.settings(for: model)
                    settings.contextLength = max(1, settings.contextLength)
                    let success = await vm.load(url: model.url, settings: settings, format: .et, forceReload: true)
                    if success {
                        modelManager.updateSettings(settings, for: model)
                        modelManager.markModelUsed(model)
                        tabRouter.selection = .chat
                    } else {
                        modelManager.loadedModel = nil
                    }
                    return
                }
                
                await vm.unload()
                try? await Task.sleep(nanoseconds: 200_000_000)
                
                var settings = modelManager.settings(for: model)
                if model.format == .gguf && settings.gpuLayers == 0 {
                    settings.gpuLayers = -1
                }
                
                let sizeBytes = Int64(model.sizeGB * 1_073_741_824.0)
                let ctx = Int(settings.contextLength)
                let layerHint: Int? = model.totalLayers > 0 ? model.totalLayers : nil
                let kvCacheEstimate = ModelRAMAdvisor.GGUFKVCacheEstimate.resolved(from: settings)
                let bypassRAM = UserDefaults.standard.bool(forKey: "bypassRAMCheck")
                if !bypassRAM && !ModelRAMAdvisor.fitsInRAM(
                    format: model.format,
                    sizeBytes: sizeBytes,
                    contextLength: ctx,
                    layerCount: layerHint,
                    moeInfo: model.moeInfo,
                    kvCacheEstimate: kvCacheEstimate
                ) {
                    AppSoundPlayer.play(.error)
                    Haptics.error()
                    vm.loadError = String(
                        localized: "Model likely exceeds memory budget. Lower context or choose a smaller quant.",
                        locale: LocalizationManager.preferredLocale()
                    )
                    modelManager.loadedModel = nil
                    return
                }
                
                var loadURL = model.url
                switch model.format {
                case .gguf:
                    var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                            if isDir.boolValue {
                                if let f = InstalledModelsStore.firstGGUF(in: loadURL) {
                                    loadURL = f
                                } else {
                                    vm.loadError = String(
                                        localized: "Model file missing (.gguf)",
                                        locale: LocalizationManager.preferredLocale()
                                    )
                                    modelManager.loadedModel = nil
                                    return
                                }
                            } else if loadURL.pathExtension.lowercased() != "gguf" || !InstalledModelsStore.isValidGGUF(at: loadURL) {
                                if let f = InstalledModelsStore.firstGGUF(in: loadURL.deletingLastPathComponent()) {
                                    loadURL = f
                                } else {
                                    vm.loadError = String(
                                        localized: "Model file missing (.gguf)",
                                        locale: LocalizationManager.preferredLocale()
                                    )
                                    modelManager.loadedModel = nil
                                    return
                                }
                            }
                    } else {
                        if let alt = InstalledModelsStore.firstGGUF(in: InstalledModelsStore.baseDir(for: .gguf, modelID: model.modelID)) {
                            loadURL = alt
                        } else {
                            vm.loadError = String(
                                localized: "Model path missing",
                                locale: LocalizationManager.preferredLocale()
                            )
                            modelManager.loadedModel = nil
                            return
                        }
                    }
                case .mlx:
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                        loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                    } else {
                        var d: ObjCBool = false
                        let dir = InstalledModelsStore.baseDir(for: .mlx, modelID: model.modelID)
                        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                            loadURL = dir
                        } else {
                            vm.loadError = String(
                                localized: "Model path missing",
                                locale: LocalizationManager.preferredLocale()
                            )
                            modelManager.loadedModel = nil
                            return
                        }
                    }
                case .et:
                    return
                case .ane:
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: loadURL.path, isDirectory: &isDir) {
                        loadURL = isDir.boolValue ? loadURL : loadURL.deletingLastPathComponent()
                    } else {
                        let dir = InstalledModelsStore.baseDir(for: .ane, modelID: model.modelID)
                        var d: ObjCBool = false
                        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &d), d.boolValue {
                            loadURL = dir
                        } else {
                            vm.loadError = String(
                                localized: "Model path missing",
                                locale: LocalizationManager.preferredLocale()
                            )
                            modelManager.loadedModel = nil
                            return
                        }
                    }
                case .afm:
                    loadURL = InstalledModelsStore.baseDir(for: .afm, modelID: model.modelID)
                    try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
                case .coreai:
                    loadURL = InstalledModelsStore.baseDir(for: .coreai, modelID: model.modelID)
                    try? FileManager.default.createDirectory(at: loadURL, withIntermediateDirectories: true)
                }

                var pendingFlagSet = false
                defer {
                    if pendingFlagSet {
                        UserDefaults.standard.set(false, forKey: "bypassRAMLoadPending")
                    }
                }
                
                UserDefaults.standard.set(true, forKey: "bypassRAMLoadPending")
                pendingFlagSet = true
                
                let success = await vm.load(url: loadURL, settings: settings, format: model.format)
                if success {
                    modelManager.updateSettings(settings, for: model)
                    modelManager.markModelUsed(model)
                    tabRouter.selection = .chat
                } else {
                    modelManager.loadedModel = nil
                }
            }
        }

        private struct ChatSnapshotSheet: View {
            @Environment(\.dismiss) private var dismiss
            let rows: [ChatSnapshotRow]
            let exportText: String

            var body: some View {
                NavigationStack {
                    List {
                        Section(LocalizedStringKey("Snapshot Receipt")) {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(LocalizedStringKey(row.title))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(row.value)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .navigationTitle(Text("Chat Snapshot"))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink(item: exportText) {
                                Label("Share Snapshot", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 500, idealWidth: 580, minHeight: 460, idealHeight: 580)
#endif
            }
        }

        private struct ChatExportPackSheet: View {
            @Environment(\.dismiss) private var dismiss
            let noteTitle: String
            let markdownNote: String
            let citationsJSON: String
            let promptReceipt: String
            let generationReplayJSON: String
            @State private var exportFileURLs: [ChatExportPackBuilder.ExportKind: URL] = [:]
            @State private var exportFileError: String?
            @State private var markdownNoteURL: URL?
            @State private var markdownNoteError: String?

            var body: some View {
                NavigationStack {
                    List {
                        Section(LocalizedStringKey("Export Pack")) {
                            exportFileRow(
                                kind: .markdown,
                                titleKey: "Markdown Note",
                                subtitleKey: "Clean conversation note",
                                systemImage: "doc.plaintext"
                            )
                            exportFileRow(
                                kind: .pdf,
                                titleKey: "PDF Document",
                                subtitleKey: "Paginated conversation copy",
                                systemImage: "doc.richtext"
                            )
                            exportFileRow(
                                kind: .docx,
                                titleKey: "DOCX Document",
                                subtitleKey: "Word-compatible conversation package",
                                systemImage: "doc.text"
                            )
                            exportFileRow(
                                kind: .citationsJSON,
                                titleKey: "Citations JSON",
                                subtitleKey: "Source metadata for cited answers",
                                systemImage: "curlybraces"
                            )
                            exportFileRow(
                                kind: .promptReceipt,
                                titleKey: "Prompt Receipt",
                                subtitleKey: "Model, settings, dataset, and prompt fingerprint",
                                systemImage: "doc.badge.gearshape"
                            )
                            exportFileRow(
                                kind: .generationReplayJSON,
                                titleKey: "Replay JSON",
                                subtitleKey: "Prompt, output, timings, tools, and citations",
                                systemImage: "arrow.trianglehead.clockwise"
                            )

                            if let exportFileError, !exportFileError.isEmpty {
                                Text(exportFileError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }

                        Section(LocalizedStringKey("Local Note")) {
                            Button {
                                saveMarkdownNote()
                            } label: {
                                Label(LocalizedStringKey("Save Markdown Note"), systemImage: "square.and.arrow.down")
                            }

                            if let markdownNoteURL {
                                ShareLink(item: markdownNoteURL) {
                                    Label(LocalizedStringKey("Share Saved Note"), systemImage: "square.and.arrow.up")
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(LocalizedStringKey("Note File"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(markdownNoteURL.lastPathComponent)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 4)
                            }

                            if let markdownNoteError, !markdownNoteError.isEmpty {
                                Text(markdownNoteError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else {
                                Text(LocalizedStringKey("Save the conversation as a local Markdown note."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .navigationTitle(Text("Export Pack"))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                    .task(id: exportTaskID) {
                        generateExportFiles()
                    }
                }
#if os(macOS)
                .frame(minWidth: 500, idealWidth: 560, minHeight: 360, idealHeight: 460)
#endif
            }

            private var exportTaskID: String {
                "\(noteTitle)|\(markdownNote.count)|\(citationsJSON.count)|\(promptReceipt.count)|\(generationReplayJSON.count)"
            }

            @ViewBuilder
            private func exportFileRow(
                kind: ChatExportPackBuilder.ExportKind,
                titleKey: String,
                subtitleKey: String,
                systemImage: String
            ) -> some View {
                if let url = exportFileURLs[kind] {
                    ShareLink(item: url) {
                        exportFileLabel(titleKey: titleKey, subtitleKey: subtitleKey, systemImage: systemImage)
                    }
                } else {
                    Button {
                        generateExportFiles()
                    } label: {
                        exportFileLabel(titleKey: titleKey, subtitleKey: subtitleKey, systemImage: systemImage)
                    }
                }
            }

            private func exportFileLabel(titleKey: String, subtitleKey: String, systemImage: String) -> some View {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LocalizedStringKey(titleKey))
                            .font(.body.weight(.medium))
                        Text(LocalizedStringKey(subtitleKey))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                .padding(.vertical, 4)
            }

            private func generateExportFiles() {
                do {
                    exportFileURLs = try ChatExportPackBuilder.writeExportPack(
                        title: noteTitle,
                        markdownNote: markdownNote,
                        citationsJSON: citationsJSON,
                        promptReceipt: promptReceipt,
                        generationReplayJSON: generationReplayJSON
                    )
                    exportFileError = nil
                } catch {
                    exportFileURLs = [:]
                    exportFileError = error.localizedDescription
                }
            }

            private func saveMarkdownNote() {
                do {
                    let filename = "\(ChatExportPackBuilder.sanitizedFileStem(noteTitle))-note-\(ChatExportPackBuilder.fileTimestamp()).md"
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                    try markdownNote.write(to: url, atomically: true, encoding: .utf8)
                    markdownNoteURL = url
                    markdownNoteError = nil
                } catch {
                    markdownNoteURL = nil
                    markdownNoteError = error.localizedDescription
                }
            }
        }

        private struct ChatContextPlanSheet: View {
            @Environment(\.dismiss) private var dismiss
            let rows: [ContextPlanRow]
            let summary: String

            var body: some View {
                NavigationStack {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Prompt window")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: summary)
                                    .font(.body.weight(.medium))
                            }
                            .padding(.vertical, 4)
                        } footer: {
                            Text("Older messages marked at risk are the first candidates for summarizing or dropping when the prompt gets too large.")
                        }

                        Section(LocalizedStringKey("Messages")) {
                            if rows.isEmpty {
                                Text("No conversation messages")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(rows) { row in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            Text(verbatim: row.roleTitle)
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Text(LocalizedStringKey(row.statusKey))
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(row.tint)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(row.tint.opacity(0.12), in: Capsule())
                                            Text(verbatim: "\(row.tokenCount) tok")
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(verbatim: row.preview)
                                            .font(.callout)
                                            .lineLimit(3)
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                    .navigationTitle(Text("Context Plan"))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { dismiss() }
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 520, idealWidth: 620, minHeight: 460, idealHeight: 620)
#endif
            }
        }

        private struct ChatScratchpadSheet: View {
            @Binding var text: String
            let titleKey: String
            let placeholderKey: String
            let clearTitleKey: String
            let onCancel: () -> Void
            let onSave: () -> Void
            let onClear: () -> Void

            var body: some View {
                NavigationStack {
                    VStack(spacing: 12) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $text)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .padding(14)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                            if text.isEmpty {
                                Text(LocalizedStringKey(placeholderKey))
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 22)
                                    .padding(.leading, 20)
                                    .allowsHitTesting(false)
                            }
                        }

                        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button(role: .destructive, action: onClear) {
                                Label {
                                    Text(LocalizedStringKey(clearTitleKey))
                                        .frame(maxWidth: .infinity)
                                } icon: {
                                    Image(systemName: "trash")
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding()
                    .navigationTitle(Text(LocalizedStringKey(titleKey)))
#if os(iOS) || os(visionOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onCancel)
                        }
                        ToolbarItem(placement: .primaryAction) {
                            Button("Done", action: onSave)
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 520)
#endif
            }
        }

        private struct ChatRuntimeInfoSheet: View {
            @Environment(\.dismiss) private var dismiss
            @EnvironmentObject private var vm: ChatVM
            @EnvironmentObject private var modelManager: AppModelManager
            @State private var latestResponse: LoopbackResponseDiagnostics?
            @State private var lastStartOptions: LlamaServerBridge.StartOptions?

            private var loadedModel: LocalModel? { modelManager.loadedModel }

            private var activeSettings: ModelSettings? {
                if let settings = vm.loadedModelSettings {
                    return settings
                }
                if let loadedModel {
                    return modelManager.settings(for: loadedModel)
                }
                return nil
            }

            var body: some View {
                NavigationStack {
                    ZStack {
                        RuntimeInfoSurfaceBackground()
                            .ignoresSafeArea()

                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 24) {
                                    Text("Runtime Information")
                                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                                        .foregroundStyle(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    RuntimeInfoSection(
                                        title: "Runtime",
                                        systemImage: "cpu",
                                        isCollapsible: false,
                                        items: runtimeRows
                                    )

                                    if let settings = activeSettings {
                                        RuntimeInfoSection(
                                            title: "Sampling Parameters",
                                            systemImage: "thermometer.medium",
                                            items: samplingRows(settings)
                                        )
                                        RuntimeInfoSection(
                                            title: "Draft Information",
                                            systemImage: "square.and.pencil",
                                            items: draftRows(settings)
                                        )
                                    } else {
                                        RuntimeInfoSection(
                                            title: "Sampling Parameters",
                                            systemImage: "thermometer.medium",
                                            items: [
                                                RuntimeInfoItem("Status", value: String(localized: "No local model loaded"))
                                            ]
                                        )
                                    }

                                    RuntimeInfoSection(
                                        title: "Draft Diagnostics",
                                        systemImage: "chart.line.uptrend.xyaxis",
                                        items: diagnosticsRows
                                    )
                                    RuntimeInfoSection(
                                        title: "Server Launch",
                                        systemImage: "server.rack",
                                        items: serverRows
                                    )
                                }
                                .padding(.horizontal, runtimeHorizontalPadding)
                                .padding(.top, runtimeTopPadding)
                                .padding(.bottom, 24)
                                .frame(maxWidth: 760)
                                .frame(maxWidth: .infinity)
                            }
                            .scrollIndicators(.hidden)

                            RuntimeInfoFooter(
                                close: { dismiss() },
                                refresh: { refreshDiagnostics() }
                            )
                        }
                    }
                }
#if os(macOS)
                .frame(minWidth: 620, idealWidth: 720, maxWidth: 820, minHeight: 560, idealHeight: 760)
#endif
                .task { refreshDiagnostics() }
            }

            private var runtimeHorizontalPadding: CGFloat {
#if os(macOS)
                28
#else
                20
#endif
            }

            private var runtimeTopPadding: CGFloat {
#if os(macOS)
                28
#else
                22
#endif
            }

            private var runtimeRows: [RuntimeInfoItem] {
                if let remote = modelManager.activeRemoteSession {
                    return [
                        RuntimeInfoItem("Model", value: remote.modelName),
                        RuntimeInfoItem("Backend", value: remote.backendName),
                        RuntimeInfoItem("Format", value: String(localized: "Remote"))
                    ]
                } else if let loadedModel {
                    var rows = [
                        RuntimeInfoItem("Model", value: loadedModel.name),
                        RuntimeInfoItem("Format", value: loadedModel.format.displayName)
                    ]
                    if !loadedModel.quant.isEmpty {
                        rows.append(RuntimeInfoItem("Quantization", value: loadedModel.quant))
                    }
                    rows.append(RuntimeInfoItem("Path", value: loadedModel.url.lastPathComponent))
                    return rows
                }
                return [
                    RuntimeInfoItem("Model", value: String(localized: "None"))
                ]
            }

            private func samplingRows(_ settings: ModelSettings) -> [RuntimeInfoItem] {
                [
                    RuntimeInfoItem("Temperature", value: decimal(settings.temperature)),
                    RuntimeInfoItem("Top-p", value: decimal(settings.topP)),
                    RuntimeInfoItem("Top-k", value: "\(settings.topK)"),
                    RuntimeInfoItem("Min-p", value: decimal(settings.minP)),
                    RuntimeInfoItem("Repetition Penalty", value: decimal(Double(settings.repetitionPenalty))),
                    RuntimeInfoItem("Repeat Last N", value: "\(settings.repeatLastN)"),
                    RuntimeInfoItem("Presence Penalty", value: decimal(Double(settings.presencePenalty))),
                    RuntimeInfoItem("Frequency Penalty", value: decimal(Double(settings.frequencyPenalty))),
                    RuntimeInfoItem("Seed", value: settings.seed.map(String.init) ?? String(localized: "Default")),
                    RuntimeInfoItem("Context", value: "\(Int(settings.contextLength))"),
                    RuntimeInfoItem("CPU Threads", value: settings.cpuThreads > 0 ? "\(settings.cpuThreads)" : String(localized: "Auto")),
                    RuntimeInfoItem("GPU Layers", value: settings.gpuLayers < 0 ? String(localized: "Auto") : "\(settings.gpuLayers)"),
                    RuntimeInfoItem("Flash Attention", value: flag(settings.flashAttention)),
                    RuntimeInfoItem("KV Offload", value: flag(settings.kvCacheOffload)),
                    RuntimeInfoItem("K Cache", value: settings.kCacheQuant.rawValue),
                    RuntimeInfoItem("V Cache", value: settings.vCacheQuant.rawValue),
                    RuntimeInfoItem("Prompt Cache", value: flag(settings.promptCacheEnabled))
                ]
            }

            private func draftRows(_ settings: ModelSettings) -> [RuntimeInfoItem] {
                [
                    RuntimeInfoItem("Speculative Mode", value: speculativeSelectionTitle(settings.speculativeDecoding.selection)),
                    RuntimeInfoItem("MTP Draft Tokens", value: "\(settings.speculativeDecoding.resolvedMTPDraftNMax)"),
                    RuntimeInfoItem("MTP Min Draft Tokens", value: "\(settings.speculativeDecoding.resolvedMTPDraftNMin)"),
                    RuntimeInfoItem("MTP Draft P-Min", value: String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin)),
                    RuntimeInfoItem("Draft Strategy", value: draftModeTitle(settings.speculativeDecoding.mode)),
                    RuntimeInfoItem("Draft Value", value: "\(settings.speculativeDecoding.value)"),
                    RuntimeInfoItem("Helper Model", value: settings.speculativeDecoding.helperModelID ?? String(localized: "None")),
                    RuntimeInfoItem("MTP Support", value: mtpSupportText),
                    RuntimeInfoItem("MTP Source", value: mtpSourceText)
                ]
            }

            private var diagnosticsRows: [RuntimeInfoItem] {
                var rows: [RuntimeInfoItem] = []
                if let timings = latestResponse?.timings {
                    rows.append(RuntimeInfoItem("Draft Generated", value: timings.draftN.map(String.init) ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Draft Accepted", value: timings.draftNAccepted.map(String.init) ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Acceptance", value: timings.acceptanceRate.map { percent($0) } ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Predicted Speed", value: timings.predictedPerSecond.map { String.localizedStringWithFormat(String(localized: "%.1f tok/s"), $0) } ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Prompt Speed", value: timings.promptPerSecond.map { String.localizedStringWithFormat(String(localized: "%.1f tok/s"), $0) } ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Prompt Tokens", value: timings.promptN.map(String.init) ?? String(localized: "Unavailable")))
                    rows.append(RuntimeInfoItem("Output Tokens", value: timings.predictedN.map(String.init) ?? String(localized: "Unavailable")))
                } else {
                    rows.append(RuntimeInfoItem("Status", value: String(localized: "No response diagnostics yet")))
                }
                if let latestResponse {
                    rows.append(RuntimeInfoItem("Endpoint", value: latestResponse.endpoint))
                    rows.append(RuntimeInfoItem("Request Mode", value: latestResponse.requestMode))
                    rows.append(RuntimeInfoItem("Streaming", value: flag(latestResponse.streaming)))
                    rows.append(RuntimeInfoItem("Finish Reason", value: latestResponse.finishReason ?? String(localized: "None")))
                    rows.append(RuntimeInfoItem("Output Characters", value: "\(latestResponse.outputCharacters)"))
                }
                return rows
            }

            private var serverRows: [RuntimeInfoItem] {
                if let lastStartOptions {
                    return [
                        RuntimeInfoItem("Port", value: "\(lastStartOptions.port)"),
                        RuntimeInfoItem("Speculative Type", value: lastStartOptions.speculativeType.isEmpty ? String(localized: "None") : lastStartOptions.speculativeType),
                        RuntimeInfoItem("Draft Model", value: lastStartOptions.mtpPath.isEmpty ? String(localized: "Embedded MTP head or none") : URL(fileURLWithPath: lastStartOptions.mtpPath).lastPathComponent),
                        RuntimeInfoItem("MTP Draft Tokens", value: lastStartOptions.specDraftNMax.map(String.init) ?? String(localized: "None")),
                        RuntimeInfoItem("Server Arguments", value: lastStartOptions.argv.joined(separator: " "))
                    ]
                }
                return [
                    RuntimeInfoItem("Status", value: String(localized: "No server launch recorded"))
                ]
            }

            private var mtpSupportText: String {
                guard let url = vm.loadedModelURL ?? loadedModel?.url else { return String(localized: "Unavailable") }
                let sidecar = MtpLocator.mtpPath(alongside: url) != nil
                let embedded = GGUFMetadata.hasMTP(at: url)
                if sidecar && embedded { return String(localized: "MTP sidecar and embedded head") }
                if sidecar { return String(localized: "MTP sidecar") }
                if embedded { return String(localized: "Embedded MTP head") }
                return String(localized: "Unavailable")
            }

            private var mtpSourceText: String {
                guard let url = vm.loadedModelURL ?? loadedModel?.url else {
                    return String(localized: "None")
                }
                if let path = MtpLocator.mtpPath(alongside: url) {
                    return URL(fileURLWithPath: path).lastPathComponent
                }
                if GGUFMetadata.hasMTP(at: url) {
                    return String(localized: "Embedded MTP head")
                }
                return String(localized: "None")
            }

            private func refreshDiagnostics() {
                lastStartOptions = LlamaServerBridge.lastStartOptions()
                Task {
                    let snapshot = await LoopbackRuntimeDiagnostics.shared.latestResponseSnapshot()
                    await MainActor.run {
                        latestResponse = snapshot
                    }
                }
            }

            private func speculativeSelectionTitle(_ selection: ModelSettings.SpeculativeDecodingSettings.Selection) -> String {
                switch selection {
                case .off: return String(localized: "Off")
                case .helperDraftModel: return String(localized: "Helper Model")
                case .mtp: return String(localized: "Multi-Token Prediction")
                }
            }

            private func draftModeTitle(_ mode: ModelSettings.SpeculativeDecodingSettings.Mode) -> String {
                switch mode {
                case .tokens: return String(localized: "Draft Tokens")
                case .max: return String(localized: "Draft Window")
                }
            }

            private func flag(_ value: Bool) -> String {
                value ? String(localized: "On") : String(localized: "Off")
            }

            private func decimal(_ value: Double, digits: Int = 2) -> String {
                String(format: "%.\(digits)f", value)
            }

            private func percent(_ value: Double) -> String {
                String.localizedStringWithFormat(String(localized: "%.1f%%"), value * 100)
            }
        }

        private struct RuntimeInfoItem {
            let title: LocalizedStringKey
            let value: String

            init(_ title: LocalizedStringKey, value: String) {
                self.title = title
                self.value = value
            }
        }

        private struct RuntimeInfoSurfaceBackground: View {
            @Environment(\.colorScheme) private var colorScheme

            var body: some View {
                baseColor
                    .overlay {
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.03 : 0.42),
                                Color.blue.opacity(colorScheme == .dark ? 0.04 : 0.035),
                                Color.primary.opacity(colorScheme == .dark ? 0.035 : 0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
            }

            @ViewBuilder
            private var baseColor: some View {
#if os(macOS)
                Color(nsColor: .windowBackgroundColor)
#elseif os(visionOS)
                Color.clear
#else
                Color(uiColor: .systemGroupedBackground)
#endif
            }
        }

        private struct RuntimeInfoSection: View {
            let title: LocalizedStringKey
            let systemImage: String
            let isCollapsible: Bool
            let items: [RuntimeInfoItem]
            @State private var isExpanded: Bool

            init(title: LocalizedStringKey, systemImage: String, isCollapsible: Bool = true, items: [RuntimeInfoItem]) {
                self.title = title
                self.systemImage = systemImage
                self.isCollapsible = isCollapsible
                self.items = items
                _isExpanded = State(initialValue: true)
            }

            var body: some View {
                VStack(alignment: .leading, spacing: 10) {
                    if isCollapsible {
                        Button {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            header
                        }
                        .buttonStyle(.plain)
                    } else {
                        header
                    }

                    if isExpanded {
                        VStack(spacing: 0) {
                            ForEach(items.indices, id: \.self) { index in
                                RuntimeInfoRow(title: items[index].title, value: items[index].value)
                                if index < items.count - 1 {
                                    Divider()
                                        .overlay(Color.primary.opacity(0.05))
                                        .padding(.leading, 14)
                                }
                            }
                        }
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.regularMaterial)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .shadow(color: Color.black.opacity(0.045), radius: 14, x: 0, y: 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }

            private var header: some View {
                HStack(spacing: 12) {
                    Image(systemName: systemImage)
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.primary)
                        .frame(width: 28, height: 28)

                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    if isCollapsible {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    }
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }
        }

        private struct RuntimeInfoFooter: View {
            let close: () -> Void
            let refresh: () -> Void

            var body: some View {
                HStack(spacing: 12) {
                    Spacer()
                    Button(action: close) {
                        Text("Close")
                            .frame(minWidth: 82)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.large)
                    .keyboardShortcut(.cancelAction)

                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 70)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 8))
                    .controlSize(.large)
                    .tint(.blue)
                    .accessibilityLabel(Text("Refresh"))
                }
                .padding(.horizontal, 28)
                .padding(.top, 14)
                .padding(.bottom, 18)
                .background(.regularMaterial)
                .overlay(alignment: .top) {
                    Divider()
                        .overlay(Color.primary.opacity(0.06))
                }
            }
        }

        private struct RuntimeInfoRow: View {
            let title: LocalizedStringKey
            let value: String

            var body: some View {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Text(value)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .font(.system(.callout, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(minHeight: 34)
            }
        }

#if os(macOS)
        private struct AdvancedSettingsSidebar: View {
            @Binding var settings: ModelSettings
            let model: LocalModel?
            let models: [LocalModel]
            let hide: () -> Void
            @State private var isArgmaxANEMLLModel = false

            private var helperOptions: [LocalModel] {
                guard let base = model else { return [] }
                return models.filter { candidate in
                    guard candidate.id != base.id else { return false }
                    guard candidate.matchesArchitectureFamily(of: base) else { return false }
                    let baseSize = base.sizeGB
                    let candidateSize = candidate.sizeGB
                    if baseSize > 0, candidateSize > 0, candidateSize - baseSize > 0.01 {
                        return false
                    }
                    return true
                }
            }

            private var modelHasMTPSupport: Bool {
                guard let model, model.format == .gguf else { return false }
                return MtpLocator.hasMtpFile(alongside: model.url) || GGUFMetadata.hasMTP(at: model.url)
            }

            private var format: ModelFormat? { model?.format }

            private var supportsMinP: Bool { format == .gguf }
            private var supportsPresencePenalty: Bool { format == .gguf }
            private var supportsFrequencyPenalty: Bool { format == .gguf }
            private var supportsSpeculativeDecoding: Bool {
#if os(macOS)
                return format == .gguf
#elseif os(visionOS)
                return false
#else
                return format == .gguf
#endif
            }

            var body: some View {
                VStack(spacing: 0) {
                    HStack {
                        Text("Advanced Controls")
                            .font(.headline)
                        Spacer()
                        Button(action: hide) {
                            Image(systemName: "sidebar.trailing")
                                .imageScale(.medium)
                        }
                        .buttonStyle(.plain)
                        .help("Collapse controls")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            samplingSection
                            if supportsSpeculativeDecoding {
                                speculativeSection
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 24)
                    }
                }
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 360, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(alignment: .leading) {
                    Color.primary.opacity(0.08)
                        .frame(width: 1)
                        .ignoresSafeArea()
                }
                .task(id: model?.url.path ?? "") {
                    guard let model, model.format == .ane else {
                        isArgmaxANEMLLModel = false
                        return
                    }
                    let modelURL = model.url
                    isArgmaxANEMLLModel = await Task.detached(priority: .utility) {
                        ANEMLLCapabilityLookup.argmaxInModel(modelURL: modelURL)
                    }.value
                }
            }

            private var samplingSection: some View {
                sidebarSection(title: "Sampling", systemImage: "dial.medium") {
                    if isArgmaxANEMLLModel {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text(LocalizedStringKey("Sampling unavailable for Argmax models"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            VStack(alignment: .leading, spacing: 8) {
                                sliderRow("Temperature", value: $settings.temperature, range: 0...2, step: 0.05)
                                Text("Creativity: \(settings.temperature, format: .number.precision(.fractionLength(2))). Low values focus responses; high values add variety.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                sliderRow("Top-p", value: $settings.topP, range: 0...1, step: 0.01)
                                Text("Top-p: \(settings.topP, format: .number.precision(.fractionLength(2)))")
                                    .font(.footnote.monospacedDigit())
                            }

                            Stepper(value: $settings.topK, in: 1...2048, step: 1) {
                                Text("Top-k: \(settings.topK)")
                            }

                            if supportsMinP {
                                VStack(alignment: .leading, spacing: 8) {
                                    sliderRow("Min-p", value: $settings.minP, range: 0...1, step: 0.01)
                                    Text("Min-p: \(settings.minP, format: .number.precision(.fractionLength(2)))")
                                        .font(.footnote.monospacedDigit())
                                }
                            }

                            Stepper(
                                value: Binding(
                                    get: { Double(settings.repetitionPenalty) },
                                    set: { settings.repetitionPenalty = Float($0) }
                                ),
                                in: 0.8...2.0,
                                step: 0.05
                            ) {
                                Text("Repetition penalty: \(Double(settings.repetitionPenalty), format: .number.precision(.fractionLength(2)))")
                            }

                            Stepper(value: $settings.repeatLastN, in: 0...4096, step: 16) {
                                Text("Repeat last N tokens: \(settings.repeatLastN)")
                            }

                            if supportsPresencePenalty {
                                Stepper(
                                    value: Binding(
                                        get: { Double(settings.presencePenalty) },
                                        set: { settings.presencePenalty = Float($0) }
                                    ),
                                    in: -2.0...2.0,
                                    step: 0.1
                                ) {
                                    Text("Presence penalty: \(Double(settings.presencePenalty), format: .number.precision(.fractionLength(1)))")
                                }
                            }

                            if supportsFrequencyPenalty {
                                Stepper(
                                    value: Binding(
                                        get: { Double(settings.frequencyPenalty) },
                                        set: { settings.frequencyPenalty = Float($0) }
                                    ),
                                    in: -2.0...2.0,
                                    step: 0.1
                                ) {
                                    Text("Frequency penalty: \(Double(settings.frequencyPenalty), format: .number.precision(.fractionLength(1)))")
                                }
                            }

                            Text("Smooth loops and phrase echo by balancing repetition controls.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(model == nil)
            }

            private var speculativeSection: some View {
                sidebarSection(title: "Speculative Decoding", systemImage: "bolt.fill") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Speed up generation with a helper model or Multi-Token Prediction.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Picker("Speculative Mode", selection: speculativeSelectionBinding) {
                            ForEach(ModelSettings.SpeculativeDecodingSettings.Selection.allCases) { selection in
                                Text(selection.title).tag(selection)
                                    .disabled(selection == .mtp && !modelHasMTPSupport)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onAppear { enforceSpeculativeSelectionAvailability() }
                        .onChange(of: modelHasMTPSupport) { _ in enforceSpeculativeSelectionAvailability() }

                        if !modelHasMTPSupport {
                            mtpUnavailableNotice
                        }

                        if settings.speculativeDecoding.selection == .mtp {
                            Stepper(value: $settings.speculativeDecoding.mtpDraftNMax, in: 1...6, step: 1) {
                                Text(String.localizedStringWithFormat(String(localized: "MTP draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMax)"))
                            }
                            Stepper(value: $settings.speculativeDecoding.mtpDraftNMin, in: 0...6, step: 1) {
                                Text(String.localizedStringWithFormat(String(localized: "MTP min draft tokens: %@"), "\(settings.speculativeDecoding.resolvedMTPDraftNMin)"))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String.localizedStringWithFormat(String(localized: "MTP draft probability floor: %@"), String(format: "%.2f", settings.speculativeDecoding.resolvedMTPDraftPMin)))
                                Slider(value: $settings.speculativeDecoding.mtpDraftPMin, in: 0.0...1.0, step: 0.05)
                                Text("Lower values let the MTP head draft more tokens before bailing (more speculation, lower per-token acceptance). 0.75 is the conservative llama.cpp default.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if settings.speculativeDecoding.selection == .helperDraftModel {
                        Picker("Helper Model", selection: Binding(
                            get: { settings.speculativeDecoding.helperModelID },
                            set: { settings.speculativeDecoding.helperModelID = $0 }
                        )) {
                            Text("None").tag(String?.none)
                            ForEach(helperOptions, id: \.id) { candidate in
                                Text(candidate.name).tag(String?.some(candidate.id))
                            }
                        }

                        if helperOptions.isEmpty {
                            Text("Install another model with the same architecture and equal or smaller size to enable speculative decoding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if settings.speculativeDecoding.helperModelID != nil {
                            Picker("Draft strategy", selection: $settings.speculativeDecoding.mode) {
                                ForEach(ModelSettings.SpeculativeDecodingSettings.Mode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            Stepper(value: $settings.speculativeDecoding.value, in: 1...2048, step: 1) {
                                switch settings.speculativeDecoding.mode {
                                case .tokens:
                                    Text("Draft tokens: \(settings.speculativeDecoding.value)")
                                case .max:
                                    Text("Draft window: \(settings.speculativeDecoding.value)")
                                }
                            }
                        }
                        }
                    }
                }
            }

            private var speculativeSelectionBinding: Binding<ModelSettings.SpeculativeDecodingSettings.Selection> {
                Binding(
                    get: {
                        if settings.speculativeDecoding.selection == .mtp, !modelHasMTPSupport {
                            return .off
                        }
                        return settings.speculativeDecoding.selection
                    },
                    set: { selection in
                        settings.speculativeDecoding.selection = (selection == .mtp && !modelHasMTPSupport) ? .off : selection
                    }
                )
            }

            @ViewBuilder
            private var mtpUnavailableNotice: some View {
                Label {
                    Text("MTP is unavailable for this model. Choose another GGUF with an MTP head or bundled MTP weights. Helper-model speculative decoding is still available.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            private func enforceSpeculativeSelectionAvailability() {
                if settings.speculativeDecoding.selection == .mtp, !modelHasMTPSupport {
                    settings.speculativeDecoding.selection = .off
                }
            }


            private func sidebarSection<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
                VStack(alignment: .leading, spacing: 16) {
                    Label(title, systemImage: systemImage)
                        .font(.subheadline.weight(.semibold))
                    content()
                }
            }

            private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                    Slider(value: value, in: range, step: step)
                        .padding(.vertical, 2)
                }
            }
        }
#endif

        private var sidebar: some View {
            return VStack(alignment: .leading) {
                HStack {
                    Text("Recent Chats").font(.headline)
                    Spacer()
                    Button(action: { vm.startNewSession() }) { Image(systemName: "plus") }
                }
                .padding()
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextField(LocalizedStringKey("Search chats"), text: $chatRecallQuery)
                        .platformAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .font(.caption)
                    if !chatRecallQuery.isEmpty {
                        Button {
                            chatRecallQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LocalizedStringKey("Clear Chat Search"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal)
                .padding(.bottom, 4)

                List(selection: $vm.activeSessionID) {
                    if !chatRecallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section(LocalizedStringKey("Chat Recall")) {
                            if chatRecallResults.isEmpty {
                                Text(LocalizedStringKey("No matching messages"))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(chatRecallResults.prefix(8)) { result in
                                    Button {
                                        openRecallResult(result)
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack(spacing: 5) {
                                                Image(systemName: result.message.isBookmarked ? "bookmark.fill" : "text.magnifyingglass")
                                                    .font(.caption2)
                                                    .foregroundStyle(Color.accentColor)
                                                Text(sessionDisplayTitle(for: result.session))
                                                    .font(.caption.weight(.semibold))
                                                    .lineLimit(1)
                                            }
                                            Text(bookmarkPreview(for: result.message))
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(LocalizedStringKey("Chat search result"))
                                }
                            }
                        }
                    }

                    if !bookmarkedMessages.isEmpty {
                        Section(LocalizedStringKey("Bookmarks")) {
                            ForEach(bookmarkedMessages.prefix(8)) { bookmark in
                                Button {
                                    openBookmark(bookmark)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "bookmark.fill")
                                                .font(.caption2)
                                                .foregroundStyle(Color.accentColor)
                                            Text(sessionDisplayTitle(for: bookmark.session))
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                        }
                                        Text(bookmarkPreview(for: bookmark.message))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    ForEach(vm.sessions) { session in
                        HStack {
                            Image(systemName: session.isFavorite ? "star.fill" : "message")
                            Text(session.title)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.select(session)
                            withAnimation { showSidebar = false }
                        }
                        .contextMenu {
                            Button(session.isFavorite ? "Unfavorite" : "Favorite") { vm.toggleFavorite(session) }
                            Button(role: .destructive) { sessionToDelete = session } label: { Text("Delete") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { sessionToDelete = session } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
                .listStyle(.plain)
                .confirmationDialog("Delete chat \(sessionToDelete?.title ?? "")?", isPresented: Binding(get: { sessionToDelete != nil }, set: { if !$0 { sessionToDelete = nil } })) {
                    Button("Delete", role: .destructive) { if let s = sessionToDelete { vm.delete(s); sessionToDelete = nil } }
                    Button("Cancel", role: .cancel) { sessionToDelete = nil }
                }
            }
            .frame(maxHeight: .infinity)
            .background(Color(uiColor: .systemBackground))
            .ignoresSafeArea(edges: .bottom)
        }
        
        
    }
    
    // MARK: - Citation UI
    private struct SuggestionsOverlay: View {
        let suggestions: [String]
        let enabled: Bool
        let onTap: (String) -> Void
        let onDisabledTap: () -> Void
        
        var body: some View {
            VStack(spacing: 20) {
                Image("Noema")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)
                    .opacity(0.9)
                    .accessibilityHidden(true)
                
                VStack(spacing: 12) {
                    ForEach(suggestions.prefix(3), id: \.self) { s in
                        Button(action: {
                            if enabled {
                                onTap(s)
                            } else {
                                onDisabledTap()
                            }
                        }) {
                            Text(s)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 16)
                                .frame(maxWidth: 520)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color(.systemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 4)
                        .padding(.horizontal)
                        .opacity(enabled ? 1.0 : 0.6)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }
    
    private struct RAGDecisionBox: View {
        let info: ChatVM.Msg.RAGInjectionInfo
        @Environment(\.colorScheme) private var colorScheme
        @State private var isExpanded = false

        private var surfaceColor: Color {
            Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.04)
        }

        private var borderColor: Color {
            Color.primary.opacity(colorScheme == .dark ? 0.16 : 0.09)
        }

        private var accentColor: Color {
            switch info.stage {
            case .deciding:
                return .orange
            case .chosen, .injected:
                switch info.method {
                case .fullContent:
                    return .green
                case .rag:
                    return .blue
                case .none:
                    return .orange
                }
            }
        }

        private var titleText: String {
            switch info.stage {
            case .deciding:
                return "Choosing context strategy"
            case .chosen, .injected:
                switch info.method {
                case .fullContent:
                    return "Using full document"
                case .rag:
                    if info.retrievedChunkCount > 0 && info.injectedChunkCount < info.retrievedChunkCount {
                        return "Using smart retrieval • \(info.injectedChunkCount) of \(info.retrievedChunkCount) chunks fit"
                    }
                    return "Using smart retrieval"
                case .none:
                    return "Choosing context strategy"
                }
            }
        }

        private var modeText: String {
            switch info.method {
            case .fullContent:
                return "Full Document"
            case .rag:
                return "Smart Retrieval"
            case .none:
                return "Pending"
            }
        }

        private var stageText: String {
            switch info.stage {
            case .deciding:
                return "Deciding"
            case .chosen:
                return "Chosen"
            case .injected:
                return "Injected"
            }
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: info.stage == .deciding ? "hourglass" : "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("RETRIEVAL")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .tracking(0.5)
                            .foregroundStyle(.secondary)
                        Text(titleText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }

                if isExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        detailRow("Dataset", info.datasetName)
                        detailRow("Mode", modeText)
                        detailRow("Stage", stageText)
                        detailRow("Requested chunks", "\(info.requestedMaxChunks)")
                        detailRow("Retrieved chunks", "\(info.retrievedChunkCount)")
                        detailRow("Injected chunks", "\(info.injectedChunkCount)")
                        detailRow("Trimmed chunks", "\(info.trimmedChunkCount)")
                        detailRow(String(localized: "Configured context"), "\(info.configuredContextTokens) tok")
                        detailRow(String(localized: "Reserved for response"), "\(info.reservedResponseTokens) tok")
                        detailRow(String(localized: "Usable prompt budget"), "\(info.contextBudgetTokens) tok")
                        detailRow("Injected context", "\(info.injectedContextTokens) tok")
                        if let fullEstimate = info.fullContentEstimateTokens {
                            detailRow("Full document estimate", "\(fullEstimate) tok")
                        }
                        if info.partialChunkInjected {
                            Text("Only a partial excerpt of the top chunk fit in the prompt budget.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(info.decisionReason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(surfaceColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(borderColor, lineWidth: 0.9)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onTapGesture {
                isExpanded.toggle()
            }
            .accessibilityAddTraits(.isButton)
        }

        @ViewBuilder
        private func detailRow(_ label: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    // URLSession downloadWithProgress moved to URLSession+DownloadWithProgress.swift
    
    // Helper functions for global indexing overlay
    private func globalStageColor(_ stage: DatasetProcessingStage, current: DatasetProcessingStage) -> Color {
        switch (stage, current) {
        case (.extracting, .extracting), (.compressing, .compressing), (.embedding, .embedding):
            return .blue
        case (.extracting, .compressing), (.extracting, .embedding), (.compressing, .embedding):
            return .green
        default:
            return .gray.opacity(0.3)
        }
    }
    
    private func globalStageLabel(_ stage: DatasetProcessingStage) -> String {
        switch stage {
        case .extracting: return "Extracting"
        case .compressing: return "Compressing"
        case .embedding: return "Embedding"
        case .completed: return "Ready"
        case .failed: return "Failed"
        }
    }
    
}

#endif
