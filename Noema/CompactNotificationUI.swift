import SwiftUI

struct NotificationProgressBar: View {
    let value: Double
    var height: CGFloat = 8

    @Environment(\.colorScheme) private var colorScheme

    private var clampedValue: Double {
        max(0, min(1, value))
    }

    var body: some View {
#if os(macOS)
        IndustrialProgressBar(value: clampedValue, tint: .accentColor)
            .animation(.easeOut(duration: 0.14), value: clampedValue)
#else
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(trackColor)

                Capsule()
                    .fill(vibrantBlueGradient)
                    .frame(width: geo.size.width * clampedValue)
                    .overlay(
                        Capsule()
                            .fill(Color.white.opacity(0.35))
                            .blur(radius: 1.2)
                            .frame(width: 20),
                        alignment: .trailing
                    )
                    .shadow(color: vibrantBlue.opacity(0.42), radius: 6, x: 0, y: 2)
                    .animation(.easeOut(duration: 0.14), value: clampedValue)
            }
        }
        .frame(height: height)
#endif
    }

    private var vibrantBlue: Color {
        Color(red: 0.07, green: 0.56, blue: 1.0)
    }

    private var vibrantBlueGradient: LinearGradient {
        LinearGradient(
            colors: [
                vibrantBlue,
                Color(red: 0.0, green: 0.75, blue: 1.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private var trackColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.16)
            : Color.black.opacity(0.12)
    }
}

private struct CompactStatusTextModifier: ViewModifier {
    let minimumScaleFactor: CGFloat
    let alignment: TextAlignment

    func body(content: Content) -> some View {
        content
            .lineLimit(1)
            .minimumScaleFactor(minimumScaleFactor)
            .allowsTightening(true)
            .truncationMode(.tail)
            .multilineTextAlignment(alignment)
    }
}

extension View {
    func compactStatusText(
        minimumScaleFactor: CGFloat = 0.8,
        alignment: TextAlignment = .leading
    ) -> some View {
        modifier(CompactStatusTextModifier(minimumScaleFactor: minimumScaleFactor, alignment: alignment))
    }
}
