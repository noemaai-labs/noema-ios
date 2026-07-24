import Foundation

// OpenAI-style multimodal content parts for remote chat requests, mirroring
// the GGUF loopback's makeLoopbackImageObject/loopbackImagePayload: attached
// files are re-normalized to ≤1600px JPEG (near no-op — the composer already
// stores them that way) and shipped as base64 data: URLs.

enum RemoteImageEncoding {
    struct Payload {
        let data: Data
        let mime: String
    }

    /// `{"type":"image_url","image_url":{"url":"data:<mime>;base64,…"}}`,
    /// nil when the file can't be read at all.
    static func imageContentObject(forPath path: String) -> [String: Any]? {
        guard let payload = payload(forPath: path) else { return nil }
        let b64 = payload.data.base64EncodedString()
        return [
            "type": "image_url",
            "image_url": ["url": "data:\(payload.mime);base64,\(b64)"]
        ]
    }

    /// Raw base64 (no data: URL wrapper) — Ollama's chat API takes bare
    /// base64 strings in `messages[].images`.
    static func base64Payload(forPath path: String) -> String? {
        payload(forPath: path)?.data.base64EncodedString()
    }

    static func payload(forPath path: String) -> Payload? {
        let fileURL = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            Task { await logger.log("[Images][Remote] unreadable attachment path=\(fileURL.lastPathComponent)") }
            return nil
        }
        if let normalized = AttachmentImageNormalizer.normalizeAttachmentData(data) {
            return Payload(data: normalized.data, mime: "image/jpeg")
        }
        let mime: String
        switch fileURL.pathExtension.lowercased() {
        case "png": mime = "image/png"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        return Payload(data: data, mime: mime)
    }
}
