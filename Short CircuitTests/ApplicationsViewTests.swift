import Foundation
import Testing
@testable import Short_Circuit

// Drives SimulatedHandlerBackend only; nothing here may construct WorkspaceHandlerBackend.

/// Serves the sample Kinds with handlers read from the simulated system.
private struct BackedSampleProvider: KindProviding {
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
struct ApplicationsViewTests {
    private func makeStore(latency: Duration = .zero) async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, latency: latency)
        let store = KindStore(provider: BackedSampleProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func kindsAreSortedIntoSectionsFromTheAppsPointOfView() async {
        let (store, _) = await makeStore()
        let preview = AppRef.preview.url

        #expect(Set(store.kindIDs(for: preview, relation: .defaultFor)).isSuperset(of: ["jpeg", "png", "pdf"]))
        #expect(store.kindIDs(for: preview, relation: .partlyDefault) == ["heic"])
        #expect(store.kindIDs(for: AppRef.photos.url, relation: .canOpen).contains("jpeg"))
    }

    @Test func explicitDeclarationsSeparateCanOpenFromOffered() {
        let index = AppIndex(kinds: SampleKindProvider.kinds) { kind in
            kind.id == "jpeg" ? [AppRef.photos.url] : []
        }
        let photos = Dictionary(index.relations(for: AppRef.photos.url).map { ($0.kindID, $0.relation) }, uniquingKeysWith: { first, _ in first })

        #expect(photos["jpeg"] == .canOpen)
        #expect(photos["png"] == .offered)
        #expect(photos["heic"] == .partlyDefault)
    }

    @Test func unknownExplicitDataCountsEveryCandidateAsAbleToOpen() {
        let index = AppIndex(kinds: SampleKindProvider.kinds) { _ in [] }

        #expect(!index.relations(for: AppRef.photos.url).contains { $0.relation == .offered })
    }

    @Test func appSummariesCountDefaultsAndOpenableKinds() async throws {
        let (store, _) = await makeStore()
        let photos = try #require(store.appIndex.summaries.first { $0.app.url == AppRef.photos.url })

        #expect(photos.defaultCount == 0)
        #expect(photos.explicitCount == store.appIndex.relations(for: AppRef.photos.url).count)
    }

    @Test func selectingAnAppPreChecksOnlyPartlyDefaultKinds() async {
        let (store, _) = await makeStore()

        store.selectApp(AppRef.photos.url)

        #expect(store.batchSelection == ["heic"])
    }

    @Test func promptCountIncludesOnlyMembersThatWillChange() async throws {
        let (store, _) = await makeStore()
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "png", "heic"]

        let plan = try #require(store.batchPlan)

        #expect(plan.promptCount == 3)
        #expect(plan.items.first { $0.id == "heic" }?.changing.map(\.target) == [.uti("public.heic")])
    }

    @Test func webPageCountsTheBrowserOnceAndXHTMLSeparately() async throws {
        let (store, _) = await makeStore()
        let web = try kind("web-page", in: store)

        #expect(AppBatchPlan(app: .textEdit, kinds: [web]).promptCount == 1)
        #expect(AppBatchPlan(app: .notes, kinds: [web]).promptCount == 2)
    }

    @Test func membersThatDontListTheAppAreShownAsSkipped() async throws {
        let (store, _) = await makeStore()
        let plan = AppBatchPlan(app: .mail, kinds: [try kind("calendar-event", in: store)])

        #expect(plan.items.first?.unsupported.map(\.target) == [.scheme("webcal")])
        #expect(plan.promptCount == 1)
    }

    @Test func applyRunsEachKindAndRecordsResultsFromLiveReads() async throws {
        let (store, backend) = await makeStore()
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "heic"]

        await store.applyBatch()

        #expect(backend.calls.map(\.target) == [.uti("public.jpeg"), .uti("public.heic")])
        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
        #expect(store.results["jpeg"]?.map(\.outcome) == [.changed])
        #expect(Set(store.results["heic"]?.map(\.outcome) ?? []) == [.changed, .skipped(.alreadyDefault)])
        #expect(store.batchRun?.finishedKindIDs == ["jpeg", "heic"])
        #expect(store.batchRun?.isRunning == false)
    }

    @Test func batchChangesFeedTheSplitList() async throws {
        let (store, _) = await makeStore()
        #expect(try kind("heic", in: store).isSplit)
        store.selectApp(AppRef.photos.url)

        await store.applyBatch()

        #expect(store.resolvedSplitIDs.contains("heic"))
        #expect(store.splitKinds.contains { $0.id == "heic" })
    }

    @Test func stopEndsTheBatchAfterTheCurrentPromptAndLeavesTheRestUntouched() async throws {
        let (store, backend) = await makeStore(latency: .milliseconds(150))
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg", "png", "quicktime-movie"]

        let run = Task { await store.applyBatch() }
        await waitFor { store.batchRun?.changesStarted == 1 }
        store.stopBatch()
        await run.value

        #expect(backend.calls.map(\.target) == [.uti("public.jpeg")])
        #expect(store.batchRun?.finishedKindIDs == ["jpeg"])
        #expect(store.batchRun?.notStartedKindIDs == ["png", "quicktime-movie"])
        #expect(try kind("png", in: store).defaultApp?.url == AppRef.preview.url)
    }

    @Test func aBatchHoldsTheAppWideWriteGate() async throws {
        let (store, backend) = await makeStore(latency: .milliseconds(150))
        store.selectApp(AppRef.photos.url)
        store.batchSelection = ["jpeg"]

        let run = Task { await store.applyBatch() }
        await waitFor { !backend.calls.isEmpty }
        #expect(!store.canWrite)
        await store.setDefault(.photos, for: try kind("png", in: store))
        await store.refresh()
        #expect(!store.isRefreshing)
        await run.value

        #expect(backend.calls.map(\.target) == [.uti("public.jpeg")])
    }

    @Test func showKindLeavesTheApplicationsView() async {
        let (store, _) = await makeStore()
        store.sidebarSelection = .applications
        store.searchText = "photos"

        store.showKind("jpeg")

        #expect(store.sidebarSelection == .common)
        #expect(store.selectedKindID == "jpeg")
        #expect(store.searchText.isEmpty)
    }
}
