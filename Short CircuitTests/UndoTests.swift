import Foundation
import Testing
@testable import Short_Circuit

// Every test here drives SimulatedHandlerBackend; nothing may construct WorkspaceHandlerBackend.

/// Serves the sample Kinds with handlers read from the simulated system.
private struct BackendKindProvider: KindProviding {
    let backend: SimulatedHandlerBackend
    var kinds = SampleKindProvider.kinds

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] {
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
        behaviors: [KindMember.Target: SimulatedHandlerBackend.Behavior] = [:]
    ) async -> (KindStore, SimulatedHandlerBackend, UndoManager) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, behaviors: behaviors)
        let store = KindStore(provider: BackendKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        await store.refresh()
        return (store, backend, undoManager)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    private func undo(_ undoManager: UndoManager, in store: KindStore) async {
        undoManager.undo()
        await store.undoTask?.value
    }

    @Test func undoRestoresTheChangedMemberAndNamesTheType() async throws {
        let (store, backend, undoManager) = await makeStore()
        await store.setDefault(.photos, for: try kind("heic", in: store))
        #expect(await backend.currentHandler(for: .uti("public.heic")) == AppRef.photos.url)
        #expect(undoManager.undoActionName == "Set Default App for “HEIC image”")

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
        let (store, backend, undoManager) = await makeStore()
        await store.setDefault(.textEdit, for: .uti("public.html"), in: try kind("web-page", in: store))
        #expect(await backend.currentHandler(for: .scheme("https")) == AppRef.textEdit.url)

        let callsBefore = backend.calls.count
        await undo(undoManager, in: store)

        #expect(backend.calls.dropFirst(callsBefore).map(\.target) == [.scheme("http")])
        for target in WritePlan.browserTargets {
            #expect(await backend.currentHandler(for: target) == AppRef.safari.url)
        }
    }

    @Test func aBatchUndoesAsOneGroup() async throws {
        let (store, backend, undoManager) = await makeStore()
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
        let (store, backend, _) = await makeStore(behaviors: [.uti("public.heif"): .declineWithError])
        let record = KindStore.UndoRecord(
            actionName: "Test",
            restores: [.init(target: .uti("public.heif"), app: .preview), .init(target: .uti("public.heic"), app: .photos)],
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
        let (store, _, undoManager) = await makeStore(behaviors: [.uti("public.jpeg"): .declineSilently])
        await store.setDefault(.preview, for: try kind("png", in: store))
        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        #expect(!undoManager.canUndo)
    }

    @Test func undoWhileAnotherChangeRunsIsRefusedAndSaysSo() async throws {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, latency: .milliseconds(300))
        let store = KindStore(provider: BackendKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        let jpeg = try kind("jpeg", in: store)
        let running = Task { await store.setDefault(.photos, for: jpeg) }
        for _ in 0..<200 where !store.isWriting { try? await Task.sleep(for: .milliseconds(5)) }

        await store.performUndo(KindStore.UndoRecord(actionName: "Test", restores: [.init(target: .uti("public.png"), app: .photos)], kindIDs: ["png"]))
        await running.value

        #expect(backend.calls.map(\.target) == [.uti("public.jpeg")])
        #expect(store.message?.isFailure == true)
    }

    @Test func restoresSkipTargetsThatHadNoDefault() {
        let applied = [
            MemberResult(target: .uti("a"), outcome: .changed, handlerAfter: .preview),
            MemberResult(target: .uti("b"), outcome: .changed, handlerAfter: .preview),
            MemberResult(target: .uti("c"), outcome: .declined, handlerAfter: .photos),
        ]
        let restores = KindStore.restores(for: applied, before: [.uti("a"): .photos, .uti("c"): .photos], app: .preview)

        #expect(restores == [.init(target: .uti("a"), app: .photos)])
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
