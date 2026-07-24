import Foundation

struct DeviceGPUInfo {
    static let unsupportedModels: Set<String> = [
        // iPhone (below A13)
        "iPhone10,3", "iPhone10,6", // iPhone X
        "iPhone11,2", // iPhone XS
        "iPhone11,4", "iPhone11,6", // iPhone XS Max
        "iPhone11,8", // iPhone XR
        // iPad (below A13)
        "iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4", // iPad Pro 11" (1st gen)
        "iPad8,9", "iPad8,10", // iPad Pro 11" (2nd gen)
        "iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8", // iPad Pro 12.9" (3rd gen)
        "iPad8,11", "iPad8,12", // iPad Pro 12.9" (4th gen)
        "iPad11,3", "iPad11,4", // iPad Air (3rd gen)
        "iPad7,11", "iPad7,12", // iPad (7th gen)
        "iPad11,6", "iPad11,7", // iPad (8th gen)
        "iPad11,1", "iPad11,2" // iPad mini (5th gen)
    ]

    static var supportsGPUOffload: Bool {
        let id = hardwareIdentifier()
        return !unsupportedModels.contains(id)
    }

    /// Pre-A13 devices cannot reliably JIT MLX bfloat16 kernels.
    /// Force float16 on these models to avoid Metal compiler crashes.
    static var requiresFloat16: Bool { !supportsGPUOffload }

    private static func hardwareIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}
