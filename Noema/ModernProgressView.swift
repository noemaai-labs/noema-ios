import SwiftUI

/// A modern progress view with fluid animations
struct ModernProgressView: View {
    let value: Double
    var tint: Color = .accentColor
    var height: CGFloat = 4
    
    @State private var animatedValue: Double = 0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.gray.opacity(0.2))
                    .frame(height: height)
                
                // Progress fill – use a short linear animation instead of spring
                // to avoid continuous 60fps rendering that causes scroll jank.
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [tint, tint.opacity(0.8)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geometry.size.width * animatedValue, height: height)
                    .animation(.linear(duration: 0.2), value: animatedValue)
                
                // Shimmer effect
                if animatedValue > 0 && animatedValue < 1 {
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    Color.white.opacity(0),
                                    Color.white.opacity(0.3),
                                    Color.white.opacity(0)
                                ]),
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * 0.3, height: height)
                        .offset(x: geometry.size.width * animatedValue - geometry.size.width * 0.15)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            animatedValue = value
        }
        .onChange(of: value) { newValue in
            animatedValue = newValue
        }
    }
}

/// A modern circular progress indicator
struct ModernCircularProgressView: View {
    @State private var rotation: Double = 0
    @State private var trimEnd: Double = 0.1
    var size: CGFloat = 40
    var lineWidth: CGFloat = 3
    var tint: Color = .accentColor
    
    var body: some View {
        Circle()
            .trim(from: 0, to: trimEnd)
            .stroke(
                LinearGradient(
                    gradient: Gradient(colors: [tint, tint.opacity(0.5)]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    trimEnd = 0.8
                }
            }
    }
}

/// A download progress view with percentage
struct ModernDownloadProgressView: View {
    let progress: Double
    let speed: Double? // MB/s
    var showPercentage: Bool = true
    
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                if showPercentage {
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 40, alignment: .leading)
                }
                
                Spacer(minLength: 6)

                ZStack(alignment: .trailing) {
                    Text(Self.speedWidthTemplate)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .hidden()

                    Text(speedText)
                        .font(.caption2)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.secondary)
                }
            }
            
            ModernProgressView(value: progress)
        }
    }
}

struct ProcessingPromptCardView: View {
    let progress: Double

    @Environment(\.colorScheme) private var colorScheme

    private var clampedProgress: Double {
        min(1.0, max(0.0, progress))
    }

    private var surfaceColor: Color {
        colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.97)
    }

    private var surfaceBorderColor: Color {
        Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.10)
    }

    private var secondaryColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.68) : Color.black.opacity(0.58)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.82)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.1) : Color.black.opacity(0.04)
    }

#if os(macOS)
    private static let cardRadius: CGFloat = 10
#else
    private static let cardRadius: CGFloat = 18
#endif

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.below.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(secondaryColor)
                    Text(LocalizedStringKey("Processing Prompt"))
#if os(macOS)
                        .textCase(.uppercase)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.3)
#else
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
#endif
                        .foregroundStyle(primaryTextColor)
                }

                Spacer()

                Text("\(Int(clampedProgress * 100))%")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(secondaryColor)
            }

#if os(macOS)
            IndustrialProgressBar(value: clampedProgress)
#else
            ModernProgressView(
                value: clampedProgress,
                tint: .accentColor,
                height: 3
            )
            .frame(height: 3)
#endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(surfaceColor)
        .clipShape(RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cardRadius, style: .continuous)
                .strokeBorder(surfaceBorderColor, lineWidth: 0.6)
        )
#if !os(macOS)
        .shadow(color: shadowColor, radius: 8, x: 0, y: 4)
#endif
    }
}

private extension ModernDownloadProgressView {
    static let speedWidthTemplate = "999.9 MB/s"

    var speedText: String {
        guard let speed, speed > 0 else { return "" }
        return Self.formattedSpeedText(speed)
    }

    static func formattedSpeedText(_ bytesPerSecond: Double) -> String {
        // Convert to KB/s or MB/s for display
        let kbps = bytesPerSecond / 1_024.0
        if kbps > 1_024.0 {
            return String(format: "%.1f MB/s", kbps / 1_024.0)
        }
        return String(format: "%.0f KB/s", kbps)
    }
}

// View modifier to easily apply modern progress styling
extension View {
    func modernProgress() -> some View {
        self.progressViewStyle(ModernProgressViewStyle())
    }
}

struct ModernProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if let fractionCompleted = configuration.fractionCompleted {
            ModernProgressView(value: fractionCompleted)
        } else {
            ModernCircularProgressView()
        }
    }
}
