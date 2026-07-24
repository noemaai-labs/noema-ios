import Foundation
import XCTest
@testable import Noema

final class MemoryToolTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let trackedKeys = [
        "memoryEnabled",
        "currentModelSupportsFunctionCalling",
        "currentModelFormat",
        "currentModelIsRemote",
        SystemPreset.customSystemPromptIntroKey
    ]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        savedDefaults = trackedKeys.reduce(into: [:]) { result, key in
            result[key] = defaults.object(forKey: key)
        }
    }

    override func tearDown() {
        for key in trackedKeys {
            if let value = savedDefaults[key] ?? nil {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        savedDefaults.removeAll()
        super.tearDown()
    }

    @MainActor
    func testMemoryStoreCRUDPersistsAcrossReload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-store-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = MemoryStore(fileURL: url, notificationCenter: .init())
        let created = try store.create(title: "User Preferences", content: "User prefers pnpm.")
        XCTAssertEqual(created.title, "User Preferences")

        let inserted = try store.insert(id: created.id.uuidString, title: nil, content: " Use frozen lockfiles.", at: nil)
        XCTAssertTrue(inserted.content.contains("Use frozen lockfiles."))

        let replaced = try store.stringReplace(
            id: created.id.uuidString,
            title: nil,
            oldString: "pnpm",
            newString: "bun"
        )
        XCTAssertTrue(replaced.content.contains("bun"))

        let renamed = try store.rename(id: created.id.uuidString, title: nil, newTitle: "Package Manager Preference")
        XCTAssertEqual(renamed.title, "Package Manager Preference")

        let reloaded = MemoryStore(fileURL: url, notificationCenter: .init())
        let persisted = try reloaded.entry(id: created.id.uuidString, title: nil)
        XCTAssertEqual(persisted.title, "Package Manager Preference")
        XCTAssertTrue(persisted.content.contains("bun"))
    }

    func testMemoryToolAvailabilityTracksMasterToggle() async {
        defaults.set(true, forKey: "memoryEnabled")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set(ModelFormat.gguf.rawValue, forKey: "currentModelFormat")
        defaults.set(false, forKey: "currentModelIsRemote")

        let memoryToolAvailableWhenEnabled = await ToolManager.shared.isToolAvailable("noema.memory")

        XCTAssertTrue(MemoryToolGate.isAvailable())
        XCTAssertTrue(ToolAvailability.current(currentFormat: .gguf).memory)
        XCTAssertTrue(memoryToolAvailableWhenEnabled)

        defaults.set(false, forKey: "memoryEnabled")

        let memoryToolAvailableWhenDisabled = await ToolManager.shared.isToolAvailable("noema.memory")

        XCTAssertFalse(MemoryToolGate.isAvailable())
        XCTAssertFalse(ToolAvailability.current(currentFormat: .gguf).memory)
        XCTAssertFalse(memoryToolAvailableWhenDisabled)
    }

    func testMemoryToolUnavailableForRemoteSessions() async {
        defaults.set(true, forKey: "memoryEnabled")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set(ModelFormat.gguf.rawValue, forKey: "currentModelFormat")
        defaults.set(true, forKey: "currentModelIsRemote")

        let memoryToolAvailableWhenRemote = await ToolManager.shared.isToolAvailable("noema.memory")

        XCTAssertFalse(MemoryToolGate.isAvailable())
        XCTAssertFalse(ToolAvailability.current(currentFormat: .gguf).memory)
        XCTAssertFalse(memoryToolAvailableWhenRemote)
    }

    func testMemoryToolUnavailableForLocalMLX() async {
        defaults.set(true, forKey: "memoryEnabled")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set(ModelFormat.mlx.rawValue, forKey: "currentModelFormat")
        defaults.set(false, forKey: "currentModelIsRemote")

        let memoryToolAvailableForLocalMLX = await ToolManager.shared.isToolAvailable("noema.memory")

        XCTAssertFalse(MemoryToolGate.isAvailable())
        XCTAssertFalse(ToolAvailability.current(currentFormat: .mlx).memory)
        XCTAssertFalse(memoryToolAvailableForLocalMLX)
    }

    @MainActor
    func testMemoryStoreEnforcesMaximumEntryCount() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-store-cap-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = MemoryStore(fileURL: url, notificationCenter: .init())
        for index in 0..<MemoryStore.maximumEntries {
            _ = try store.create(title: "Memory \(index)", content: "Content \(index)")
        }

        XCTAssertEqual(store.entries.count, MemoryStore.maximumEntries)

        XCTAssertThrowsError(
            try store.create(title: "Overflow", content: "This should fail.")
        ) { error in
            XCTAssertEqual(error as? MemoryStoreError, .maximumEntriesReached)
        }
    }

    func testMemoryPromptBudgeterPrefersRecentlyUpdatedEntries() {
        let now = Date()
        let oldest = MemoryEntry(
            id: UUID(),
            title: "Oldest",
            content: "old",
            createdAt: now.addingTimeInterval(-300),
            updatedAt: now.addingTimeInterval(-300)
        )
        let newest = MemoryEntry(
            id: UUID(),
            title: "Newest",
            content: "new",
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-10)
        )
        let middle = MemoryEntry(
            id: UUID(),
            title: "Middle",
            content: "mid",
            createdAt: now.addingTimeInterval(-200),
            updatedAt: now.addingTimeInterval(-100)
        )

        let plan = MemoryPromptBudgeter.plan(
            entries: [oldest, newest, middle],
            isActive: true,
            promptTokenLimit: 3,
            basePromptTokens: 1
        ) { candidate in
            1 + candidate.count
        }

        XCTAssertEqual(plan.entries.map(\.title), ["Newest", "Middle"])
        XCTAssertEqual(plan.status.state, .partiallyLoaded)
        XCTAssertEqual(plan.status.loadedCount, 2)
        XCTAssertEqual(plan.status.omittedCount, 1)
    }

    func testMemoryPromptBudgeterCanDisableAllMemoriesWhenNothingFits() {
        let entry = MemoryEntry(title: "Constraint", content: "Tests require Redis.")
        let plan = MemoryPromptBudgeter.plan(
            entries: [entry],
            isActive: true,
            promptTokenLimit: 10,
            basePromptTokens: 10
        ) { _ in
            11
        }

        XCTAssertTrue(plan.entries.isEmpty)
        XCTAssertEqual(plan.status.state, .notLoaded)
        XCTAssertEqual(plan.status.loadedCount, 0)
        XCTAssertEqual(plan.status.totalCount, 1)
        XCTAssertEqual(plan.status.omittedCount, 1)
    }

    func testSystemPromptResolverIncludesMemoryGuidanceAndSnapshot() {
        let snapshot = """
        Persistent Memory:
        Entries:
        1. Response Style
           id: 123
           content: Avoid em dashes in responses.
        """

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability(webSearch: false, python: false, memory: true),
            memorySnapshot: snapshot
        )

        XCTAssertTrue(prompt.contains("**MEMORY (ARMED)**"))
        XCTAssertTrue(prompt.contains("Avoid em dashes in responses."))
        XCTAssertTrue(prompt.contains("multiple conversations"))
        XCTAssertTrue(prompt.contains("All stored memories are about the user"))
        XCTAssertTrue(prompt.contains("If a memory says \"My name is ...\""))
        XCTAssertTrue(prompt.contains("Do not copy placeholder or example text"))
        XCTAssertFalse(prompt.contains("User prefers pnpm over npm."))
    }

    func testSystemPromptResolverOmitsMemoryGuidanceForRemoteToolAvailability() {
        defaults.set(true, forKey: "memoryEnabled")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set(ModelFormat.gguf.rawValue, forKey: "currentModelFormat")
        defaults.set(true, forKey: "currentModelIsRemote")

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: false,
            toolAvailabilityOverride: ToolAvailability.current(currentFormat: .gguf),
            memorySnapshot: """
            Persistent Memory:
            Entries:
            1. Remote Preference
               id: 123
               content: This should not be injected for remote sessions.
            """
        )

        XCTAssertFalse(prompt.contains("**MEMORY (ARMED)**"))
        XCTAssertFalse(prompt.contains("This should not be injected for remote sessions."))
    }

    func testSystemPromptResolverUsesDefaultEditableIntroAndLockedGeneralSuffix() {
        defaults.removeObject(forKey: SystemPreset.customSystemPromptIntroKey)

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability.none
        )

        XCTAssertTrue(prompt.hasPrefix(SystemPreset.defaultEditableIntro))
        XCTAssertTrue(prompt.contains("#### Math and notation"))
        XCTAssertTrue(prompt.contains("#### Style and safety"))
        XCTAssertTrue(prompt.contains("Current date:"))
    }

    func testSystemPromptResolverUsesCustomEditableIntroWithoutRemovingLockedSections() {
        let customIntro = """
        You are Noema, a concise assistant.

        Prefer short answers and lead with the conclusion.
        """
        defaults.set(customIntro, forKey: SystemPreset.customSystemPromptIntroKey)

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability.none
        )

        XCTAssertTrue(prompt.hasPrefix(customIntro))
        XCTAssertTrue(prompt.contains("#### Math and notation"))
        XCTAssertTrue(prompt.contains("#### Style and safety"))
        XCTAssertFalse(prompt.hasPrefix(SystemPreset.defaultEditableIntro))
    }

    func testBlankEditableIntroFallsBackToDefault() {
        defaults.set("   \n\n   ", forKey: SystemPreset.customSystemPromptIntroKey)

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability.none
        )

        XCTAssertTrue(prompt.hasPrefix(SystemPreset.defaultEditableIntro))
    }

    func testSystemPromptResolverKeepsLockedSectionsWhenEditableIntroIsExcluded() {
        defaults.set("Global intro that should be excluded.", forKey: SystemPreset.customSystemPromptIntroKey)

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability.none,
            editableIntro: nil
        )

        XCTAssertFalse(prompt.contains("Global intro that should be excluded."))
        XCTAssertTrue(prompt.contains("#### Math and notation"))
        XCTAssertTrue(prompt.contains("#### Style and safety"))
        XCTAssertTrue(prompt.contains("Current date:"))
    }

    func testSystemPromptResolverUsesExplicitEditableIntroOverride() {
        defaults.set("Global intro that should not win.", forKey: SystemPreset.customSystemPromptIntroKey)
        let overrideIntro = """
        Model-specific intro.

        Be terse and precise.
        """

        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability.none,
            editableIntro: overrideIntro
        )

        XCTAssertTrue(prompt.hasPrefix(overrideIntro))
        XCTAssertFalse(prompt.hasPrefix("Global intro that should not win."))
        XCTAssertTrue(prompt.contains("#### Style and safety"))
    }

    func testSystemPromptResolverOmitsSnapshotWhenNoMemoriesArePreloaded() {
        let prompt = SystemPromptResolver.general(
            currentFormat: .gguf,
            includeThinkRestriction: true,
            toolAvailabilityOverride: ToolAvailability(webSearch: false, python: false, memory: true),
            memorySnapshot: nil
        )

        XCTAssertTrue(prompt.contains("**MEMORY (ARMED)**"))
        XCTAssertFalse(prompt.contains("Persistent Memory:"))
    }

    func testRAGPromptCanStillIncludeMemoryGuidance() {
        let customIntro = """
        You are Noema, a retrieval helper.

        Keep answers tightly scoped to the evidence.
        """
        defaults.set(customIntro, forKey: SystemPreset.customSystemPromptIntroKey)

        var prompt = SystemPreset.rag.text
        let snapshot = """
        Persistent Memory:
        Entries:
        1. Project Constraint
           id: abc
           content: Tests require Redis.
        """

        let appended = SystemPromptResolver.appendToolGuidance(
            to: &prompt,
            availability: ToolAvailability(webSearch: false, python: false, memory: true),
            includeThinkRestriction: true,
            memorySnapshot: snapshot
        )

        XCTAssertTrue(appended)
        XCTAssertTrue(prompt.hasPrefix(customIntro))
        XCTAssertTrue(prompt.contains("You are a retrieval-focused assistant."))
        XCTAssertTrue(prompt.contains("Tests require Redis."))
        XCTAssertTrue(prompt.contains("**MEMORY (ARMED)**"))
    }

    @MainActor
    func testChatVMLiveRefreshesSystemPromptWhenCustomIntroChanges() async throws {
        defaults.set(SystemPreset.defaultEditableIntro, forKey: SystemPreset.customSystemPromptIntroKey)

        let vm = ChatVM()
        let updatedIntro = """
        You are Noema, a highly structured assistant.

        Prefer compact answers with a one-sentence summary first.
        """

        defaults.set(updatedIntro, forKey: SystemPreset.customSystemPromptIntroKey)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await Task.yield()
        await Task.yield()

        let activeID = vm.activeSessionID
        let sessions = vm.sessions
        let resolvedActiveID = try XCTUnwrap(activeID)
        let session = try XCTUnwrap(sessions.first(where: { $0.id == resolvedActiveID }))
        let systemMessage = try XCTUnwrap(session.messages.first(where: { $0.role.lowercased() == "system" }))

        XCTAssertTrue(systemMessage.text.hasPrefix(updatedIntro))
        XCTAssertTrue(systemMessage.text.contains("#### Math and notation"))
    }

    @MainActor
    func testChatVMUsesPerModelPromptOverrideAheadOfGlobalPrompt() throws {
        let globalIntro = "Global intro that should lose."
        let modelIntro = "Per-model intro that should win."
        defaults.set(globalIntro, forKey: SystemPreset.customSystemPromptIntroKey)

        var settings = ModelSettings.default(for: .gguf)
        settings.systemPromptMode = .override
        settings.systemPromptOverride = modelIntro

        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/noema/tests/override.gguf"),
            loadedFormat: .gguf,
            loadedSettings: settings
        )

        let systemMessage = try activeSystemMessage(in: vm)

        XCTAssertTrue(systemMessage.text.hasPrefix(modelIntro))
        XCTAssertFalse(systemMessage.text.hasPrefix(globalIntro))
        XCTAssertTrue(systemMessage.text.contains("#### Math and notation"))
    }

    @MainActor
    func testChatVMExcludeGlobalPromptKeepsLockedSections() throws {
        let globalIntro = "Global intro that should be excluded."
        defaults.set(globalIntro, forKey: SystemPreset.customSystemPromptIntroKey)

        var settings = ModelSettings.default(for: .gguf)
        settings.systemPromptMode = .excludeGlobal

        let vm = ChatVM()
        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: URL(fileURLWithPath: "/tmp/noema/tests/exclude.gguf"),
            loadedFormat: .gguf,
            loadedSettings: settings
        )

        let systemMessage = try activeSystemMessage(in: vm)

        XCTAssertFalse(systemMessage.text.contains(globalIntro))
        XCTAssertTrue(systemMessage.text.contains("#### Math and notation"))
        XCTAssertTrue(systemMessage.text.contains("#### Style and safety"))
        XCTAssertTrue(systemMessage.text.contains("Current date:"))
    }

    @MainActor
    func testChatVMLiveRefreshesSystemPromptWhenLoadedPromptModeChanges() throws {
        let globalIntro = "Global intro that should be replaced."
        let modelIntro = "Per-model prompt after live refresh."
        defaults.set(globalIntro, forKey: SystemPreset.customSystemPromptIntroKey)

        let vm = ChatVM()
        let loadedURL = URL(fileURLWithPath: "/tmp/noema/tests/live-refresh.gguf")
        var inherited = ModelSettings.default(for: .gguf)
        inherited.systemPromptMode = .inheritGlobal

        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: loadedURL,
            loadedFormat: .gguf,
            loadedSettings: inherited
        )
        XCTAssertTrue(try activeSystemMessage(in: vm).text.hasPrefix(globalIntro))

        var overridden = inherited
        overridden.systemPromptMode = .override
        overridden.systemPromptOverride = modelIntro

        vm.setLoadedStateForTesting(
            modelLoaded: true,
            loadedURL: loadedURL,
            loadedFormat: .gguf,
            loadedSettings: overridden
        )

        let refreshed = try activeSystemMessage(in: vm)
        XCTAssertTrue(refreshed.text.hasPrefix(modelIntro))
        XCTAssertFalse(refreshed.text.hasPrefix(globalIntro))
    }

    @MainActor
    func testMemoryToolStreamingPathExecutesAndPersistsEntry() async throws {
        defaults.set(true, forKey: "memoryEnabled")
        defaults.set(true, forKey: "currentModelSupportsFunctionCalling")
        defaults.set(ModelFormat.gguf.rawValue, forKey: "currentModelFormat")
        defaults.set(false, forKey: "currentModelIsRemote")

        await ToolRegistrar.shared.initializeTools()

        let uniqueTitle = "Memory Test \(UUID().uuidString)"
        defer {
            if let entry = try? MemoryStore.shared.entry(id: nil, title: uniqueTitle) {
                _ = try? MemoryStore.shared.delete(id: entry.id.uuidString, title: nil)
            }
        }

        let vm = makeChatVM(userText: "Remember my preference.")
        let token = #"TOOL_CALL: {"tool":"noema.memory","tool_call_id":"mem-1","args":{"operation":"create","title":"\#(uniqueTitle)","content":"User prefers pnpm over npm."},"request_status":"ready"}"#

        let handled = await interceptToolCallIfPresent(
            token,
            messageIndex: 1,
            chatVM: vm
        )

        XCTAssertNotNil(handled)
        let call = try XCTUnwrap(vm.streamMsgs[1].toolCalls?.onlyElement)
        XCTAssertEqual(call.toolName, "noema.memory")
        XCTAssertEqual(call.phase, .completed)
        XCTAssertEqual(call.externalToolCallID, "mem-1")
        XCTAssertNotNil(try? MemoryStore.shared.entry(id: nil, title: uniqueTitle))
    }

    @MainActor
    private func makeChatVM(userText: String) -> ChatVM {
        let vm = ChatVM()
        vm.streamMsgs = [
            ChatVM.Msg(role: "🧑‍💻", text: userText, timestamp: Date()),
            ChatVM.Msg(role: "🤖", text: "", timestamp: Date(), streaming: true)
        ]
        return vm
    }

    @MainActor
    private func activeSystemMessage(in vm: ChatVM) throws -> ChatVM.Msg {
        let activeID = try XCTUnwrap(vm.activeSessionID)
        let session = try XCTUnwrap(vm.sessions.first(where: { $0.id == activeID }))
        return try XCTUnwrap(session.messages.first(where: { $0.role.lowercased() == "system" }))
    }
}

private extension Array {
    var onlyElement: Element? {
        count == 1 ? first : nil
    }
}
