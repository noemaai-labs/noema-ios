// PythonExecutor.swift
import Foundation

/// Generated file metadata captured from a Python execution sandbox.
struct PythonExecutionArtifact: Codable, Equatable, Sendable, Identifiable {
    let relativePath: String
    let filename: String
    let kind: String
    let mimeType: String?
    let sizeBytes: Int64
    let preview: String?
    let base64Data: String?

    var id: String { relativePath }
}

/// Result of a Python execution
struct PythonExecutionResult: Codable, Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let executionTimeMs: Int
    let error: String?
    let timedOut: Bool
    let artifacts: [PythonExecutionArtifact]

    init(
        stdout: String,
        stderr: String,
        exitCode: Int32,
        executionTimeMs: Int,
        error: String?,
        timedOut: Bool,
        artifacts: [PythonExecutionArtifact] = []
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.executionTimeMs = executionTimeMs
        self.error = error
        self.timedOut = timedOut
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey {
        case stdout
        case stderr
        case exitCode
        case executionTimeMs
        case error
        case timedOut
        case artifacts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stdout = try container.decode(String.self, forKey: .stdout)
        stderr = try container.decode(String.self, forKey: .stderr)
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        executionTimeMs = try container.decode(Int.self, forKey: .executionTimeMs)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        timedOut = try container.decode(Bool.self, forKey: .timedOut)
        artifacts = try container.decodeIfPresent([PythonExecutionArtifact].self, forKey: .artifacts) ?? []
    }
}

/// Protocol for platform-specific Python execution backends
protocol PythonExecutor: Sendable {
    func execute(code: String, timeout: TimeInterval) async throws -> PythonExecutionResult
    var isAvailable: Bool { get }
}

let pythonSandboxAllowedRootEnvVar = "NOEMA_PYTHON_ALLOWED_ROOT"

/// Sandbox preamble injected before user code to restrict dangerous operations
let pythonSandboxPreamble = """
import sys as _sys
import os as _os
import builtins as _builtins
import pathlib as _pathlib
import sysconfig as _sysconfig

# Block dangerous modules via meta_path hook
_blocked_modules = frozenset({
    'socket', 'subprocess', 'shutil', 'http', 'urllib',
    'requests', 'smtplib', 'ftplib', 'xmlrpc', 'multiprocessing',
    'ctypes', 'signal', 'webbrowser', 'antigravity',
})

class _SandboxImportBlocker:
    def find_spec(self, name, path=None, target=None):
        top = name.split('.')[0]
        if top in _blocked_modules:
            raise ImportError(f"Module '{name}' is blocked in sandbox mode")
        return None

    def find_module(self, name, path=None):
        top = name.split('.')[0]
        if top in _blocked_modules:
            raise ImportError(f"Module '{name}' is blocked in sandbox mode")
        return None

_noema_restore_callbacks = []
_noema_import_blocker = _SandboxImportBlocker()
_sys.meta_path.insert(0, _noema_import_blocker)

def _noema_register_restore(target, attr, original):
    _noema_restore_callbacks.append((target, attr, original))

def _noema_normalize_path(path):
    if isinstance(path, int):
        return None
    if hasattr(path, '__fspath__'):
        path = path.__fspath__()
    if not isinstance(path, str):
        return None
    if not _os.path.isabs(path):
        path = _os.path.join(_os.getcwd(), path)
    return _os.path.realpath(path)

def _noema_allowed_roots():
    roots = []
    try:
        if '__noema_allowed_root' in globals():
            roots.append(globals()['__noema_allowed_root'])
    except Exception:
        pass
    env_root = _os.environ.get('NOEMA_PYTHON_ALLOWED_ROOT')
    if env_root:
        roots.append(env_root)
    for key in ('stdlib', 'platstdlib'):
        try:
            location = _sysconfig.get_path(key)
        except Exception:
            location = None
        if location:
            roots.append(location)
    normalized = []
    for root in roots:
        if not root:
            continue
        normalized_root = _os.path.realpath(root)
        if normalized_root not in normalized:
            normalized.append(normalized_root)
    return normalized

def _noema_ensure_path_allowed(path):
    normalized = _noema_normalize_path(path)
    if normalized is None:
        return path

    for allowed_root in _noema_allowed_roots():
        if normalized == allowed_root or normalized.startswith(allowed_root + _os.sep):
            return path

    raise PermissionError(f"File system access outside the sandbox is blocked: {normalized}")

_noema_original_open = _builtins.open
def _noema_sandbox_open(file, *args, **kwargs):
    _noema_ensure_path_allowed(file)
    return _noema_original_open(file, *args, **kwargs)
_noema_register_restore(_builtins, 'open', _builtins.open)
_builtins.open = _noema_sandbox_open

def _blocked_call(*a, **k):
    raise PermissionError("This operation is blocked in sandbox mode")

for _attr in (
    'system', 'popen', 'execl', 'execle', 'execlp', 'execlpe',
    'execv', 'execve', 'execvp', 'execvpe', 'kill', 'killpg', 'fork'
):
    if hasattr(_os, _attr):
        _noema_register_restore(_os, _attr, getattr(_os, _attr))
        setattr(_os, _attr, _blocked_call)

if hasattr(_os, 'forkpty'):
    _noema_register_restore(_os, 'forkpty', _os.forkpty)
    _os.forkpty = _blocked_call

def _noema_wrap_path_function(name):
    if not hasattr(_os, name):
        return
    original = getattr(_os, name)
    def _wrapped(path, *args, **kwargs):
        _noema_ensure_path_allowed(path)
        return original(path, *args, **kwargs)
    _noema_register_restore(_os, name, original)
    setattr(_os, name, _wrapped)

def _noema_wrap_path_pair(name):
    if not hasattr(_os, name):
        return
    original = getattr(_os, name)
    def _wrapped(src, dst, *args, **kwargs):
        _noema_ensure_path_allowed(src)
        _noema_ensure_path_allowed(dst)
        return original(src, dst, *args, **kwargs)
    _noema_register_restore(_os, name, original)
    setattr(_os, name, _wrapped)

for _attr in ('remove', 'unlink', 'mkdir', 'makedirs', 'rmdir', 'listdir', 'scandir', 'stat', 'lstat'):
    _noema_wrap_path_function(_attr)
for _attr in ('rename', 'replace'):
    _noema_wrap_path_pair(_attr)

if hasattr(_os, 'walk'):
    _noema_original_walk = _os.walk
    def _noema_sandbox_walk(top, *args, **kwargs):
        _noema_ensure_path_allowed(top)
        return _noema_original_walk(top, *args, **kwargs)
    _noema_register_restore(_os, 'walk', _os.walk)
    _os.walk = _noema_sandbox_walk

_noema_path_methods = (
    'open', 'read_text', 'write_text', 'read_bytes', 'write_bytes',
    'mkdir', 'unlink', 'rename', 'replace', 'iterdir'
)

for _method_name in _noema_path_methods:
    if not hasattr(_pathlib.Path, _method_name):
        continue
    _original = getattr(_pathlib.Path, _method_name)
    def _make_wrapper(method):
        def _wrapped(self, *args, **kwargs):
            _noema_ensure_path_allowed(self)
            return method(self, *args, **kwargs)
        return _wrapped
    _noema_register_restore(_pathlib.Path, _method_name, _original)
    setattr(_pathlib.Path, _method_name, _make_wrapper(_original))

def _noema_restore_sandbox():
    while _noema_restore_callbacks:
        target, attr, original = _noema_restore_callbacks.pop()
        setattr(target, attr, original)
    try:
        _sys.meta_path.remove(_noema_import_blocker)
    except ValueError:
        pass

del _blocked_call
del _attr
del _method_name
del _original
del _make_wrapper
del _pathlib
del _builtins
del _sysconfig
del _blocked_modules
del _sys
del _os

"""

