#if os(visionOS)
import SwiftUI
import RealityKit
import UIKit
import simd
import Combine

// Allow conditional availability within SceneBuilder closures (e.g., if #available).
extension SceneBuilder {
    static func buildLimitedAvailability<Content>(_ component: Content) -> Content where Content: SwiftUI.Scene {
        component
    }
}

enum VisionWindowMode {
    case planar
    case volumetric
}

enum VisionSceneID {
    static let planarWindow = "com.noema.vision.planar"
    static let storedPanelWindow = "com.noema.vision.stored"
    static let pinnedCardWindow = "com.noema.vision.pinnedCard"
}

struct VisionPinnedNote: Identifiable, Hashable, Codable {
    let id: UUID
    let text: String
    let createdAt: Date
    let sessionID: UUID
    let messageID: UUID
    let anchorID: UUID
    var storedTransform: simd_float4x4?

    init(
        id: UUID = UUID(),
        text: String,
        createdAt: Date = Date(),
        sessionID: UUID,
        messageID: UUID,
        anchorID: UUID = UUID(),
        storedTransform: simd_float4x4? = nil
    ) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.sessionID = sessionID
        self.messageID = messageID
        self.anchorID = anchorID
        self.storedTransform = storedTransform
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
        case createdAt
        case sessionID
        case messageID
        case anchorID
        case storedTransform
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        messageID = try container.decode(UUID.self, forKey: .messageID)
        anchorID = try container.decode(UUID.self, forKey: .anchorID)
        if let matrixArray = try container.decodeIfPresent([Float].self, forKey: .storedTransform), matrixArray.count == 16 {
            storedTransform = simd_float4x4(
                SIMD4(matrixArray[0], matrixArray[1], matrixArray[2], matrixArray[3]),
                SIMD4(matrixArray[4], matrixArray[5], matrixArray[6], matrixArray[7]),
                SIMD4(matrixArray[8], matrixArray[9], matrixArray[10], matrixArray[11]),
                SIMD4(matrixArray[12], matrixArray[13], matrixArray[14], matrixArray[15])
            )
        } else {
            storedTransform = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(anchorID, forKey: .anchorID)
        if let storedTransform {
            try container.encode(Self.flattenedTransform(storedTransform), forKey: .storedTransform)
        }
    }

    static func == (lhs: VisionPinnedNote, rhs: VisionPinnedNote) -> Bool {
        lhs.id == rhs.id &&
        lhs.text == rhs.text &&
        lhs.createdAt == rhs.createdAt &&
        lhs.sessionID == rhs.sessionID &&
        lhs.messageID == rhs.messageID &&
        lhs.anchorID == rhs.anchorID &&
        lhs.flattenedStoredTransform == rhs.flattenedStoredTransform
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(text)
        hasher.combine(createdAt)
        hasher.combine(sessionID)
        hasher.combine(messageID)
        hasher.combine(anchorID)
        if let flattened = flattenedStoredTransform {
            hasher.combine(flattened.count)
            flattened.forEach { hasher.combine($0) }
        } else {
            hasher.combine(0)
        }
    }

    private var flattenedStoredTransform: [Float]? {
        guard let storedTransform else { return nil }
        return Self.flattenedTransform(storedTransform)
    }

    private static func flattenedTransform(_ matrix: simd_float4x4) -> [Float] {
        let column0 = matrix.columns.0
        let column1 = matrix.columns.1
        let column2 = matrix.columns.2
        let column3 = matrix.columns.3
        return [
            column0.x, column0.y, column0.z, column0.w,
            column1.x, column1.y, column1.z, column1.w,
            column2.x, column2.y, column2.z, column2.w,
            column3.x, column3.y, column3.z, column3.w
        ]
    }
}

@MainActor
final class VisionPinnedNoteStore: ObservableObject {
    @Published private(set) var notes: [VisionPinnedNote] = []
    private let storageKey = "com.noema.vision.pinnedNotes"
    private var pendingTransforms: [UUID: simd_float4x4] = [:]
    private var lastPersistedAt: [UUID: Date] = [:]
    private let transformEpsilon: Float = 1e-4
    private let minPersistenceInterval: TimeInterval = 0.35

    init() {
        load()
    }

    func note(withID id: UUID) -> VisionPinnedNote? {
        notes.first { $0.id == id }
    }

