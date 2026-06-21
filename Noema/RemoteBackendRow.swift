import SwiftUI
import Foundation

struct RemoteBackendRow: View {
    let backend: RemoteBackend
    let isFetching: Bool
    let isOffline: Bool
    let activeSession: ActiveRemoteSession?
    @Environment(\.locale) private var locale

    private var relativeFormatter: RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = locale
        return formatter
    }

    private var status: (text: String, color: Color)? {
        if let error = backend.lastError, !error.isEmpty {
            return (error, .red)
        }
        if let fetched = backend.lastFetched {
            let relative = relativeFormatter.localizedString(for: fetched, relativeTo: Date())
            return (
                String.localizedStringWithFormat(String(localized: "Updated %@", locale: locale), relative),
                Color.secondary
            )
        }
        if backend.cachedModels.isEmpty {
            return (String(localized: "No models fetched yet", locale: locale), Color.secondary)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(backend.name)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)

                    if !backend.isOpenRouter {
                        badge(text: backend.endpointType.displayName,
                              color: badgeColor(for: backend.endpointType))
                    }

                    if backend.hasAuth && !backend.isOpenRouter {
                        badge(text: String(localized: "Auth"), color: .orange)
                    }
                }
                
                Text(backend.displayBaseHost)
                    .font(FontTheme.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .lineLimit(1)
                
                HStack(spacing: 6) {
                    if let indicator = connectionIndicator {
                        HStack(spacing: 4) {
                            Circle().fill(indicator.color).frame(width: 6, height: 6)
                            Text(indicator.text)
                            if indicator.streaming {
                                Text("·")
                                Text(LocalizedStringKey("Streaming"))
                            }
                        }
                        .foregroundColor(indicator.color)
                    }
                    
                    if let status {
                        if connectionIndicator != nil {
                            Text("·").foregroundColor(AppTheme.tertiaryText)
                        }
                        Text(status.text)
                            .foregroundColor(status.color)
                    }
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.top, 2)
            }
            Spacer()
            
            if isOffline {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.secondaryText)
            } else if isFetching {
                ProgressView().scaleEffect(0.7)
            } else if backend.cachedModels.isEmpty {
                Text(LocalizedStringKey("Tap to load"))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(AppTheme.secondaryText)
            } else {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "%d models", locale: locale),
                        backend.cachedModels.count
                    )
                )
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 8)
    }

    private func badge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .foregroundColor(color)
    }

    private func badgeColor(for type: RemoteBackend.EndpointType) -> Color {
        switch type {
        case .openAI: return .blue
        case .openRouter: return .orange
        case .lmStudio: return .purple
        case .ollama: return .green
        case .cloudRelay, .noemaRelay: return .teal
        }
    }

    private var connectionIndicator: (symbol: String, text: String, color: Color, streaming: Bool)? {
        guard let session = activeSession, session.backendID == backend.id else { return nil }
        switch session.transport {
        case .cloudRelay:
            return ("icloud", String(localized: "Cloud Relay"), .teal, session.streamingEnabled)
        case .lan(let ssid):
            let text = ssid.isEmpty
                ? String(localized: "Local Network")
                : String.localizedStringWithFormat(String(localized: "LAN · %@"), ssid)
            return ("wifi.router", text, .green, session.streamingEnabled)
        case .direct:
            return ("bolt.horizontal", String(localized: "Direct"), .blue, session.streamingEnabled)
        }
    }
}
