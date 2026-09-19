import Foundation
import Testing
@testable import Short_Circuit

// Drives SimulatedHandlerBackend only; nothing here may construct WorkspaceHandlerBackend or call
// a real setter. The guard tests call the check alone.

private struct ExtensionKindProvider: KindProviding {
    let backend: SimulatedHandlerBackend

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] {
        var kinds = SampleKindProvider.kinds
        for kindIndex in kinds.indices {
            for memberIndex in kinds[kindIndex].members.indices {
                let target = kinds[kindIndex].members[memberIndex].target
                kinds[kindIndex].members[memberIndex].defaultApp = await backend.currentHandler(for: target).map(HandlerService.appRef(for:))
            }
        }
        return kinds
    }
}

@MainActor
struct ExtensionTargetTests {
    private func makeStore(declaredExtensions: [String: String] = [:]) async -> (KindStore, SimulatedHandlerBackend, UndoManager) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, declaredExtensions: declaredExtensions)
        let store = KindStore(provider: ExtensionKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        await store.refresh()
        return (store, backend, undoManager)
    }

    private func markdown(_ store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == "markdown" })
    }

    private func handler(_ target: KindMember.Target, in store: KindStore) throws -> URL? {
        try markdown(store).members.first { $0.target == target }?.defaultApp?.url
    }

    @Test func extensionTargetsAreReadAndEffective() async throws {
        let (store, backend, _) = await makeStore()
        let kind = try markdown(store)

        #expect(try handler(.fileExtension("markdown"), in: store) == AppRef.notes.url)
        #expect(await backend.currentHandler(for: .fileExtension("mdown")) == AppRef.textEdit.url)
        #expect(kind.effectiveMembers.map(\.target).contains(.fileExtension("mkd")))
        #expect(kind.isSplit)
    }

    @Test func oneExtensionRowChangesOnlyThatExtension() async throws {
        let (store, backend, _) = await makeStore()

        await store.setDefault(.textEdit, for: .fileExtension("markdown"), in: try markdown(store))

        #expect(backend.calls.map(\.target) == [.fileExtension("markdown")])
        #expect(try handler(.fileExtension("markdown"), in: store) == AppRef.textEdit.url)
        #expect(try handler(.uti("net.daringfireball.markdown"), in: store) == AppRef.textEdit.url)
        #expect(store.results(for: try markdown(store)).map(\.outcome) == [.changed])
        #expect(try !markdown(store).isSplit)
    }

    /// Nothing prompts for these, so they must never move as a side effect of another row.
    @Test func otherRowsNeverTouchExtensionTargets() async throws {
        let (store, backend, _) = await makeStore()

        await store.setDefault(.preview, for: .uti("net.daringfireball.markdown"), in: try markdown(store))
        await store.setDefault(.textEdit, for: .uti("public.html"), in: try #require(store.kinds.first { $0.id == "web-page" }))

        #expect(!backend.calls.contains { $0.target.isFileExtension })
        #expect(try handler(.fileExtension("markdown"), in: store) == AppRef.notes.url)
    }

    @Test func fixSplitSetsOnlyTheExtensionThatDiffers() async throws {
        let (store, backend, _) = await makeStore()
        let kind = try markdown(store)
        #expect(kind.fixSplitApp?.url == AppRef.textEdit.url)

        await store.fixSplit(kind)

        #expect(backend.calls.map(\.target) == [.fileExtension("markdown")])
        #expect(try !markdown(store).isSplit)
    }

    @Test func anExtensionThatNowResolvesToADeclaredTypeIsRefused() async throws {
        let (store, backend, _) = await makeStore(declaredExtensions: ["mkd": "com.example.markdown"])

        await store.setDefault(.preview, for: .fileExtension("mkd"), in: try markdown(store))

        #expect(backend.calls.map(\.target) == [.fileExtension("mkd")])
        #expect(await backend.currentHandler(for: .fileExtension("mkd")) == AppRef.textEdit.url)
        let result = try #require(store.results(for: try markdown(store)).first)
        guard case .failed(let domain, _, let message) = result.outcome else {
            Issue.record("expected a failure, got \(result.outcome)")
            return
        }
        #expect(domain == ExtensionTargetGuard.errorDomain)
        #expect(message.contains("com.example.markdown, a declared type"))
    }

    @Test func undoRestoresExtensionTargetsAndSaysWhatAsks() async throws {
        let (store, backend, undoManager) = await makeStore()
        await store.setDefault(.preview, for: try markdown(store))
        #expect(backend.calls.count == 4)

        let restores = try #require(store.undoHistory.last).restores
        #expect(restores.count == 4)
        #expect(restores.count { !$0.target.isFileExtension } == 1)
        undoManager.undo()
        await store.undoTask?.value

        #expect(store.message?.text == "Restored the previous apps.")
        #expect(try handler(.uti("net.daringfireball.markdown"), in: store) == AppRef.textEdit.url)
        #expect(try handler(.fileExtension("markdown"), in: store) == AppRef.notes.url)
        #expect(try handler(.fileExtension("mkd"), in: store) == AppRef.textEdit.url)
    }

    @Test func undoOfAnExtensionAloneDoesNotPromiseAPrompt() async throws {
        let (store, _, undoManager) = await makeStore()
        await store.setDefault(.textEdit, for: .fileExtension("markdown"), in: try markdown(store))

        #expect(try #require(store.undoHistory.last).restores.map(\.target) == [.fileExtension("markdown")])
        undoManager.undo()
        await store.undoTask?.value

        #expect(store.message?.text == "Restored the previous app. macOS didn’t ask about this.")

        #expect(try handler(.fileExtension("markdown"), in: store) == AppRef.notes.url)
    }

    @Test func batchCountsChangesAndPromptsSeparately() async throws {
        let (store, _, _) = await makeStore()
        let plan = AppBatchPlan(app: .preview, kinds: [try markdown(store)])

        #expect(plan.changeCount == 4)
        #expect(plan.promptCount == 1)
        #expect(plan.items.first?.changingExtensions == [".md", ".markdown", ".mdown", ".mkd"])
    }
}

