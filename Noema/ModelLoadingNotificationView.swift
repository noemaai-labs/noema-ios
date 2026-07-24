import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

// Cross-version helper for SwiftUI's onChange(old,new) added in iOS 17/macOS 14.
private struct OnChangeCompatibilityModifier<Value: Equatable>: ViewModifier {
    let value: Value
    let initial: Bool
    let action: (Value, Value) -> Void
    @State private var previous: Value?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if previous == nil {
                    previous = value
                    if initial {
                        action(value, value)
                    }
                }
            }
            .onChange(of: value) { newValue in
                let old = previous ?? newValue
                previous = newValue
                action(old, newValue)
            }
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(
        of value: Value,
        initial: Bool = false,
        _ action: @escaping (_ old: Value, _ new: Value) -> Void
    ) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value, initial: initial, action)
        } else {
            self.modifier(OnChangeCompatibilityModifier(value: value, initial: initial, action: action))
        }
    }
}

@MainActor
protocol ModelLoadingManaging: ObservableObject {
    var loadingModelName: String? { get set }
}

#if DEBUG
@MainActor
final class PreviewModelManager: ObservableObject, ModelLoadingManaging {
    @Published var loadingModelName: String?
}
#endif

struct ModelLoadingNotificationView<Manager: ModelLoadingManaging>: View {
    @ObservedObject var modelManager: Manager
    @ObservedObject var loadingTracker: ModelLoadingProgressTracker

    @State private var showNotification = false
    @State private var animateIn = false
    @State private var animateOut = false
    @Environment(\.colorScheme) private var colorScheme

    private var pillWidth: CGFloat {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? 280 : 200
        #else
        260
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .pad ? 40 : 20
        #else
        32
        #endif
    }

    var body: some View {
        ZStack {
            if showNotification {
                content
                    .scaleEffect(animateIn ? 1.0 : 0.92)
                    .opacity(animateIn ? 1.0 : 0.0)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: animateIn)
                    .animation(.easeOut(duration: 0.22), value: animateOut)
            }
        }
        .onAppear {
            if loadingTracker.isLoading {
                showNotification = true
                animateOut = false
                animateIn = false
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        animateIn = true
                    }
                }
            }
        }
        .onChangeCompat(of: loadingTracker.isLoading) { wasLoading, isLoading in
            if isLoading && !wasLoading {
                showNotification = true
                animateOut = false
                animateIn = false
                DispatchQueue.main.async {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        animateIn = true
                    }
                }
            } else if !isLoading && wasLoading {
                withAnimation(.easeOut(duration: 0.22)) {
                    animateOut = true
                    animateIn = false
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    showNotification = false
                    animateOut = false
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey("Loading"))
#if os(macOS)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textCase(.uppercase)
                .tracking(0.3)
                .foregroundStyle(.secondary)
#else
                .font(.caption.weight(.semibold))
                .foregroundStyle(primaryTextColor)
#endif
                .compactStatusText()

            NotificationProgressBar(value: loadingTracker.progress, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: pillWidth)
        .glassPill(cornerRadius: 20)
#if !os(macOS)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.24), lineWidth: 0.8)
        )
#endif
        .padding(.horizontal, horizontalPadding)
        .opacity(animateOut ? 0.0 : 1.0)
        .scaleEffect(animateOut ? 0.92 : (animateIn ? 1.0 : 0.96))
    }

    private var primaryTextColor: Color {
        #if os(macOS)
        Color(nsColor: .labelColor)
        #else
        Color.primary
        #endif
    }
}

#if DEBUG
#Preview {
    ZStack {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
        #else
        Color(.systemBackground)
            .ignoresSafeArea()
        #endif

        VStack {
            Spacer()

            ModelLoadingNotificationView(
                modelManager: {
                    let manager = PreviewModelManager()
                    manager.loadingModelName = "Llama-3.2-3B-Instruct-Q4"
                    return manager
                }(),
                loadingTracker: ModelLoadingProgressTracker.preview
            )

            Spacer()
        }
    }
}
#endif
