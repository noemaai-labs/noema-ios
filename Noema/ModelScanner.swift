// ModelScanner.swift
import Foundation

enum ModelScanner {
    static func layerCount(for url: URL, format: ModelFormat) -> Int {
        switch format {
        case .gguf:
            let cCount = Int(gguf_layer_count(url.path))
            if cCount > 0 { return cCount }
            return GGUFMetadata.layerCount(at: url) ?? 0
        case .mlx, .et:
            return 0
        case .ane:
            return 0
        case .afm:
            return 0
        case .coreai:
            return 0
        }
    }

    static func moeInfo(for url: URL, format: ModelFormat) -> MoEInfo? {
        switch format {
        case .gguf:
            var target = url
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue {
                if let gguf = try? FileManager.default
                    .contentsOfDirectory(at: target, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension.lowercased() == "gguf" }) {
                    target = gguf
                }
            }
            return GGUFMetadata.moeInfo(at: target)
        case .mlx:
            return MLXMetadata.moeInfo(at: url)
        case .et, .ane, .afm, .coreai:
            return nil
        }
    }
}
