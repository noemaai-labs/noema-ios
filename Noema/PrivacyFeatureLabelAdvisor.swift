import Foundation

struct PrivacyFeatureLabelProfile: Equatable, Sendable {
    var offGrid: Bool
    var webSearchEnabled: Bool
    var pythonEnabled: Bool
    var memoryEnabled: Bool
    var remoteRedactionEnabled: Bool
}

struct PrivacyFeatureLabel: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case local
        case localSandbox
        case optionalNetwork
        case remote
        case blocked
        case off

        var titleKey: String {
            switch self {
            case .local: return "Local"
            case .localSandbox: return "Local sandbox"
            case .optionalNetwork: return "Optional network"
            case .remote: return "Remote"
            case .blocked: return "Blocked"
            case .off: return "Off"
            }
        }
    }

    let id: String
    let titleKey: String
    let state: State
    let detailKey: String
    let systemImage: String
}

enum PrivacyFeatureLabelAdvisor {
    static func labels(for profile: PrivacyFeatureLabelProfile) -> [PrivacyFeatureLabel] {
        [
            PrivacyFeatureLabel(
                id: "local_model",
                titleKey: "Local model chat",
                state: .local,
                detailKey: "Prompts and tokens stay on this device when a local model is selected.",
                systemImage: "cpu"
            ),
            PrivacyFeatureLabel(
                id: "dataset_retrieval",
                titleKey: "Dataset retrieval",
                state: .local,
                detailKey: "Imported documents and embeddings stay on device.",
                systemImage: "doc.text.magnifyingglass"
            ),
            PrivacyFeatureLabel(
                id: "memory",
                titleKey: "Memory",
                state: profile.memoryEnabled ? .local : .off,
                detailKey: profile.memoryEnabled
                    ? "Saved memories are stored locally and require explicit tool permission in chat."
                    : "Memory tools are disabled.",
                systemImage: "brain"
            ),
            PrivacyFeatureLabel(
                id: "python",
                titleKey: "Python",
                state: profile.pythonEnabled ? .localSandbox : .off,
                detailKey: profile.pythonEnabled
                    ? "Python runs in a local sandbox without network access."
                    : "Python tools are disabled.",
                systemImage: "terminal"
            ),
            PrivacyFeatureLabel(
                id: "web_search",
                titleKey: "Web search",
                state: networkState(enabled: profile.webSearchEnabled, offGrid: profile.offGrid),
                detailKey: networkDetail(enabled: profile.webSearchEnabled, offGrid: profile.offGrid),
                systemImage: "magnifyingglass"
            ),
            PrivacyFeatureLabel(
                id: "remote_backends",
                titleKey: "Remote backends",
                state: profile.offGrid ? .blocked : .remote,
                detailKey: remoteDetail(offGrid: profile.offGrid, redactionEnabled: profile.remoteRedactionEnabled),
                systemImage: "antenna.radiowaves.left.and.right"
            ),
            PrivacyFeatureLabel(
                id: "downloads_explore",
                titleKey: "Downloads and Explore",
                state: profile.offGrid ? .blocked : .optionalNetwork,
                detailKey: profile.offGrid
                    ? "Off-grid blocks Explore, downloads, and external model catalog calls."
                    : "Explore and downloads contact external model catalogs only when used.",
                systemImage: "arrow.down.circle"
            )
        ]
    }

    private static func networkState(enabled: Bool, offGrid: Bool) -> PrivacyFeatureLabel.State {
        if offGrid { return .blocked }
        return enabled ? .optionalNetwork : .off
    }

    private static func networkDetail(enabled: Bool, offGrid: Bool) -> String {
        if offGrid {
            return "Off-grid blocks web search and records blocked attempts."
        }
        if enabled {
            return "Web search can contact the network only when enabled and armed in chat."
        }
        return "Web search is disabled."
    }

    private static func remoteDetail(offGrid: Bool, redactionEnabled: Bool) -> String {
        if offGrid {
            return "Off-grid blocks remote backend traffic."
        }
        if redactionEnabled {
            return "Remote prompts can leave the device; sensitive-data redaction is enabled."
        }
        return "Remote prompts can leave the device when you choose a remote backend."
    }
}
