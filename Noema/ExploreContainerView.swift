import SwiftUI

enum ExploreSection: String, CaseIterable {
    case models, datasets
}

enum ModelTypeFilter: String, CaseIterable {
    case all = "All"
    case text = "Text"
    case vision = "Vision"
    
    var label: LocalizedStringKey { LocalizedStringKey(rawValue) }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.quote"
        case .vision: return "eye"
        }
    }
    
    var color: Color {
        switch self {
        case .all: return .blue
        case .text: return .green
        case .vision: return .purple
        }
    }
}

@MainActor
class ModelTypeFilterManager: ObservableObject {
    @Published var filter: ModelTypeFilter
    @Published private(set) var visionStatusVersion: Int = 0
    private var visionStatus: [String: Bool] = [:]
    
    init(filter: ModelTypeFilter) {
        self.filter = filter
    }
    
    func shouldIncludeModel(_ record: ModelRecord) -> Bool {
        // Always hide models from specific creators
        let hiddenCreators = ["MaziyarPanahi"]
        if hiddenCreators.contains(where: { $0.caseInsensitiveCompare(record.publisher) == .orderedSame }) {
            return false
        }

        if !UIConstants.showMultimodalUI {
            return true
        }

        switch filter {
        case .all:
            return true
        case .text:
            // Exclude vision models
            return !resolveVisionStatus(for: record)
        case .vision:
            // Only include vision models
            return resolveVisionStatus(for: record)
        }
    }
    
    func updateVisionStatus(repoId: String, isVision: Bool) {
        guard visionStatus[repoId] != isVision else { return }
        visionStatus[repoId] = isVision
        visionStatusVersion &+= 1
    }

    func knownVisionStatus(for repoId: String) -> Bool? {
        visionStatus[repoId]
    }

    private func resolveVisionStatus(for record: ModelRecord) -> Bool {
        // Fast path: if the Hub pipeline explicitly marks this as a VLM, treat it as vision-capable.
        if record.pipeline_tag == "image-text-to-text" {
            visionStatus[record.id] = true
            return true
        }
        if let cached = visionStatus[record.id] {
            return cached
        }
        // Use cached hub signals (GGUF projector or MLX/VLM hub inference)
        var detected = false
        if let meta = HuggingFaceMetadataCache.cached(repoId: record.id) {
            detected = meta.isVision
        }
        // Local GGUF projectors on disk can also mark a repo as vision-capable
        if detected == false, ProjectorLocator.hasProjectorForModelID(record.id) {
            detected = true
        }
        // As a last cached heuristic, consult the detector's cached decision
        if detected == false, VisionModelDetector.isVisionModelCachedOrHeuristic(repoId: record.id) {
            detected = true
        }

        visionStatus[record.id] = detected
        return detected
    }
}

#if os(macOS)
@MainActor
final class ExploreChromeState: ObservableObject {
    @Published var searchMode: ExploreSearchMode = .gguf
    @Published var searchText: String = ""
    @Published var isSearchVisible: Bool = false
    @Published var searchPlaceholder: LocalizedStringKey = LocalizedStringKey("Search")
    @Published var activeSection: ExploreSection?
    @Published var isImportVisible: Bool = false
    var toggleAction: (() -> Void)?
    var searchSubmitAction: (() -> Void)?
    var importGGUFAction: (() -> Void)?
    var importMLXAction: (() -> Void)?

    func toggle() {
        toggleAction?()
    }

    var hasToggle: Bool {
        toggleAction != nil
    }

    func submitSearch() {
        searchSubmitAction?()
    }

    func importGGUF() {
        importGGUFAction?()
    }

    func importMLX() {
        importMLXAction?()
    }
}

struct ExploreContainerView: View {
    @ObservedObject private var enterpriseManager = EnterprisePolicyManager.shared

    /// Explicit model allowlist from the active Noema Teams policy (nil = consumer Explore).
    private var enterpriseLockedModelIDs: [String]? {
        guard enterpriseManager.state.isEnrolledOnDevice else { return nil }
        return enterpriseManager.policy?.allowedModelIDs
    }

    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @EnvironmentObject var tabRouter: TabRouter
    @AppStorage("exploreSection") private var exploreSectionRaw = ExploreSection.models.rawValue
    @AppStorage("modelTypeFilter") private var modelTypeFilterRaw = ModelTypeFilter.all.rawValue
    @StateObject private var filterManager = ModelTypeFilterManager(filter: .all)
    @StateObject private var chromeState = ExploreChromeState()

    private var exploreSection: ExploreSection {
        get { ExploreSection(rawValue: exploreSectionRaw) ?? .models }
        nonmutating set { exploreSectionRaw = newValue.rawValue }
    }

