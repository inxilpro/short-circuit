import Foundation
import Testing
@testable import Short_Circuit

// Every test here drives SimulatedHandlerBackend; nothing may construct WorkspaceHandlerBackend.

/// Serves Kinds with handlers read from the simulated system. The Kind list can be swapped
/// between loads, to model an app update changing what macOS lists for a type.
private final class BackendKindProvider: KindProviding, @unchecked Sendable {
    let backend: SimulatedHandlerBackend
    private let lock = NSLock()
    private var _kinds: [Kind]
    var delay: Duration = .zero

    init(backend: SimulatedHandlerBackend, kinds: [Kind] = SampleKindProvider.kinds) {
        self.backend = backend
        _kinds = kinds
    }

    var kinds: [Kind] {
        get { lock.withLock { _kinds } }
        set { lock.withLock { _kinds = newValue } }
    }

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] {
        if delay > .zero { try await Task.sleep(for: delay) }
        var kinds = kinds
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
struct UndoTests {
    private func makeStore(
        handlers: [KindMember.Target: URL]? = nil,
        behaviors: [KindMember.Target: SimulatedHandlerBackend.Behavior] = [:],
        latency: Duration = .zero
    ) async -> (KindStore, SimulatedHandlerBackend, UndoManager, BackendKindProvider) {
        let backend: SimulatedHandlerBackend
        if let handlers {
            backend = SimulatedHandlerBackend(handlers: handlers, behaviors: behaviors, latency: latency)
        } else {
            backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, behaviors: behaviors, latency: latency)
        }
        let provider = BackendKindProvider(backend: backend)
        let store = KindStore(provider: provider, writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        await store.refresh()
        return (store, backend, undoManager, provider)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    private func undo(_ undoManager: UndoManager, in store: KindStore) async {
        undoManager.undo()
        await store.undoTask?.value
    }

    /// Lets a busy Undo's deferred re-registration run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func undoRestoresTheChangedMemberAndNamesTheType() async throws {
        let (store, backend, undoManager, _) = await makeStore()
        await store.setDefault(.photos, for: try kind("heic", in: store))
        #expect(await backend.currentHandler(for: .uti("public.heic")) == AppRef.photos.url)
        #expect(undoManager.undoActionName == "Set Default App for “HEIC image”")
        #expect(store.undoMenuTitle == "Undo Set Default App for “HEIC image”")

        let callsBefore = backend.calls.count
        await undo(undoManager, in: store)

        #expect(await backend.currentHandler(for: .uti("public.heic")) == AppRef.preview.url)
        #expect(await backend.currentHandler(for: .uti("public.heif")) == AppRef.photos.url)
        #expect(backend.calls.dropFirst(callsBefore).map(\.target) == [.uti("public.heic")])
        #expect(try kind("heic", in: store).members.first?.defaultApp?.url == AppRef.preview.url)
        #expect(store.message?.isFailure == false)
    }

    /// One `http` call moved the whole browser role, so one `http` call puts it back.
    @Test func browserUndoIsOneCallThroughHttp() async throws {
        let (store, backend, undoManager, _) = await makeStore()
        await store.setDefault(.textEdit, for: .uti("public.html"), in: try kind("web-page", in: store))
        #expect(await backend.currentHandler(for: .scheme("https")) == AppRef.textEdit.url)
        #expect(!undoManager.undoActionName.hasSuffix("(Partly)"))

        let callsBefore = backend.calls.count
        await undo(undoManager, in: store)

        #expect(backend.calls.dropFirst(callsBefore).map(\.target) == [.scheme("http")])
        for target in WritePlan.browserTargets {
            #expect(await backend.currentHandler(for: target) == AppRef.safari.url)
        }
    }

    @Test func aBatchUndoesAsOneGroup() async throws {
        let (store, backend, undoManager, _) = await makeStore()
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "png"]
        await store.applyBatch()
        #expect(await backend.currentHandler(for: .uti("public.jpeg")) == AppRef.photos.url)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.photos.url)
        #expect(undoManager.undoActionName == "Make Photos the Default for 2 Types")

        await undo(undoManager, in: store)

        #expect(await backend.currentHandler(for: .uti("public.jpeg")) == AppRef.preview.url)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.preview.url)
        #expect(!undoManager.canUndo)
    }

    @Test func aDeclinedPromptStopsTheRestOfTheUndo() async throws {
        let (store, backend, _, _) = await makeStore(behaviors: [.uti("public.heif"): .declineWithError])
        let record = KindStore.UndoRecord(
            actionName: "Test",
            restores: [
                .init(target: .uti("public.heif"), app: .preview, after: [.uti("public.heif"): AppRef.photos.url], before: [.uti("public.heif"): AppRef.preview.url], label: "public.heif"),
                .init(target: .uti("public.heic"), app: .photos, after: [.uti("public.heic"): AppRef.preview.url], before: [.uti("public.heic"): AppRef.photos.url], label: "public.heic"),
            ],
            kindIDs: ["heic"]
        )

        await store.performUndo(record)

        #expect(backend.calls.map(\.target) == [.uti("public.heif")])
        #expect(await backend.currentHandler(for: .uti("public.heic")) == AppRef.preview.url)
        #expect(store.message?.isFailure == true)
        #expect(store.message?.text.contains("One change wasn’t attempted") == true)
        #expect(store.results(for: try kind("heic", in: store)).first?.outcome == .declined)
    }

    @Test func nothingChangedMeansNothingToUndo() async throws {
        let (store, _, undoManager, _) = await makeStore(behaviors: [.uti("public.jpeg"): .declineSilently])
        await store.setDefault(.preview, for: try kind("png", in: store))
        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        #expect(!undoManager.canUndo)
    }

    @Test func restoresSkipTargetsThatHadNoDefault() {
        let applied = [
            MemberResult(target: .uti("a"), outcome: .changed, handlerAfter: .preview),
            MemberResult(target: .uti("b"), outcome: .changed, handlerAfter: .preview),
            MemberResult(target: .uti("c"), outcome: .declined, handlerAfter: .photos),
        ]
        let before: [KindMember.Target: AppRef?] = [.uti("a"): AppRef.photos, .uti("b"): Optional<AppRef>.none, .uti("c"): AppRef.photos]
        let restores = KindStore.restores(for: applied, before: before, label: "Test")

        #expect(restores.map(\.target) == [.uti("a")])
        #expect(restores.first?.app == AppRef.photos)
        #expect(restores.first?.after == [.uti("a"): AppRef.preview.url])
    }

    // MARK: R1, a newer change wins

    @Test func aTypeChangedAgainOutsideTheAppIsLeftAlone() async throws {
        let (store, backend, undoManager, _) = await makeStore()
        await store.setDefault(.photos, for: try kind("png", in: store))
        backend.changeExternally(.uti("public.png"), to: AppRef.textEdit.url)
        let callsBefore = backend.calls.count

        await undo(undoManager, in: store)

        #expect(backend.calls.count == callsBefore)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.textEdit.url)
        #expect(store.message?.text.contains("PNG image was changed again since; left as is.") == true)
    }

    @Test func refreshDropsHistoryForTypesThatMoved() async throws {
        let (store, backend, undoManager, _) = await makeStore()
        await store.setDefault(.photos, for: try kind("jpeg", in: store))
        await store.setDefault(.photos, for: try kind("png", in: store))
        backend.changeExternally(.uti("public.png"), to: AppRef.textEdit.url)

        await store.refresh(force: true)

        #expect(store.undoHistory.count == 1)
        #expect(undoManager.undoActionName == "Set Default App for “JPEG image”")
        #expect(store.message?.text.contains("One change can no longer be undone") == true)

        await undo(undoManager, in: store)
        #expect(await backend.currentHandler(for: .uti("public.jpeg")) == AppRef.preview.url)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.textEdit.url)
        #expect(!undoManager.canUndo)
    }

    // MARK: R3, the same eligibility as a normal change

    @Test func anAppMacOSNoLongerListsIsNotRestored() async throws {
        let (store, backend, undoManager, provider) = await makeStore()
        await store.setDefault(.photos, for: try kind("png", in: store))
        provider.kinds = provider.kinds.map { kind in
            var kind = kind
            if kind.id == "png" { kind.members[0].candidateURLs = [AppRef.photos.url] }
            return kind
        }
        await store.refresh(force: true)
        let callsBefore = backend.calls.count

        await undo(undoManager, in: store)

        #expect(backend.calls.count == callsBefore)
        #expect(store.message?.text.contains("macOS no longer lists Preview for PNG image") == true)
    }

    @Test func anUninstalledAppIsNotRestored() async throws {
        let gone = URL(filePath: "/Applications/Gone Viewer.app", directoryHint: .isDirectory)
        var handlers: [KindMember.Target: URL] = [:]
        for member in SampleKindProvider.kinds.flatMap(\.members) { handlers[member.target] = member.defaultApp?.url }
        handlers[.uti("public.png")] = gone
        let (store, backend, undoManager, _) = await makeStore(handlers: handlers)
        await store.setDefault(.photos, for: try kind("png", in: store))
        #expect(undoManager.canUndo)
        let callsBefore = backend.calls.count

        await undo(undoManager, in: store)

        #expect(backend.calls.count == callsBefore)
        #expect(store.message?.text.contains("is no longer installed") == true)
    }

    // MARK: R4, busy Undo keeps its entry

    @Test func undoDuringAChangeKeepsTheEntryAndRunsLater() async throws {
        let (store, backend, undoManager, _) = await makeStore(latency: .milliseconds(150))
        await store.setDefault(.photos, for: try kind("png", in: store))
        let jpeg = try kind("jpeg", in: store)
        let running = Task { await store.setDefault(.photos, for: jpeg) }
        for _ in 0..<200 where !store.isWriting { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!store.canUndoNow)

        undoManager.undo()
        await settle()
        #expect(undoManager.canUndo)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.photos.url)

        await running.value
        await undo(undoManager, in: store)
        #expect(await backend.currentHandler(for: .uti("public.jpeg")) == AppRef.preview.url)
        await undo(undoManager, in: store)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.preview.url)
        #expect(backend.maxConcurrentCalls == 1)
    }

    @Test func twoQuickUndosRestoreBothChanges() async throws {
        let (store, backend, undoManager, _) = await makeStore(latency: .milliseconds(50))
        await store.setDefault(.photos, for: try kind("png", in: store))
        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        undoManager.undo()
        undoManager.undo()
        await store.undoTask?.value
        await settle()
        #expect(await backend.currentHandler(for: .uti("public.jpeg")) == AppRef.preview.url)
        #expect(undoManager.canUndo)

        await undo(undoManager, in: store)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.preview.url)
        #expect(!undoManager.canUndo)
    }

    @Test func undoDuringARefreshKeepsTheEntry() async throws {
        let (store, backend, undoManager, provider) = await makeStore()
        await store.setDefault(.photos, for: try kind("png", in: store))
        provider.delay = .milliseconds(150)
        let refreshing = Task { await store.refresh(force: true) }
        for _ in 0..<200 where !store.isRefreshing { try? await Task.sleep(for: .milliseconds(5)) }

        let callsBefore = backend.calls.count
        undoManager.undo()
        await settle()
        #expect(backend.calls.count == callsBefore)
        #expect(undoManager.canUndo)

        await refreshing.value
        await undo(undoManager, in: store)
        #expect(await backend.currentHandler(for: .uti("public.png")) == AppRef.preview.url)
    }

    // MARK: R5, a mixed browser role can't be restored exactly

    @Test func mixedBrowserRoleUndoSaysWhatItCouldNotRestore() async throws {
        var handlers: [KindMember.Target: URL] = [:]
        for member in SampleKindProvider.kinds.flatMap(\.members) { handlers[member.target] = member.defaultApp?.url }
        handlers[.scheme("https")] = AppRef.textEdit.url
        handlers[.uti("public.html")] = AppRef.textEdit.url
        let (store, backend, undoManager, _) = await makeStore(handlers: handlers)

        await store.setDefault(.textEdit, for: .uti("public.html"), in: try kind("web-page", in: store))
        #expect(await backend.currentHandler(for: .scheme("http")) == AppRef.textEdit.url)
        #expect(undoManager.undoActionName == "Set Default App for public.html (Partly)")

        await undo(undoManager, in: store)

        #expect(await backend.currentHandler(for: .scheme("http")) == AppRef.safari.url)
        #expect(await backend.currentHandler(for: .scheme("https")) == AppRef.safari.url)
        let text = try #require(store.message?.text)
        #expect(text.contains("https: links now opens with Safari; before the change it opened with TextEdit"))
        #expect(store.message?.isFailure == true)
    }
}