enum PythonExecutionArtifactCollector {
    static let maxArtifacts = 12
    static let maxPreviewBytes = 32_768
    static let maxEmbeddedBytes = 700_000
    static let maxTotalEmbeddedBytes = 1_400_000

    static func collect(from rootURL: URL, excluding excludedRelativePaths: Set<String> = ["script.py"]) -> [PythonExecutionArtifact] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var artifacts: [PythonExecutionArtifact] = []
        var embeddedBytes = 0

        for case let fileURL as URL in enumerator {
            guard artifacts.count < maxArtifacts else { break }
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }

            let relativePath = normalizedRelativePath(for: fileURL, rootURL: rootURL)
            guard !excludedRelativePaths.contains(relativePath),
                  !relativePath.hasPrefix("__pycache__/"),
                  !relativePath.hasSuffix(".pyc") else {
                continue
            }

            let sizeBytes = Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let classification = classify(fileURL)
            let canEmbed = sizeBytes >= 0
                && sizeBytes <= Int64(maxEmbeddedBytes)
                && embeddedBytes + Int(sizeBytes) <= maxTotalEmbeddedBytes
            let data = canEmbed ? try? Data(contentsOf: fileURL) : nil
            let base64Data = classification.kind == "image" ? data?.base64EncodedString() : nil
            let preview = previewText(from: data, kind: classification.kind)

            if data != nil {
                embeddedBytes += max(0, Int(sizeBytes))
            }

            artifacts.append(
                PythonExecutionArtifact(
                    relativePath: relativePath,
                    filename: fileURL.lastPathComponent,
                    kind: classification.kind,
                    mimeType: classification.mimeType,
                    sizeBytes: sizeBytes,
                    preview: preview,
                    base64Data: base64Data
                )
            )
        }

        return artifacts
    }

    private static func normalizedRelativePath(for fileURL: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }

    private static func classify(_ fileURL: URL) -> (kind: String, mimeType: String?) {
        switch fileURL.pathExtension.lowercased() {
        case "png":
            return ("image", "image/png")
        case "jpg", "jpeg":
            return ("image", "image/jpeg")
        case "gif":
            return ("image", "image/gif")
        case "webp":
            return ("image", "image/webp")
        case "bmp":
            return ("image", "image/bmp")
        case "tif", "tiff":
            return ("image", "image/tiff")
        case "svg":
            return ("text", "image/svg+xml")
        case "csv":
            return ("table", "text/csv")
        case "tsv":
            return ("table", "text/tab-separated-values")
        case "json":
            return ("json", "application/json")
        case "jsonl":
            return ("text", "application/x-ndjson")
        case "txt", "md", "markdown", "log", "out", "err", "py":
            return ("text", "text/plain")
        default:
            return ("file", nil)
        }
    }

    private static func previewText(from data: Data?, kind: String) -> String? {
        guard kind != "image", let data, !data.isEmpty else { return nil }
        let previewData = data.prefix(maxPreviewBytes)
        guard let text = String(data: previewData, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