@MainActor
struct ChangeWordingTests {
    @Test func promptsAreCountedOnlyForCallsMacOSConfirms() {
        #expect(ChangeWording.summary(changes: 0, prompts: 0) == "nothing needs changing")
        #expect(ChangeWording.summary(changes: 1, prompts: 1) == "macOS will ask you to confirm 1 change")
        #expect(ChangeWording.summary(changes: 2, prompts: 2) == "macOS will ask you to confirm 2 changes")
        #expect(ChangeWording.summary(changes: 3, prompts: 2) == "3 changes; macOS will ask about 2")
        #expect(ChangeWording.summary(changes: 1, prompts: 0) == "1 change, made without a macOS prompt")
        #expect(ChangeWording.summary(changes: 2, prompts: 0) == "2 changes, made without a macOS prompt")
    }

    @Test func undoSaysHowManyChangesMacOSWillAskAbout() {
        #expect(ChangeWording.undoStart(changes: 4, prompts: 1) == "Restoring the previous apps. 4 changes; macOS will ask about 1.")
        #expect(ChangeWording.undoStart(changes: 1, prompts: 0) == "Restoring the previous app. macOS doesn’t ask about these, so nothing will prompt you.")
        #expect(ChangeWording.undoStart(changes: 2, prompts: 2) == "Restoring the previous apps. macOS will ask you to confirm each of 2 changes.")
    }

    @Test func writePlanCountsExtensionsAsChangesNotPrompts() {
        let textEdit = AppRef.textEdit.url
        let plan = WritePlan(app: textEdit, targets: [.uti("public.rtf"), .fileExtension("markdown"), .fileExtension("mkd")]) { _ in AppRef.preview.url }

        #expect(plan.changeCount == 3)
        #expect(plan.promptCount == 1)
    }

    @Test func progressForAnExtensionDoesNotSayItWaitsForMacOS() {
        let step = WritePlan.Step(call: .fileExtension("markdown"), covers: [.fileExtension("markdown")])
        #expect(ChangeWording.progressTitle(WriteProgress(step: 1, total: 1, call: step)) == "Setting .markdown files…")
        #expect(ChangeWording.progressTitle(WriteProgress(step: 2, total: 3, call: step)) == "Setting .markdown files… change 2 of 3")
        let prompted = WritePlan.Step(call: .uti("public.rtf"), covers: [.uti("public.rtf")])
        #expect(ChangeWording.progressTitle(WriteProgress(step: 1, total: 3, call: prompted)) == "Waiting for macOS… change 1 of 3")
    }
}

/// The live backend's safety check, exercised without the setter.
struct ExtensionGuardTests {
    @Test func aDeclaredTypeIsRefused() {
        #expect(ExtensionTargetGuard.liveDeclaredType("txt") == "public.plain-text")
        #expect(throws: (any Error).self) {
            try ExtensionTargetGuard.check("txt", declaredType: ExtensionTargetGuard.liveDeclaredType)
        }
    }

    @Test func anExtensionOnlyADynamicTypeClaimsPasses() throws {
        let unclaimed = "sczz\(UUID().uuidString.prefix(8).lowercased())"
        #expect(ExtensionTargetGuard.liveDeclaredType(unclaimed) == nil)
        try ExtensionTargetGuard.check(unclaimed, declaredType: ExtensionTargetGuard.liveDeclaredType)
    }

    @Test func onlyPlainExtensionsBecomeFileNames() {
        for bad in ["", ".md", "a/b", "../x", "..", "a:b"] {
            #expect(!ExtensionTargetGuard.isPlainExtension(bad))
            #expect(throws: (any Error).self) { try ExtensionTargetGuard.check(bad) { _ in nil } }
        }
        #expect(ExtensionTargetGuard.isPlainExtension("markdown"))
    }
}
