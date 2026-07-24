import Foundation
import Darwin

@objc protocol MCPProcessHostXPCProtocol {
    func launch(
        executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
        withReply reply: @escaping (NSNumber?, FileHandle?, FileHandle?, FileHandle?, String?) -> Void
    )
    func terminate(processID: NSNumber, withReply reply: @escaping () -> Void)
    func terminateAll(withReply reply: @escaping () -> Void)
}

final class MCPProcessHostSession: NSObject, MCPProcessHostXPCProtocol {
    private let lock = NSLock()
    private var processes: Set<Int32> = []

    func launch(
        executable: String, arguments: [String], environment: [String: String], workingDirectory: String?,
        withReply reply: @escaping (NSNumber?, FileHandle?, FileHandle?, FileHandle?, String?) -> Void
    ) {
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            reply(nil, nil, nil, nil, "The selected executable is missing or is not executable."); return
        }
        var stdoutFD: Int32 = -1, stdinFD: Int32 = -1, stderrFD: Int32 = -1, errorNumber: Int32 = 0
        let allArguments = [executable] + arguments
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let pid: pid_t = withMutableCStringArray(allArguments) { argv in
            withMutableCStringArray(environmentStrings) { envp in
                executable.withCString { executablePointer in
                    if let workingDirectory {
                        return workingDirectory.withCString { directoryPointer in
                            noema_mcp_spawn(executablePointer, argv, envp, directoryPointer, &stdoutFD, &stdinFD, &stderrFD, &errorNumber)
                        }
                    }
                    return noema_mcp_spawn(executablePointer, argv, envp, nil, &stdoutFD, &stdinFD, &stderrFD, &errorNumber)
                }
            }
        }
        guard pid > 0 else {
            reply(nil, nil, nil, nil, String(cString: strerror(errorNumber))); return
        }
        _ = lock.withLock { processes.insert(pid) }
        reply(
            NSNumber(value: pid), FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: true),
            FileHandle(fileDescriptor: stdinFD, closeOnDealloc: true), FileHandle(fileDescriptor: stderrFD, closeOnDealloc: true), nil
        )
    }

    func terminate(processID: NSNumber, withReply reply: @escaping () -> Void) {
        terminateGroup(processID.int32Value); reply()
    }

    func terminateAll(withReply reply: @escaping () -> Void) {
        let snapshot = lock.withLock { let copy = processes; processes.removeAll(); return copy }
        for pid in snapshot { terminateGroup(pid) }
        reply()
    }

    private func terminateGroup(_ pid: Int32) {
        _ = lock.withLock { processes.remove(pid) }
        guard pid > 1 else { return }
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) } }
    }

    private func withMutableCStringArray<Result>(_ strings: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result) -> Result {
        let pointers = strings.map { strdup($0)! }
        defer { pointers.forEach { free($0) } }
        var terminated: [UnsafeMutablePointer<CChar>?] = pointers.map(Optional.some) + [nil]
        return terminated.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}

final class MCPProcessHostListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let session = MCPProcessHostSession()
        connection.exportedInterface = NSXPCInterface(with: MCPProcessHostXPCProtocol.self)
        connection.exportedObject = session
        // One exported session owns only the process groups launched through
        // that connection. Closing one server therefore cannot stop its peers,
        // while app exit invalidates every session and still tears down all trees.
        connection.invalidationHandler = { session.terminateAll {} }
        connection.interruptionHandler = { session.terminateAll {} }
        connection.resume()
        return true
    }
}

let listener = NSXPCListener.service()
let listenerDelegate = MCPProcessHostListenerDelegate()
listener.delegate = listenerDelegate
listener.resume()