    @discardableResult
    func pin(message: ChatVM.Msg, in sessionID: UUID) -> VisionPinnedNote {
        let sanitized = sanitizedPinnedContent(from: message)
        if let index = notes.firstIndex(where: { $0.messageID == message.id && $0.sessionID == sessionID }) {
            if notes[index].text != sanitized {
                notes[index] = VisionPinnedNote(
                    id: notes[index].id,
                    text: sanitized,
                    createdAt: notes[index].createdAt,
                    sessionID: sessionID,
                    messageID: message.id,
                    anchorID: notes[index].anchorID,
                    storedTransform: notes[index].storedTransform
                )
                save()
            }
            primePersistenceMetadata(for: notes[index])
            return notes[index]
        }

        let note = VisionPinnedNote(text: sanitized, sessionID: sessionID, messageID: message.id)
        notes.append(note)
        save()
        primePersistenceMetadata(for: note)
        return note
    }

    func remove(noteID: UUID) {
        notes.removeAll { $0.id == noteID }
        pendingTransforms.removeValue(forKey: noteID)
        lastPersistedAt.removeValue(forKey: noteID)
        save()
    }

    func updateTransform(for noteID: UUID, transform: simd_float4x4) {
        guard let index = notes.firstIndex(where: { $0.id == noteID }) else { return }
        primePersistenceMetadata(for: notes[index])

        if let stored = notes[index].storedTransform, stored.isApproximatelyEqual(to: transform, tolerance: transformEpsilon) {
            pendingTransforms.removeValue(forKey: noteID)
            return
        }

        pendingTransforms[noteID] = transform

        let now = Date()
        if let lastPersisted = lastPersistedAt[noteID], now.timeIntervalSince(lastPersisted) < minPersistenceInterval {
            return
        }

        let transformToPersist = pendingTransforms.removeValue(forKey: noteID) ?? transform
        notes[index].storedTransform = transformToPersist
        lastPersistedAt[noteID] = now
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([VisionPinnedNote].self, from: data) {
            let sanitizedNotes = decoded.map { sanitizeIfNeeded($0) }
            notes = sanitizedNotes
            sanitizedNotes.forEach { primePersistenceMetadata(for: $0) }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func sanitizeIfNeeded(_ note: VisionPinnedNote) -> VisionPinnedNote {
        let cleaned = sanitizedPinnedContent(from: note.text)
        guard cleaned != note.text else { return note }
        return VisionPinnedNote(
            id: note.id,
            text: cleaned,
            createdAt: note.createdAt,
            sessionID: note.sessionID,
            messageID: note.messageID,
            anchorID: note.anchorID,
            storedTransform: note.storedTransform
        )
    }

    private func sanitizedPinnedContent(from message: ChatVM.Msg) -> String {
        sanitizedPinnedContent(from: message.text)
    }

    private func sanitizedPinnedContent(from rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let closingThink = trimmed.range(of: "</think>", options: .backwards) {
            let afterThink = trimmed[closingThink.upperBound...]
            let trailing = afterThink.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                let stripped = stripThinkTags(from: String(trailing))
                if !stripped.isEmpty { return stripped }
            }
        }

        return stripThinkTags(from: trimmed)
    }

    private func stripThinkTags(from text: String) -> String {
        var result = text
        while let open = result.range(of: "<think>"),
              let close = result.range(of: "</think>", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        result = result.replacingOccurrences(of: "<think>", with: "")
        result = result.replacingOccurrences(of: "</think>", with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func primePersistenceMetadata(for note: VisionPinnedNote) {
        if lastPersistedAt[note.id] == nil {
            lastPersistedAt[note.id] = .distantPast
        }
        if let transform = note.storedTransform, pendingTransforms[note.id] == nil {
            pendingTransforms[note.id] = transform
        }
    }
}

private extension simd_float4x4 {
    func isApproximatelyEqual(to other: simd_float4x4, tolerance: Float) -> Bool {
        let delta0 = abs(columns.0 - other.columns.0)
        let delta1 = abs(columns.1 - other.columns.1)
        let delta2 = abs(columns.2 - other.columns.2)
        let delta3 = abs(columns.3 - other.columns.3)
        let firstPair = max(delta0.maxComponent, delta1.maxComponent)
        let secondPair = max(delta2.maxComponent, delta3.maxComponent)
        return max(firstPair, secondPair) <= tolerance
    }
}

private extension SIMD4 where Scalar == Float {
    var maxComponent: Float { max(max(x, y), max(z, w)) }
}

struct NoemaVisionMainScene: SwiftUI.Scene {
    @StateObject private var tabRouter = TabRouter()
    @StateObject private var chatVM = ChatVM()
    @StateObject private var modelManager = AppModelManager()
    @StateObject private var datasetManager = DatasetManager()
    @StateObject private var downloadController = DownloadController()
    @StateObject private var walkthroughManager = GuidedWalkthroughManager()
    @StateObject private var localizationManager = LocalizationManager()
    @State private var immersiveSpaceActive = false
    @StateObject private var pinnedStore = VisionPinnedNoteStore()
    @AppStorage("appearance") private var appearance = "system"

    private var colorScheme: ColorScheme? { VisionAppearance.forcedScheme(for: appearance) }

    private func storedPanelView() -> some View {
        StoredPanelWindow()
            .environmentObject(tabRouter)
            .environmentObject(chatVM)
            .environmentObject(modelManager)
            .environmentObject(datasetManager)
            .environmentObject(downloadController)
            .environmentObject(walkthroughManager)
            .environmentObject(pinnedStore)
            .environmentObject(localizationManager)
            .environment(\.locale, localizationManager.locale)
            .visionAppearance(colorScheme)
    }

    @SceneBuilder
    var body: some SwiftUI.Scene {
        WindowGroup(id: VisionSceneID.planarWindow) {
            VisionMainContainer(
                mode: .planar,
                tabRouter: tabRouter,
                chatVM: chatVM,
                modelManager: modelManager,
                datasetManager: datasetManager,
                downloadController: downloadController,
                walkthroughManager: walkthroughManager,
                immersiveSpaceActive: $immersiveSpaceActive,
                pinnedStore: pinnedStore,
                localizationManager: localizationManager
            )
            .environmentObject(localizationManager)
            .environment(\.locale, localizationManager.locale)
            .visionAppearance(colorScheme)
            .calendarConfirmationHost()
            .onAppear {
                ReviewPrompter.shared.trackSession()
                AppIntentDriver.shared.bind(chatVM: chatVM,
                                            modelManager: modelManager,
                                            datasetManager: datasetManager,
                                            tabRouter: tabRouter,
                                            downloadController: downloadController)
            }
        }
        .defaultSize(width: 1100, height: 840)

        storedPanelScene

        pinnedCardScene

        ImmersiveSpace(id: VisionImmersiveView.spaceID) {
            VisionImmersiveView(isActive: $immersiveSpaceActive)
                .environmentObject(chatVM)
                .environmentObject(modelManager)
                .environmentObject(pinnedStore)
                .environmentObject(localizationManager)
                .environment(\.locale, localizationManager.locale)
                .visionAppearance(colorScheme)
        }
    }

    private var storedPanelScene: some SwiftUI.Scene {
        WindowGroup(id: VisionSceneID.storedPanelWindow) {
            storedPanelView()
        }
        .defaultSize(width: 420, height: 560)
        .windowResizability(.contentSize)
        .windowStyle(.plain)
    }

    private var pinnedCardScene: some SwiftUI.Scene {
        WindowGroup(id: VisionSceneID.pinnedCardWindow, for: UUID.self) { binding in
            if let noteID = binding.wrappedValue, let note = pinnedStore.note(withID: noteID) {
                VisionPinnedCardWindow(note: note)
                    .environmentObject(pinnedStore)
                    .environmentObject(chatVM)
                    .environmentObject(tabRouter)
                    .visionAppearance(colorScheme)
            } else {
                Text("Pinned answer unavailable")
                    .padding()
            }
        }
        .windowStyle(.volumetric)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 0.55, height: 0.22, depth: 0.05)
    }
}

private struct VisionMainContainer: View {
    let mode: VisionWindowMode
    let tabRouter: TabRouter
    @ObservedObject var chatVM: ChatVM
    @ObservedObject var modelManager: AppModelManager
    @ObservedObject var datasetManager: DatasetManager
    @ObservedObject var downloadController: DownloadController
    @ObservedObject var walkthroughManager: GuidedWalkthroughManager
    @Binding var immersiveSpaceActive: Bool
    @ObservedObject var pinnedStore: VisionPinnedNoteStore
    @ObservedObject var localizationManager: LocalizationManager
    @State private var immersiveError: String?
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Group {
            switch mode {
            case .planar, .volumetric:
                planarView
            }
        }
        .alert("Immersive Space", isPresented: Binding(get: { immersiveError != nil }, set: { _ in immersiveError = nil })) {
            Button("OK", role: .cancel) { immersiveError = nil }
        } message: {
            Text(immersiveError ?? "")
        }
    }

    private var baseContent: some View {
        ContentView(
            mode: mode,
            tabRouter: tabRouter,
            chatVM: chatVM,
            modelManager: modelManager,
            datasetManager: datasetManager,
            downloadController: downloadController,
            walkthroughManager: walkthroughManager
        )
        .environmentObject(pinnedStore)
        .environmentObject(localizationManager)
        .environment(\.locale, localizationManager.locale)
    }

    @ViewBuilder
    private var planarView: some View {
        baseContent
    }

}

private struct VisionPinnedCardWindow: View {
    @EnvironmentObject private var pinnedStore: VisionPinnedNoteStore
    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var tabRouter: TabRouter
    @Environment(\.dismiss) private var dismiss
    let note: VisionPinnedNote

    private var formattedDate: String {
        note.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinned answer")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(formattedDate)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }

            ScrollView {
                MathRichText(source: note.text, bodyFont: .title3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .frame(
            minWidth: 480,
            idealWidth: 620,
            maxWidth: 1300,
            minHeight: 220,
            idealHeight: 360,
            maxHeight: 900
        )
        .glassBackgroundEffect()
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 36, style: .continuous)
        )
        .overlay(alignment: .topTrailing) { overlayButtons }
    }

    private var overlayButtons: some View {
        HStack(spacing: 12) {
            Button(action: openChat) {
                Label("View in Chat", systemImage: "arrow.turn.up.left")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Button(action: closeWindow) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close pinned answer")
        }
        .padding(12)
    }

    private func openChat() {
        tabRouter.selection = .chat
        if let session = chatVM.sessions.first(where: { $0.id == note.sessionID }) {
            chatVM.select(session)
        }
        chatVM.focus(onMessageWithID: note.messageID)
    }

    private func closeWindow() {
        pinnedStore.remove(noteID: note.id)
        dismiss()
    }
}

private struct VisionImmersiveView: View {
    static let spaceID = "NoemaImmersiveSpace"

    @EnvironmentObject private var chatVM: ChatVM
    @EnvironmentObject private var modelManager: AppModelManager
    @EnvironmentObject private var pinnedStore: VisionPinnedNoteStore
    @Binding var isActive: Bool
    @State private var scene = VisionImmersiveScene()

    var body: some View {
        RealityView { content in
            content.add(scene.root)
        } update: { _ in
            scene.updateOutput(text: assistantSummary)
            scene.updateShelf(with: modelManager.downloadedModels)
            scene.updateStatus(isStreaming: chatVM.isStreaming, rate: chatVM.msgs.last?.perf?.avgTokPerSec)
            scene.updatePinnedNotes(pinnedStore.notes)
        }
        .onChange(of: modelManager.downloadedModels) { models in
            scene.updateShelf(with: models)
        }
        .onReceive(pinnedStore.$notes) { notes in
            scene.updatePinnedNotes(notes)
        }
        .onAppear { isActive = true }
        .onDisappear { isActive = false }
    }

    private var assistantSummary: String {
        if let streaming = chatVM.msgs.last, streaming.streaming {
            return streaming.text.isEmpty ? "Generating response…" : streaming.text
        }
        if let message = chatVM.msgs.reversed().first(where: { $0.role != "🧑‍💻" && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return message.text
        }
        return chatVM.prompt.isEmpty ? "No assistant output yet." : "Awaiting response…"
    }
}

@MainActor
private final class VisionImmersiveScene {
    let root: AnchorEntity
    private let panel: ModelEntity
    private let textEntity: ModelEntity
    private let shelfParent: Entity
    private let statusOrb: ModelEntity
    private let pinnedParent: Entity
    private var currentOutput: String = ""
    private var statusColor: UIColor = .systemTeal
    private var shelfEntities: [String: Entity] = [:]
    private var pinnedEntities: [UUID: Entity] = [:]

    init() {
        let anchor = AnchorEntity()
        anchor.position = [0, 1.35, -1.4]
        root = anchor

        let panelMaterial = SimpleMaterial(color: UIColor(white: 1.0, alpha: 0.28), roughness: 0.2, isMetallic: false)
        panel = ModelEntity(mesh: .generatePlane(width: 0.9, height: 0.5, cornerRadius: 0.05), materials: [panelMaterial])
        panel.position = [0, 0.3, 0]
        panel.orientation = simd_quatf(angle: -0.12, axis: [1, 0, 0])
        panel.generateCollisionShapes(recursive: true)
        panel.components.set(InputTargetComponent())
        anchor.addChild(panel)

        textEntity = ModelEntity(mesh: Self.makeTextMesh("Welcome to Noema on visionOS."), materials: [SimpleMaterial(color: .white, roughness: 0.15, isMetallic: false)])
        textEntity.position = [0, 0.02, 0.02]
        textEntity.scale = [0.0024, 0.0024, 0.0024]
        panel.addChild(textEntity)

        shelfParent = Entity()
        shelfParent.position = [0, -0.28, 0.05]
        panel.addChild(shelfParent)

        statusOrb = ModelEntity(mesh: .generateSphere(radius: 0.055), materials: [SimpleMaterial(color: statusColor.withAlphaComponent(0.85), roughness: 0.1, isMetallic: false)])
        statusOrb.position = [0.36, 0.33, 0.05]
        statusOrb.generateCollisionShapes(recursive: true)
        statusOrb.components.set(InputTargetComponent())
        panel.addChild(statusOrb)

        pinnedParent = Entity()
        pinnedParent.position = [-0.55, 0.1, 0.02]
        panel.addChild(pinnedParent)
    }

    func updateOutput(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.isEmpty ? "No assistant output yet." : trimmed
        guard normalized != currentOutput else { return }
        currentOutput = normalized
        let mesh = Self.makeTextMesh(normalized)
        textEntity.model = ModelComponent(mesh: mesh, materials: [SimpleMaterial(color: .white, roughness: 0.1, isMetallic: false)])
    }

    func updateShelf(with models: [LocalModel]) {
        let top = Array(models.prefix(5))
        var seen = Set<String>()
        for (index, model) in top.enumerated() {
            let id = model.id
            let entity: Entity
            if let existing = shelfEntities[id] {
                entity = existing
            } else {
                entity = makeShelfEntity(for: model)
                shelfParent.addChild(entity)
                shelfEntities[id] = entity
            }
            let spacing: Float = 0.22
            let originOffset = Float(top.count - 1) * spacing / 2
            entity.position = [Float(index) * spacing - originOffset, 0, 0]
            seen.insert(id)
        }
        for (id, entity) in shelfEntities where !seen.contains(id) {
            entity.removeFromParent()
            shelfEntities.removeValue(forKey: id)
        }
    }

    func updateStatus(isStreaming: Bool, rate: Double?) {
        let desired = isStreaming ? UIColor.systemGreen : UIColor.systemTeal
        if desired != statusColor {
            statusColor = desired
            statusOrb.model = ModelComponent(mesh: .generateSphere(radius: 0.055), materials: [SimpleMaterial(color: desired.withAlphaComponent(0.85), roughness: 0.1, isMetallic: false)])
        }
        let pulse = isStreaming ? (1.0 + 0.12 * sin(Float(Date().timeIntervalSinceReferenceDate) * 3.2)) : 1.0
        statusOrb.scale = [pulse, pulse, pulse]
        if let rate, isStreaming == false {
            let summary = String(format: "%.1f tok/s", rate)
            let label = ModelEntity(mesh: Self.makeTextMesh(summary), materials: [SimpleMaterial(color: .white, roughness: 0.1, isMetallic: false)])
            label.position = [0, -0.12, 0]
            label.scale = [0.0016, 0.0016, 0.0016]
            if statusOrb.children.isEmpty {
                statusOrb.addChild(label)
            } else {
                statusOrb.children[0].removeFromParent()
                statusOrb.addChild(label)
            }
        } else if !statusOrb.children.isEmpty && isStreaming {
            statusOrb.children.removeAll()
        }
    }

    func updatePinnedNotes(_ notes: [VisionPinnedNote]) {
        var seen = Set<UUID>()
        for (index, note) in notes.enumerated() {
            let entity: Entity
            if let existing = pinnedEntities[note.id] {
                entity = existing
                updatePinnedText(for: entity, text: note.text)
            } else {
                entity = makePinnedEntity(for: note)
                pinnedParent.addChild(entity)
                pinnedEntities[note.id] = entity
            }
            entity.position = [0, Float(index) * 0.22, 0]
            seen.insert(note.id)
        }
        for (id, entity) in pinnedEntities where !seen.contains(id) {
            entity.removeFromParent()
            pinnedEntities.removeValue(forKey: id)
        }
    }

    private static func makeTextMesh(_ text: String) -> MeshResource {
        let font = MeshResource.Font.systemFont(ofSize: 0.08, weight: .regular)
        let frame = CGRect(x: -0.42, y: -0.22, width: 0.84, height: 0.44)
        return MeshResource.generateText(text, extrusionDepth: 0.001, font: font, containerFrame: frame, alignment: .left, lineBreakMode: .byWordWrapping)
    }

    private func makeShelfEntity(for model: LocalModel) -> Entity {
        let baseColor: UIColor
        switch model.format {
        case .gguf: baseColor = UIColor(red: 0.28, green: 0.44, blue: 0.88, alpha: 0.85)
        case .mlx: baseColor = UIColor(red: 0.95, green: 0.53, blue: 0.2, alpha: 0.85)
        case .et: baseColor = UIColor(red: 0.16, green: 0.73, blue: 0.86, alpha: 0.85)
        case .ane: baseColor = UIColor(red: 0.33, green: 0.78, blue: 0.45, alpha: 0.85)
        case .afm: baseColor = UIColor(red: 0.35, green: 0.46, blue: 0.86, alpha: 0.85)
        case .coreai: baseColor = UIColor(red: 0.55, green: 0.35, blue: 0.86, alpha: 0.85)
        }
        let body = ModelEntity(mesh: .generateBox(width: 0.18, height: 0.07, depth: 0.04, cornerRadius: 0.02), materials: [SimpleMaterial(color: baseColor, roughness: 0.25, isMetallic: false)])
        body.position = [0, 0, 0]
        body.generateCollisionShapes(recursive: true)
        body.components.set(InputTargetComponent())

        let labelMesh = MeshResource.generateText(model.name, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.06, weight: .medium), containerFrame: CGRect(x: -0.08, y: -0.025, width: 0.16, height: 0.05), alignment: .center, lineBreakMode: .byTruncatingTail)
        let label = ModelEntity(mesh: labelMesh, materials: [SimpleMaterial(color: .white, roughness: 0.1, isMetallic: false)])
        label.position = [0, 0.05, 0.025]
        label.scale = [0.0014, 0.0014, 0.0014]
        body.addChild(label)
        return body
    }

    private func makePinnedEntity(for note: VisionPinnedNote) -> Entity {
        let card = ModelEntity(mesh: .generatePlane(width: 0.3, height: 0.18, cornerRadius: 0.035), materials: [SimpleMaterial(color: UIColor(white: 1.0, alpha: 0.3), roughness: 0.2, isMetallic: false)])
        card.generateCollisionShapes(recursive: true)
        card.components.set(InputTargetComponent())

        let text = ModelEntity(mesh: MeshResource.generateText(note.text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.07, weight: .regular), containerFrame: CGRect(x: -0.135, y: -0.075, width: 0.27, height: 0.15), alignment: .left, lineBreakMode: .byWordWrapping), materials: [SimpleMaterial(color: .white, roughness: 0.1, isMetallic: false)])
        text.position = [0, 0, 0.01]
        text.scale = [0.0014, 0.0014, 0.0014]
        card.addChild(text)
        return card
    }

    private func updatePinnedText(for entity: Entity, text: String) {
        guard let card = entity.children.first as? ModelEntity else { return }
        card.model = ModelComponent(mesh: MeshResource.generateText(text, extrusionDepth: 0.001, font: .systemFont(ofSize: 0.07, weight: .regular), containerFrame: CGRect(x: -0.135, y: -0.075, width: 0.27, height: 0.15), alignment: .left, lineBreakMode: .byWordWrapping), materials: [SimpleMaterial(color: .white, roughness: 0.1, isMetallic: false)])
    }
}
#endif
