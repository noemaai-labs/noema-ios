import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(MLX)
import MLX
#endif

/// Shared launch configuration applied by both the iOS and visionOS entry points.
/// The routine mirrors the previous implementation from `Noema.swift` so that
/// the visionOS target can access it without pulling in the entire iOS app file.
func configureSharedApplicationEnvironment() {
#if canImport(MLX)
    // On non-compatible devices (pre-A13), force CPU execution to avoid Metal
    // JIT issues with bfloat16 kernels.
    if !DeviceGPUInfo.supportsGPUOffload {
        Device.setDefault(device: Device(.cpu))
    }
#endif
    // Initialize tool system once at startup; registration is handled by ToolRegistrar.
    Task { @MainActor in
        await ToolRegistrar.shared.initializeTools()
    }

    // Apply network kill switch at launch based on stored offGrid setting.
    let off = UserDefaults.standard.object(forKey: "offGrid") as? Bool ?? false
    NetworkKillSwitch.setEnabled(off)

    // Export HF_ENDPOINT for dependencies (e.g. WhisperKit's Hub client) when a
    // Hugging Face mirror/custom endpoint is configured.
    HFEndpoint.applyEnvironment()

    // Noema Teams: restore any cached enterprise policy (and its off-grid mapping)
    // before the first chat can start, then refresh from the workspace server.
    Task { @MainActor in
        _ = EnterprisePolicyManager.shared
    }

    // Prime RAM/device budget detection early so storage-tier overrides are ready.
    DeviceRAMInfo.primeCache()
}
