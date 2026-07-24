import SwiftUI
import Combine

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

// MARK: - Model metadata
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


// MARK: - One-shot downloader
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
                // Stage next to the destination: interrupted transfers resume from the
                // partial (Range) or from resume data keyed by jobID/artifactID, and an
                // unvalidated file never sits at the final path.
                let staging = dest.appendingPathExtension("download")
                // Resume blobs persist to a flat file named "<jobID>-<artifactID>.resume";
                // a slash from the repo id would break that path.
                let jobID   = "starter:\(item.repo.replacingOccurrences(of: "/", with: "-"))"

                if verboseLogging { print("[Downloader] ▶︎ \(item.file)") }
                do {
                    try await BackgroundDownloadManager.shared.download(
                        from: remote,
                        to: staging,
                        jobID: jobID,
                        artifactID: item.file
                    ) { part in
                        Task { @MainActor in
                            self.fractions[idx] = part
                            if self.state.isDownloading {
                                self.state = .downloading(self.fractions.reduce(0, +) / total)
                            }
                        }
                    }
                    if dest.pathExtension.lowercased() == "gguf" {
                        let magic: Data = try {
                            let fh = try FileHandle(forReadingFrom: staging)
                            defer { try? fh.close() }
                            return (try? fh.read(upToCount: 4)) ?? Data()
                        }()
                        guard magic == Data("GGUF".utf8) else {
                            try? FileManager.default.removeItem(at: staging)
                            throw URLError(.cannotParseResponse)
                        }
                    }
                    try FileManager.default.moveItemReplacing(at: dest, from: staging)
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

// MARK: - FileManager helpers
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
