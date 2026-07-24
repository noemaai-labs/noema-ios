import SwiftUI

// MARK: - Dataset rows

/// A flat, text-forward dataset / Knowledge Pack row that mirrors the Stored
/// `ModelRow` exactly: name + optional status badge, a publisher subtitle, and a
/// monospaced, dot-separated metadata line — no leading icon, no card, no
/// rounded chips. Rows sit directly on the page background and are separated by
/// hairline `Divider`s, just like the stored model list.
///
/// Shared by the iOS/visionOS and macOS Explore Datasets layouts.
struct DatasetRecordRow: View {
    let record: DatasetRecord
    var action: () -> Void

    /// Industrial metadata tokens, joined by middle dots like `ModelRow`.
    private var metadataTokens: [String] {
        var tokens: [String] = []
        if let category = record.category { tokens.append(category.displayName.uppercased()) }
        if let license = record.license, !license.isEmpty { tokens.append(license) }
        return tokens
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName)
                        .font(FontTheme.body)
                        .fontWeight(.medium)
                        .foregroundStyle(AppTheme.text)
                        .lineLimit(1)

                    if !record.publisher.isEmpty {
                        Text(record.publisher)
                            .font(FontTheme.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    } else if let summary = record.summary, !summary.isEmpty {
                        Text(summary)
                            .font(FontTheme.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }

                    if !metadataTokens.isEmpty {
                        Text(metadataTokens.joined(separator: " · "))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(AppTheme.tertiaryText)
                            .lineLimit(1)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                if record.installed {
                    statusBadge(LocalizedStringKey("Installed"))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A flat row for an installed (imported) dataset, matching `DatasetRecordRow`
/// and the Stored `ModelRow` so the user's own datasets and the curated packs
/// share one industrial visual language.
struct LocalDatasetRow: View {
    let dataset: LocalDataset
    /// Whether to surface the "re-embedding recommended" hint (computed by the
    /// caller from `DatasetManager`).
    var showsReindexNotice: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(dataset.name)
                            .font(FontTheme.body)
                            .fontWeight(.medium)
                            .foregroundStyle(AppTheme.text)
                            .lineLimit(1)

                        if showsReindexNotice {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                                .accessibilityLabel(Text(LocalizedStringKey("Re-embedding recommended")))
                        }
                    }

                    if !dataset.source.isEmpty {
                        Text(dataset.source)
                            .font(FontTheme.caption)
                            .foregroundStyle(AppTheme.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if dataset.isIndexed {
                    statusBadge(LocalizedStringKey("Indexed"))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The trailing monospaced status pill used by both dataset rows — identical to
/// the "Loaded" badge on the Stored `ModelRow`.
@ViewBuilder
private func statusBadge(_ title: LocalizedStringKey) -> some View {
    HStack(spacing: 4) {
        Image(systemName: "checkmark")
        Text(title)
    }
    .font(.system(size: 11, weight: .semibold, design: .monospaced))
    .foregroundColor(.green)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(Color.green.opacity(0.1))
    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
}
