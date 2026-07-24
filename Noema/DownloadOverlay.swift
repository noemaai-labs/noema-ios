import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

struct DownloadOverlay: View {
    @EnvironmentObject var controller: DownloadController
    @ObservedObject private var presentationUpdates = DownloadPresentationUpdates.shared

    var body: some View {
        if controller.showOverlay {
            VStack {
                Button(action: { controller.openList() }) {
#if os(macOS)
                    statusChip
#else
                    statusCircle
#endif
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Downloads"))
                .accessibilityValue(Text(verbatim: "\(Int(controller.overallProgress * 100))%"))
            }
            // Keep the visual offset from the edge, but don't expand the button's tappable area.
            .padding(12)
        }
    }

#if os(macOS)
    private var statusChip: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let tint: Color = controller.allCompleted ? .green : .accentColor
        return HStack(spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(verbatim: "\(Int(controller.overallProgress * 100))%")
                .industrialStat()
                .monospacedDigit()
            IndustrialProgressBar(value: controller.overallProgress, tint: tint)
                .frame(width: 56)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(shape.fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .contentShape(shape)
    }
#else
    private var statusCircle: some View {
        ZStack {
            Circle()
                .fill(.thinMaterial)
                .frame(width: 50, height: 50)
                .applyGlassIfAvailable()
            if controller.allCompleted {
                Image(systemName: "checkmark")
                    .font(.title2)
                    .foregroundColor(.green)
            } else {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 40, height: 40)
                    Circle()
                        .trim(from: 0, to: CGFloat(controller.overallProgress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 40, height: 40)
                    Text("\(Int(controller.overallProgress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.primary)
                }
            }
        }
    }
#endif
}

#if !os(macOS)
private extension View {
    @ViewBuilder
    func applyGlassIfAvailable() -> some View {
        #if os(visionOS)
        self.background(.regularMaterial, in: Circle())
        #elseif os(iOS)
        if #available(iOS 26.0, *) {
            // `glassEffect` is currently flaky on iPadOS 26.x (rotation / modal overlap glitches).
            // Prefer the stable material fallback on iPad until Apple irons this out.
            if UIDevice.current.userInterfaceIdiom == .pad {
                self.background(.regularMaterial, in: Circle())
            } else {
                self.glassEffect(.regular, in: Circle())
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
#endif
