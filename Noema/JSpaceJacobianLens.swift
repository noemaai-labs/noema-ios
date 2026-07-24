#if canImport(MLXLLM) && canImport(MLXLMCommon)
import Foundation
import MLX

final class JSpaceJacobianLens {
    let manifest: JSpaceLensManifest
    let path: String
    private let matrices: [Int: MLXArray]   // source layer -> [d, d] (fp32)

    init(manifest: JSpaceLensManifest, matrices: [Int: MLXArray], path: String) {
        self.manifest = manifest
        self.matrices = matrices
        self.path = path
    }

    /// J_l for a resid_post block index, or nil if this layer wasn't fitted.
    func matrix(_ layer: Int) -> MLXArray? { matrices[layer] }

    var softcap: Float? {
        guard let c = manifest.finalLogitSoftcapping, c > 0 else { return nil }
        return Float(c)
    }

    static func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("manifest.json")
    }

    /// Cheap: decode just the manifest (for dimension validation before the heavy load).
    static func readManifest(directory: URL) throws -> JSpaceLensManifest {
        let data = try Data(contentsOf: manifestURL(in: directory))
        return try JSONDecoder().decode(JSpaceLensManifest.self, from: data)
    }

    /// Heavy: load every fitted matrix. Call off the main thread.
    static func load(directory: URL) throws -> JSpaceJacobianLens {
        let manifest = try readManifest(directory: directory)
        let safetensors = directory.appendingPathComponent("jacobians.safetensors")
        let arrays = try loadArrays(url: safetensors)
        var matrices: [Int: MLXArray] = [:]
        for (key, value) in arrays {
            // keys are "layer_<N>"
            guard let n = Int(key.split(separator: "_").last.map(String.init) ?? "") else { continue }
            matrices[n] = value.asType(.float32)
        }
        guard !matrices.isEmpty else {
            throw JSpaceLensError.emptyLens
        }
        return JSpaceJacobianLens(manifest: manifest, matrices: matrices, path: directory.path)
    }
}

enum JSpaceLensError: Error { case emptyLens }

/// Process-wide cache: loading a multi-GB lens is expensive, so keep the last one
/// resident and reuse it across generations (all installs run serialized inside
/// ModelContainer.perform, so contention is nil; the lock is belt-and-suspenders).
final class JSpaceJacobianLensStore: @unchecked Sendable {
    static let shared = JSpaceJacobianLensStore()
    private let lock = NSLock()
    private var cached: JSpaceJacobianLens?

    /// Returns the lens for `path`, loading+caching on first use. Reports load
    /// success/failure to the UI via the runtime.
    func lens(atPath path: String?) -> JSpaceJacobianLens? {
        guard let path, !path.isEmpty else { return nil }
        lock.lock()
        if let cached, cached.path == path { lock.unlock(); return cached }
        lock.unlock()

        do {
            let loaded = try JSpaceJacobianLens.load(directory: URL(fileURLWithPath: path))
            lock.lock(); cached = loaded; lock.unlock()
            JSpaceLensRuntime.shared.reportLensStatus(
                .loaded(base: loaded.manifest.baseModel, layers: loaded.manifest.sourceLayers.count)
            )
            return loaded
        } catch {
            JSpaceLensRuntime.shared.reportLensStatus(.failed(reason: "\(error)"))
            return nil
        }
    }
}
#endif