/// SwiftUI clears a `fileImporter`'s presentation binding before it calls the completion, so
/// the pick must survive dismissal.
@MainActor
struct OtherAppOrderTests {
    @Test func aPickArrivingAfterDismissalStillApplies() async throws {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds)
        let store = KindStore(provider: BackendKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()

        store.requestOtherApp(for: .kind("png"))
        #expect(store.isPresentingAppChoice)
        store.isPresentingAppChoice = false
        let target = try #require(store.pendingAppChoice)
        await store.completeAppChoice(AppRef.photos.url, for: target)

        #expect(backend.calls.map(\.target) == [.uti("public.png")])
        #expect(await backend.currentHandler(for: .uti("public.png")).map(AppIdentity.canonical) == AppIdentity.canonical(AppRef.photos.url))
        #expect(store.lastAppFolder == AppRef.photos.url.deletingLastPathComponent())
        #expect(store.pendingAppChoice == nil)
    }

    @Test func aMemberPickAppliesToThatMemberOnly() async throws {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds)
        let store = KindStore(provider: BackendKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()

        store.requestOtherApp(for: .member("heic", .uti("public.heif")))
        store.isPresentingAppChoice = false
        await store.completeAppChoice(AppRef.preview.url, for: try #require(store.pendingAppChoice))

        #expect(backend.calls.map(\.target) == [.uti("public.heif")])
    }

    @Test func cancellingClearsThePendingTarget() async {
        let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview)
        await store.refresh()
        store.requestOtherApp(for: .kind("png"))
        store.isPresentingAppChoice = false
        store.cancelAppChoice()

        #expect(store.pendingAppChoice == nil)
    }
}

