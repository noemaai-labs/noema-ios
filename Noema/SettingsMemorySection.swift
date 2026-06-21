import SwiftUI

struct SettingsMemorySection: View {
    var body: some View {
        Section(header: Text("Memory")) {
            SettingsMemorySummaryContent()
        }
    }
}

struct SettingsMemorySummaryContent: View {
    let onManage: (() -> Void)?

    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var store = MemoryStore.shared
    @EnvironmentObject private var chatVM: ChatVM

    @State private var showInfo = false
    @State private var isPresentingManager = false

    init(onManage: (() -> Void)? = nil) {
        self.onManage = onManage
    }

    private var isAtCapacity: Bool {
        store.entries.count >= MemoryStore.maximumEntries
    }

    private var pendingConflictCount: Int {
        store.reviewItems.reduce(0) { partial, item in
            partial + (item.possibleConflicts ?? []).count
        }
    }

    private var currentModelNoticeText: String? {
        let status = chatVM.memoryPromptBudgetStatus
        guard settings.memoryEnabled, status.shouldDisplayNotice else { return nil }
        switch status.state {
        case .partiallyLoaded:
            return String.localizedStringWithFormat(
                String(localized: "Current model preloads %d of %d memories."),
                status.loadedCount,
                status.totalCount
            )
        case .notLoaded:
            return String(localized: "Current model cannot preload memories within its context budget.")
        case .inactive, .allLoaded:
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $settings.memoryEnabled) {
                HStack(spacing: 8) {
                    Text("Persistent Memory")
                    Button { showInfo = true } label: {
                        Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("What is Persistent Memory?"))
                }
            }
            .tint(.blue)

            Text("Memory entries persist across conversations on this device. When enabled, tool-capable models can read or update them automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(
                String.localizedStringWithFormat(
                    String(localized: "Up to %d memories can be stored across conversations on this device."),
                    MemoryStore.maximumEntries
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button {
                    if let onManage {
                        onManage()
                    } else {
                        isPresentingManager = true
                    }
                } label: {
                    Label("Manage Memories", systemImage: "square.stack.3d.up")
                }

                Spacer()

                Text(
                    String.localizedStringWithFormat(
                        String(localized: "%d of %d saved"),
                        store.entries.count,
                        MemoryStore.maximumEntries
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if !store.reviewItems.isEmpty {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "%d pending review"),
                        store.reviewItems.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if pendingConflictCount > 0 {
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "%d possible memory conflicts"),
                        pendingConflictCount
                    )
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if isAtCapacity {
                Text("Memory is full. Delete an entry to add another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.entries.isEmpty {
                Text("No memories saved yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let currentModelNoticeText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bookmark.slash")
                        .foregroundStyle(.secondary)
                    Text(currentModelNoticeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $isPresentingManager) {
            NavigationStack {
                MemoryManagementView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isPresentingManager = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Persistent Memory", isPresented: $showInfo) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("When enabled, models can save durable facts like stable preferences or recurring project constraints to on-device memory that persists across conversations.")
        }
    }
}

struct MemoryManagementView: View {
    @ObservedObject private var store = MemoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared

    @State private var draft = MemoryEditorDraft()
    @State private var isPresentingEditor = false
    @State private var deleteTarget: MemoryEntry?
    @State private var editorError: String?
    @State private var reviewError: String?

    private var isAtCapacity: Bool {
        store.entries.count >= MemoryStore.maximumEntries
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Memories")
                            .font(.title2.weight(.semibold))
                        Text("View, edit, or delete saved memories. This list is limited to 20 entries.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(
                        String.localizedStringWithFormat(
                            String(localized: "%d of %d saved"),
                            store.entries.count,
                            MemoryStore.maximumEntries
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.memoryReviewRequired) {
                    Label("Review Memory Saves", systemImage: "checklist.checked")
                }
                .tint(.blue)
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

                if !store.reviewItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Memory Review Inbox")
                            .font(.headline)
                        Text("Review model-proposed memories before saving them.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(store.reviewItems) { item in
                            MemoryReviewItemCard(
                                item: item,
                                onApprove: { approveReviewItem(item) },
                                onReject: { rejectReviewItem(item) }
                            )
                        }
                        if let reviewError, !reviewError.isEmpty {
                            Text(reviewError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }

                Button {
                    draft = MemoryEditorDraft()
                    editorError = nil
                    isPresentingEditor = true
                } label: {
                    Label("Add Memory", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAtCapacity)

                if isAtCapacity {
                    Text("Memory is full. Delete an entry to add another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.entries.isEmpty {
                    Text("No memories saved yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.entries) { entry in
                            MemoryEntryCard(
                                entry: entry,
                                onEdit: {
                                    draft = MemoryEditorDraft(entry: entry)
                                    editorError = nil
                                    isPresentingEditor = true
                                },
                                onDelete: {
                                    deleteTarget = entry
                                }
                            )
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Manage Memories")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $isPresentingEditor) {
            NavigationStack {
                MemoryEditorSheet(
                    draft: $draft,
                    errorMessage: $editorError,
                    onSave: saveDraft
                )
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Delete Memory", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let deleteTarget else { return }
                _ = try? MemoryStore.shared.delete(id: deleteTarget.id.uuidString, title: nil)
                self.deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
            }
        } message: {
            Text("This permanently removes the selected memory entry.")
        }
    }

    private func saveDraft() {
        do {
            if let entryID = draft.entryID {
                _ = try MemoryStore.shared.updateEntry(
                    id: entryID,
                    title: draft.title,
                    content: draft.content,
                    scope: draft.scope,
                    expiresAt: draft.hasExpiry ? draft.expiresAt : nil
                )
            } else {
                _ = try MemoryStore.shared.create(
                    title: draft.title,
                    content: draft.content,
                    scope: draft.scope,
                    expiresAt: draft.hasExpiry ? draft.expiresAt : nil
                )
            }
            editorError = nil
            isPresentingEditor = false
        } catch {
            editorError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func approveReviewItem(_ item: MemoryReviewItem) {
        do {
            _ = try MemoryStore.shared.approveReviewItem(id: item.id)
            reviewError = nil
        } catch {
            reviewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func rejectReviewItem(_ item: MemoryReviewItem) {
        do {
            _ = try MemoryStore.shared.rejectReviewItem(id: item.id)
            reviewError = nil
        } catch {
            reviewError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct MemoryReviewItemCard: View {
    let item: MemoryReviewItem
    let onApprove: () -> Void
    let onReject: () -> Void

    private var conflicts: [MemoryConflict] {
        item.possibleConflicts ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Created by Memory Tool")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(item.effectiveScope.localizedTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                        if let expiresAt = item.expiresAt {
                            Text(item.isExpired ? String(localized: "Expired") : String.localizedStringWithFormat(String(localized: "Expires %@"), expiresAt.formatted(date: .abbreviated, time: .omitted)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(item.isExpired ? .orange : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            if !conflicts.isEmpty {
                MemoryConflictSummary(conflicts: conflicts, tint: .orange)
            }

            HStack {
                Text(item.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reject", role: .destructive, action: onReject)
                    .buttonStyle(.borderless)
                Button("Approve", action: onApprove)
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct MemoryEntryCard: View {
    @ObservedObject private var store = MemoryStore.shared

    let entry: MemoryEntry
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var conflicts: [MemoryConflict] {
        store.possibleConflicts(title: entry.title, content: entry.content, excluding: entry.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.headline)
                    Text(entry.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Text(entry.effectiveScope.localizedTitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.12)))
                        if let expiresAt = entry.expiresAt {
                            Text(entry.isExpired ? String(localized: "Expired") : String.localizedStringWithFormat(String(localized: "Expires %@"), expiresAt.formatted(date: .abbreviated, time: .omitted)))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(entry.isExpired ? .orange : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        }
                    }
                }

                Spacer()
            }

            if !conflicts.isEmpty {
                MemoryConflictSummary(conflicts: conflicts, tint: .orange)
            }

            HStack {
                Text(entry.updatedAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Edit", action: onEdit)
                    .buttonStyle(.borderless)
                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct MemoryConflictSummary: View {
    let conflicts: [MemoryConflict]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Possible Conflict", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            ForEach(conflicts.prefix(2)) { conflict in
                Text(
                    String.localizedStringWithFormat(
                        String(localized: "May contradict \"%@\""),
                        conflict.title
                    )
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                Text(conflict.kind.localizedSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("Review both memories before saving.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MemoryEditorDraft {
    var entryID: UUID?
    var title: String = ""
    var content: String = ""
    var scope: MemoryScope = .allChats
    var hasExpiry = false
    var expiresAt = Calendar.current.date(byAdding: .month, value: 1, to: Date()) ?? Date()

    init() { }

    init(entry: MemoryEntry) {
        self.entryID = entry.id
        self.title = entry.title
        self.content = entry.content
        self.scope = entry.effectiveScope
        self.hasExpiry = entry.expiresAt != nil
        if let expiresAt = entry.expiresAt {
            self.expiresAt = expiresAt
        }
    }

    var isNew: Bool { entryID == nil }
}

private struct MemoryEditorSheet: View {
    @Binding var draft: MemoryEditorDraft
    @Binding var errorMessage: String?
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Memory Title", text: $draft.title)
                TextEditor(text: $draft.content)
                    .frame(minHeight: 220)
                Picker("Memory Scope", selection: $draft.scope) {
                    ForEach(MemoryScope.allCases, id: \.self) { scope in
                        Text(scope.localizedTitle).tag(scope)
                    }
                }
                Toggle("Expires", isOn: $draft.hasExpiry)
                if draft.hasExpiry {
                    DatePicker(
                        "Expiry Date",
                        selection: $draft.expiresAt,
                        in: Date()...,
                        displayedComponents: [.date]
                    )
                }
            } header: {
                Text(draft.isNew ? "New Memory" : "Edit Memory")
            } footer: {
                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                } else {
                    Text("Use memory for durable facts that should remain available in future conversations.")
                }
            }
        }
        .navigationTitle(draft.isNew ? "Add Memory" : "Edit Memory")
        #if !os(macOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onSave()
                }
            }
        }
    }
}
