import Foundation
import Observation
import Testing
@testable import Short_Circuit

// Drives SimulatedHandlerBackend only.

private struct BackedProvider: KindProviding {
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// The Applications list and detail read `KindStore.appIndex`, a cache Observation can't see.
/// These check the counts follow every kind of change, and that a view reading the index from
/// the cache is still told to re-render.
@MainActor
struct AppIndexUpdateTests {
    private func makeStore(latency: Duration = .zero) async -> (KindStore, SimulatedHandlerBackend, UndoManager) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, latency: latency)
        let store = KindStore(provider: BackedProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false
        store.undoManager = undoManager
        await store.refresh()
        return (store, backend, undoManager)
    }

    private func defaultCount(_ app: AppRef, in store: KindStore) -> Int {
        store.appIndex.summaries.first { $0.app.url == app.url }?.defaultCount ?? 0
    }

    private func defaultFor(_ app: AppRef, in store: KindStore) -> Set<Kind.ID> {
        Set(store.kinds(for: app.url, relation: .defaultFor).map(\.id))
    }

    @Test func aReadFromTheCacheIsStillToldAboutChanges() async throws {
        let (store, _, _) = await makeStore()
        _ = store.appIndex
        let changed = Flag()
        withObservationTracking {
            _ = store.appIndex
        } onChange: {
            changed.set()
        }

        await store.setDefault(.photos, for: try #require(store.kinds.first { $0.id == "png" }))

        #expect(changed.isSet)
    }

    @Test func oneChangeMovesTheTypeBetweenSections() async throws {
        let (store, _, _) = await makeStore()
        let photosBefore = defaultCount(.photos, in: store)
        let previewBefore = defaultCount(.preview, in: store)
        #expect(store.kindIDs(for: AppRef.photos.url, relation: .canOpen).contains("png"))

        await store.setDefault(.photos, for: try #require(store.kinds.first { $0.id == "png" }))

        #expect(defaultCount(.photos, in: store) == photosBefore + 1)
        #expect(defaultCount(.preview, in: store) == previewBefore - 1)
        #expect(defaultFor(.photos, in: store).contains("png"))
        #expect(!store.kindIDs(for: AppRef.photos.url, relation: .canOpen).contains("png"))
    }

    @Test func aBatchUpdatesCountsAndKeepsItsStatus() async {
        let (store, _, _) = await makeStore()
        let before = defaultCount(.photos, in: store)
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "png"]
        await store.applyBatch()

        #expect(defaultCount(.photos, in: store) == before + 2)
        #expect(defaultFor(.photos, in: store).isSuperset(of: ["jpeg", "png"]))
        #expect(store.batchRun?.finishedKindIDs == ["jpeg", "png"])
        #expect(store.results["png"]?.first?.outcome == .changed)
    }

    @Test func stoppingMidBatchCountsOnlyWhatChanged() async {
        let (store, _, _) = await makeStore(latency: .milliseconds(100))
        let before = defaultCount(.photos, in: store)
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "png"]
        let run = Task { await store.applyBatch() }
        for _ in 0..<200 where (store.batchRun?.changesStarted ?? 0) < 1 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        store.stopBatch()
        await run.value

        #expect(defaultCount(.photos, in: store) == before + 1)
        #expect(store.batchRun?.notStartedKindIDs.count == 1)
    }

    @Test func undoPutsTheCountsBack() async {
        let (store, _, undoManager) = await makeStore()
        let before = defaultCount(.photos, in: store)
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "png"]
        await store.applyBatch()
        #expect(defaultCount(.photos, in: store) == before + 2)

        undoManager.undo()
        await store.undoTask?.value

        #expect(defaultCount(.photos, in: store) == before)
        #expect(!defaultFor(.photos, in: store).contains("png"))
    }
}