/// Types whose every declared member loses its extensions to another type (Canon TIFF raw on the
/// dev Mac) have nothing a whole-type change could affect, but each member can still be set alone.
@MainActor
struct NoWholeTypeTargetTests {
    private func allShadowed() -> Kind {
        Kind(
            id: "canon-tiff-raw", name: "Canon TIFF raw", category: .images,
            members: [
                KindMember(target: .uti("com.canon.tif-raw-image"), defaultApp: .preview, governedExtensions: []),
                KindMember(target: .uti("com.canon.tif-raw-image.alt"), defaultApp: .photos, governedExtensions: []),
            ],
            extensions: ["tif"], mimeTypes: [],
            candidates: [.preview, .photos]
        )
    }

    @Test func thereIsNoWholeTypeChangeAndNoSplit() {
        let kind = allShadowed()

        #expect(!kind.hasWholeTypeTargets)
        #expect(!kind.isSplit)
        #expect(kind.fixSplitApp == nil)
        #expect(!kind.candidates(for: kind.members[0]).isEmpty)
    }

    @Test func memberChangesStillWorkAndWholeTypeChangesMakeNoCall() async throws {
        let kind = allShadowed()
        let backend = SimulatedHandlerBackend(kinds: [kind])
        let store = KindStore(provider: BackendKindProvider(backend: backend, kinds: [kind]), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()

        await store.setDefault(.photos, for: kind)
        #expect(backend.calls.isEmpty)

        await store.setDefault(.photos, for: kind.members[0].target, in: kind)
        #expect(backend.calls.map(\.target) == [kind.members[0].target])
    }
}

/// Safari is reachable through three paths; a re-read through any of them is the same app.
struct SameAppTests {
    @Test func symlinkedAppPathsCompareEqual() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "same-app-\(UUID().uuidString)", directoryHint: .isDirectory)
        let real = folder.appending(path: "Preboot/Safari.app", directoryHint: .isDirectory)
        let link = folder.appending(path: "Applications/Safari.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(WritePlan.sameApp(link, real))
        #expect(WritePlan.sameApp(real.appending(path: "Contents/..", directoryHint: .isDirectory), link))
        #expect(!WritePlan.sameApp(link, folder.appending(path: "Other.app")))

        let plan = WritePlan(app: link, targets: [.uti("public.html"), .uti("public.xhtml")]) { _ in real }
        #expect(plan.promptCount == 0)
    }
}