    private var modelTypeFilter: ModelTypeFilter {
        get { ModelTypeFilter(rawValue: modelTypeFilterRaw) ?? .all }
        nonmutating set { modelTypeFilterRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ExploreChromeBar(
                    title: LocalizedStringKey("Explore"),
                    selection: exploreSection,
                    onSelectionChange: { newValue in
                        withAnimation(.snappy) { exploreSection = newValue }
                    },
                    showFilter: exploreSection == .models && UIConstants.showMultimodalUI,
                    filterSelection: modelTypeFilter,
                    onFilterChange: { newFilter in
                        withAnimation(.snappy) {
                            modelTypeFilterRaw = newFilter.rawValue
                            filterManager.filter = newFilter
                        }
                    },
                    chromeState: chromeState
                )

                Group {
                    switch exploreSection {
                    case .models:
                        if let lockedIDs = enterpriseLockedModelIDs {
                            EnterpriseModelsExploreView(allowedModelIDs: lockedIDs)
                        } else {
                            ExploreView()
                                .environmentObject(filterManager)
                                .environmentObject(chromeState)
                        }
                    case .datasets:
                        DatasetsExploreView()
                            .environmentObject(chromeState)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
        .onAppear {
            if !UIConstants.showMultimodalUI {
                modelTypeFilterRaw = ModelTypeFilter.all.rawValue
            }
            filterManager.filter = modelTypeFilter
            applyPendingExploreSection(tabRouter.pendingExploreSection)
        }
        .onReceive(tabRouter.$pendingExploreSection) { section in
            applyPendingExploreSection(section)
        }
        .onReceive(walkthrough.$step) { step in
            switch step {
            case .exploreIntro, .exploreDatasets, .exploreImport:
                if exploreSection != .datasets {
                    withAnimation(.snappy) { exploreSection = .datasets }
                }
            case .exploreSwitchToModels, .exploreModelTypes, .exploreMLX:
                if exploreSection != .models {
                    withAnimation(.snappy) { exploreSection = .models }
                }
            default:
                break
            }
        }
        .onChangeCompat(of: modelTypeFilterRaw) { _, newValue in
            if UIConstants.showMultimodalUI, let newFilter = ModelTypeFilter(rawValue: newValue) {
                filterManager.filter = newFilter
            } else {
                modelTypeFilterRaw = ModelTypeFilter.all.rawValue
                filterManager.filter = .all
            }
        }
    }

    /// Applies a section switch requested by an App Intent. When no search
    /// query is pending, the request ends here; otherwise the target explore
    /// view consumes the query (and clears both fields) once visible.
    private func applyPendingExploreSection(_ section: ExploreSection?) {
        guard let section else { return }
        if exploreSection != section {
            withAnimation(.snappy) { exploreSectionRaw = section.rawValue }
        }
        if tabRouter.pendingExploreSearch == nil {
            DispatchQueue.main.async { tabRouter.pendingExploreSection = nil }
        }
    }
}

struct ModelTypeFilterToggle: View {
    let selection: ModelTypeFilter
    var onChange: (ModelTypeFilter) -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        Menu {
            ForEach(ModelTypeFilter.allCases, id: \.self) { filter in
                Button {
                    onChange(filter)
                } label: {
                    if filter == selection {
                        Label(filter.label, systemImage: "checkmark")
                    } else {
                        Label(filter.label, systemImage: filter.icon)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selection.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(selection.label)
                    .textCase(.uppercase)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(Color.primary.opacity(0.65))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(shape.fill(Color.primary.opacity(0.05)))
            .overlay(shape.stroke(Color.primary.opacity(0.15), lineWidth: 1))
            .contentShape(shape)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(LocalizedStringKey("Filter"))
    }
}

@MainActor
private struct ExploreChromeBar: View {
    let title: LocalizedStringKey
    let selection: ExploreSection
    var onSelectionChange: (ExploreSection) -> Void
    let showFilter: Bool
    let filterSelection: ModelTypeFilter
    var onFilterChange: (ModelTypeFilter) -> Void
    @ObservedObject var chromeState: ExploreChromeState

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                if chromeState.isSearchVisible {
                    searchField
                }
                if chromeState.hasToggle {
                    Button(action: { chromeState.toggle() }) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(searchModeGradient)
                                .frame(width: 6, height: 6)
                            Text(chromeState.searchMode.displayName)
                                .textCase(.uppercase)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .tracking(0.5)
                                .foregroundStyle(Color.primary.opacity(0.75))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .guideHighlight(.exploreModelToggle)
                }
            }

            HStack(spacing: 16) {
                HStack(spacing: 2) {
                    sectionChip(LocalizedStringKey("Models"), .models)
                    sectionChip(LocalizedStringKey("Datasets"), .datasets)
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .guideHighlight(.exploreSwitchBar)

                Spacer(minLength: 12)

                if showFilter || shouldShowImport {
                    HStack(spacing: 8) {
                        if showFilter {
                            ModelTypeFilterToggle(selection: filterSelection, onChange: onFilterChange)
                        }
                        if shouldShowImport {
                            importMenu
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
        .padding(.horizontal, 24)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.5)
        }
    }

    private func sectionChip(_ title: LocalizedStringKey, _ value: ExploreSection) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return Button {
            onSelectionChange(value)
        } label: {
            Text(title)
                .textCase(.uppercase)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(selection == value ? Color.accentColor : Color.primary.opacity(0.55))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(shape.fill(selection == value ? Color.accentColor.opacity(0.16) : .clear))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == value ? .isSelected : [])
    }

    private var shouldShowImport: Bool {
        selection == .models && chromeState.isImportVisible
    }

    private var importMenu: some View {
        Menu {
            Button(action: { chromeState.importGGUF() }) {
                Label(LocalizedStringKey("Import GGUF"), systemImage: "tray.and.arrow.down.fill")
            }
            Button(action: { chromeState.importMLX() }) {
                Label(LocalizedStringKey("Import MLX"), systemImage: "bolt.fill")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey("Import"))
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(LocalizedStringKey("Import"))
    }

    private var subtitle: LocalizedStringKey {
        switch selection {
        case .models: return LocalizedStringKey("Discover and download local models")
        case .datasets: return LocalizedStringKey("Browse curated datasets for retrieval")
        }
    }

    private var searchModeGradient: LinearGradient {
        switch chromeState.searchMode {
        case .gguf:
            return ModelFormat.gguf.tagGradient
        case .mlx:
            return ModelFormat.mlx.tagGradient
        case .et:
            return ModelFormat.et.tagGradient
        case .ane:
            return ModelFormat.ane.tagGradient
        case .afm:
            return ModelFormat.afm.tagGradient
        case .coreai:
            return ModelFormat.coreai.tagGradient
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(chromeState.searchPlaceholder, text: Binding(
                get: { chromeState.searchText },
                set: { newValue in
                    if chromeState.searchText != newValue {
                        chromeState.searchText = newValue
                    }
                }
            ))
            .textFieldStyle(.plain)
            .disableAutocorrection(true)
            .onSubmit { chromeState.submitSearch() }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .frame(maxWidth: 320)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

#else

struct ExploreContainerView: View {
    @ObservedObject private var enterpriseManager = EnterprisePolicyManager.shared

    /// Explicit model allowlist from the active Noema Teams policy (nil = consumer Explore).
    private var enterpriseLockedModelIDs: [String]? {
        guard enterpriseManager.state.isEnrolledOnDevice else { return nil }
        return enterpriseManager.policy?.allowedModelIDs
    }

    @EnvironmentObject var tabRouter: TabRouter
    @EnvironmentObject var walkthrough: GuidedWalkthroughManager
    @AppStorage("exploreSection") private var exploreSectionRaw = ExploreSection.models.rawValue
    @AppStorage("modelTypeFilter") private var modelTypeFilterRaw = ModelTypeFilter.all.rawValue
    @StateObject private var filterManager = ModelTypeFilterManager(filter: .all)
    private var bottomFilterPadding: CGFloat {
#if os(visionOS)
        return 140
#else
        return 60
#endif
    }
    
    private var exploreSection: ExploreSection {
        get { ExploreSection(rawValue: exploreSectionRaw) ?? .models }
        nonmutating set { exploreSectionRaw = newValue.rawValue }
    }

    private var modelTypeFilter: ModelTypeFilter {
        get { ModelTypeFilter(rawValue: modelTypeFilterRaw) ?? .all }
        nonmutating set { modelTypeFilterRaw = newValue.rawValue }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                switch exploreSection {
                case .models:
                    if let lockedIDs = enterpriseLockedModelIDs {
                        EnterpriseModelsExploreView(allowedModelIDs: lockedIDs)
                    } else {
                        ExploreView()
                            .environmentObject(filterManager)
                    }
                case .datasets:
                    DatasetsExploreView()
                }
                
                // Floating model type filter toggle (hidden while multimodal UI is disabled)
                #if !os(visionOS)
                if UIConstants.showMultimodalUI && exploreSection == .models {
                    VStack {
                        Spacer()
                        HStack {
                            ModelTypeFilterToggle(selection: modelTypeFilter) { newFilter in
                                withAnimation(.snappy) { 
                                    modelTypeFilterRaw = newFilter.rawValue
                                    filterManager.filter = newFilter
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, UIConstants.defaultPadding)
                        .padding(.bottom, bottomFilterPadding)
                    }
                }
                #endif
            }
        }
        .navigationTitle(LocalizedStringKey("Explore"))
        // Present the switch bar as an overlay to avoid UIKit toolbar injection
        // inside UIHostingController (which triggers runtime warnings on iOS).
        .overlay(alignment: .bottom) {
            if tabRouter.selection == .explore {
                ExploreSwitchBar(selection: exploreSection) { newVal in
                    withAnimation(.snappy) { exploreSectionRaw = newVal.rawValue }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .guideHighlight(.exploreSwitchBar)
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            // Sync the filter manager with the stored value, or reset to All when multimodal UI is hidden
            if UIConstants.showMultimodalUI {
                filterManager.filter = modelTypeFilter
            } else {
                filterManager.filter = .all
                modelTypeFilterRaw = ModelTypeFilter.all.rawValue
            }
            applyPendingExploreSection(tabRouter.pendingExploreSection)
        }
        .onReceive(tabRouter.$pendingExploreSection) { section in
            applyPendingExploreSection(section)
        }
        .onReceive(walkthrough.$step) { step in
            switch step {
            case .exploreIntro, .exploreDatasets, .exploreImport:
                if exploreSection != .datasets {
                    withAnimation(.snappy) {
                        exploreSectionRaw = ExploreSection.datasets.rawValue
                    }
                }
            case .exploreSwitchToModels, .exploreModelTypes, .exploreMLX, .exploreET:
                if exploreSection != .models {
                    withAnimation(.snappy) {
                        exploreSectionRaw = ExploreSection.models.rawValue
                    }
                }
            default:
                break
            }
        }
        .onChangeCompat(of: modelTypeFilterRaw) { _, newValue in
            if UIConstants.showMultimodalUI, let newFilter = ModelTypeFilter(rawValue: newValue) {
                filterManager.filter = newFilter
            } else {
                modelTypeFilterRaw = ModelTypeFilter.all.rawValue
                filterManager.filter = .all
            }
        }
        #if os(visionOS)
        // Present the model type filter as a bottom-left ornament on visionOS
        .ornament(attachmentAnchor: .scene(.bottomLeading)) {
            if UIConstants.showMultimodalUI && exploreSection == .models {
                ModelTypeFilterToggle(selection: modelTypeFilter) { newFilter in
                    withAnimation(.snappy) {
                        modelTypeFilterRaw = newFilter.rawValue
                        filterManager.filter = newFilter
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        #endif
    }

    /// Applies a section switch requested by an App Intent. When no search
    /// query is pending, the request ends here; otherwise the target explore
    /// view consumes the query (and clears both fields) once visible.
    private func applyPendingExploreSection(_ section: ExploreSection?) {
        guard let section else { return }
        if exploreSection != section {
            withAnimation(.snappy) { exploreSectionRaw = section.rawValue }
        }
        if tabRouter.pendingExploreSearch == nil {
            DispatchQueue.main.async { tabRouter.pendingExploreSection = nil }
        }
    }
}

struct ModelTypeFilterToggle: View {
    let selection: ModelTypeFilter
    var onChange: (ModelTypeFilter) -> Void
    
    var body: some View {
        HStack(spacing: 4) {
            ForEach(ModelTypeFilter.allCases, id: \.self) { filter in
                Button(action: { onChange(filter) }) {
                    HStack(spacing: 4) {
                        Image(systemName: filter.icon)
                            .font(.caption2)
                        Text(filter.label)
                            .font(.caption2)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selection == filter ? filter.color : Color(.systemGray5))
                    )
                    .foregroundColor(selection == filter ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

@MainActor
struct ExploreSwitchBar: View {
    let selection: ExploreSection
    var onChange: (ExploreSection) -> Void

    var body: some View {
        let segmentRadius: CGFloat = UIConstants.cornerRadius
        let padding: CGFloat = 6

        HStack(spacing: 0) {
            Picker("", selection: Binding(get: { selection }, set: { onChange($0) })) {
                Text(LocalizedStringKey("Models")).tag(ExploreSection.models)
                Text(LocalizedStringKey("Datasets")).tag(ExploreSection.datasets)
            }
            .pickerStyle(.segmented)
        }
        .padding(padding)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: segmentRadius + padding, style: .continuous)
        )
        .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        .padding(.horizontal, UIConstants.defaultPadding)
        .padding(.bottom, 8)
    }
}

#endif
