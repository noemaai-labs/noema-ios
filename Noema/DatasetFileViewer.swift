import SwiftUI
import Foundation
#if canImport(PDFKit)
import PDFKit
#endif
import QuickLook

struct DatasetFileViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var content: String = ""
    @State private var error: String?
    @State private var isMarkdown = false
    private var isPDF: Bool { url.pathExtension.lowercased() == "pdf" }
    private var isEPUB: Bool { url.pathExtension.lowercased() == "epub" }

    var body: some View {
        contentView
            .navigationTitle(url.lastPathComponent)
#if os(macOS)
            .overlay(alignment: .topLeading) { macBackButton }
#endif
    }

    @ViewBuilder
    private var contentView: some View {
        if isPDF {
            #if canImport(PDFKit)
            PDFViewer(url: url)
            #else
            Text("PDF viewing not supported on this platform")
            #endif
        } else if isEPUB {
            EPUBQuickLook(url: url)
        } else {
            ScrollView {
                if let error {
                    Text(error).foregroundStyle(.red)
                } else if isMarkdown {
                    Text((try? AttributedString(markdown: content, options: .init(interpretedSyntax: .full))) ?? AttributedString(content))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                } else {
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
            .task { load() }
        }
    }

    private func load() {
        if isPDF || isEPUB { return }
        let fileURL = url
        let ext = url.pathExtension.lowercased()
        Task { @MainActor in
            let result = await Self.parse(fileURL, ext: ext)
            self.error = result.error
            self.isMarkdown = result.isMarkdown
            self.content = result.content
        }
    }

    /// Read + format off the main thread — dataset corpora are multi-MB, and the previous
    /// synchronous `Data(contentsOf:)` + per-line JSONL pretty-print blocked the MainActor on push.
    nonisolated private static func parse(_ url: URL, ext: String) async -> (content: String, isMarkdown: Bool, error: String?) {
        await Task.detached(priority: .utility) { () -> (content: String, isMarkdown: Bool, error: String?) in
            guard let data = try? Data(contentsOf: url) else {
                return ("", false, "Unable to load file")
            }
            switch ext {
            case "md":
                return (String(decoding: data, as: UTF8.self), true, nil)
            case "json":
                if let obj = try? JSONSerialization.jsonObject(with: data),
                   let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
                   let str = String(data: pretty, encoding: .utf8) {
                    return (str, false, nil)
                }
                return (String(decoding: data, as: UTF8.self), false, nil)
            case "jsonl":
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map { line -> String in
                    if let objData = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: objData),
                       let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
                       let str = String(data: pretty, encoding: .utf8) {
                        return str
                    }
                    return String(line)
                }
                return (lines.joined(separator: "\n\n"), false, nil)
            default:
                return (String(decoding: data, as: UTF8.self), false, nil)
            }
        }.value
    }
}

#if canImport(PDFKit)
private struct PDFViewer: View {
    let url: URL
    var body: some View {
        #if canImport(UIKit)
        PDFKitRepresentable(url: url)
            .ignoresSafeArea(edges: .bottom)
        #elseif canImport(AppKit)
        PDFKitRepresentableMac(url: url)
            .ignoresSafeArea(edges: .bottom)
        #else
        Text("PDF viewing not supported on this platform")
        #endif
    }
}

#if canImport(UIKit)
private struct PDFKitRepresentable: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayDirection = .vertical
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(url: url)
        return v
    }
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}
#elseif canImport(AppKit)
private struct PDFKitRepresentableMac: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayDirection = .vertical
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(url: url)
        return v
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
    }
}
#endif

// MARK: - EPUB Quick Look

private struct EPUBQuickLook: View {
    let url: URL
    var body: some View {
        #if canImport(UIKit)
        QLPreviewRepresentable(url: url)
            .ignoresSafeArea(edges: .bottom)
        #elseif canImport(AppKit)
        QLPreviewRepresentableMac(url: url)
            .ignoresSafeArea(edges: .bottom)
        #else
        Text("EPUB viewing not supported on this platform")
        #endif
    }
}

#if canImport(UIKit)
import UIKit
import QuickLook
private struct QLPreviewRepresentable: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController()
        c.dataSource = context.coordinator
        return c
    }
    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return url as NSURL
        }
    }
}
#elseif canImport(AppKit)
import AppKit
import Quartz
private struct QLPreviewRepresentableMac: NSViewControllerRepresentable {
    let url: URL
    func makeNSViewController(context: Context) -> QLPreviewPanelHostController {
        return QLPreviewPanelHostController(url: url)
    }
    func updateNSViewController(_ nsViewController: QLPreviewPanelHostController, context: Context) {}
}

final class QLPreviewPanelHostController: NSViewController, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let url: URL
    private weak var panel: QLPreviewPanel?

    init(url: URL) { self.url = url; super.init(nibName: nil, bundle: nil) }
    // Created only programmatically (never from a coder/storyboard); fail loudly if
    // that assumption is ever violated instead of returning a silently broken controller.
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: View lifecycle
    override func viewDidAppear() {
        super.viewDidAppear()
        // Acquire the shared panel and present it; set delegates explicitly.
        if let p = QLPreviewPanel.shared() {
            panel = p
            p.dataSource = self
            p.delegate = self
            p.makeKeyAndOrderFront(nil)
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        // Ensure the panel is dismissed and delegates are released to break retain cycles.
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        }
        panel?.dataSource = nil
        panel?.delegate = nil
        panel = nil
    }

    deinit {
        // Defensive cleanup in case viewWillDisappear wasn’t called.
        if let p = QLPreviewPanel.shared(), (p.delegate === self || p.dataSource === self) {
            p.dataSource = nil
            p.delegate = nil
        }
    }

    // MARK: QLPreviewPanelDataSource
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem {
        return url as NSURL
    }
}
#endif
#endif

#if os(macOS)
private extension DatasetFileViewer {
    var macBackButton: some View {
        Button {
            dismiss()
        } label: {
            Label(LocalizedStringKey("Back"), systemImage: "chevron.left")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.leading, 12)
        .padding(.top, 12)
        .background(.thinMaterial, in: Capsule())
    }
}
#endif
