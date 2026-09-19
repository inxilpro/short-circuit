import Foundation
import Testing
@testable import Short_Circuit

/// Link types only one app can open are hidden from every list unless the View option is on.
@MainActor
struct AppPrivateKindTests {
    private let privateIDs: Set<Kind.ID> = ["notes-link", "books-link"]

    private func makeStore(defaults: UserDefaults? = nil) async -> KindStore {
        let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview, defaults: defaults)
        await store.refresh()
        return store
    }

    @Test func sampleDataHasAppSpecificLinkTypes() {
        #expect(SampleKindProvider.kinds.filter(\.isAppPrivate).count >= 2)
    }

    @Test func hiddenFromEveryListAndCountByDefault() async {
        let store = await makeStore()
        #expect(!store.showsAppPrivateKinds)

        store.sidebarSelection = .all
        #expect(store.visibleKinds.allSatisfy { !privateIDs.contains($0.id) })
        #expect(store.visibleKinds.count == store.kinds.count - privateIDs.count)
        for category in KindCategory.allCases {
            #expect(store.kinds(in: .category(category)).allSatisfy { !$0.isAppPrivate })
        }
        #expect(store.commonKinds.allSatisfy { !$0.isAppPrivate })
        #expect(store.kinds.filter(\.isAppPrivate).count == privateIDs.count)
    }

    @Test func turningTheOptionOnListsThem() async {
        let store = await makeStore()
        store.sidebarSelection = .all
        store.showsAppPrivateKinds = true

        #expect(Set(store.visibleKinds.map(\.id)).isSuperset(of: privateIDs))
        #expect(store.visibleKinds.count == store.kinds.count)
    }

    @Test func applicationsLeaveThemOutOfSectionsAndCounts() async {
        let store = await makeStore()
        #expect(!store.appIndex.relations(for: AppRef.notes.url).contains { privateIDs.contains($0.kindID) })
        #expect(!store.appIndex.relations(for: AppRef.books.url).contains { privateIDs.contains($0.kindID) })
        let hiddenCount = store.appIndex.summaries.first { $0.app.url == AppRef.books.url }?.explicitCount

        store.showsAppPrivateKinds = true
        #expect(store.appIndex.relations(for: AppRef.books.url).contains { $0.kindID == "books-link" })
        let shownCount = store.appIndex.summaries.first { $0.app.url == AppRef.books.url }?.explicitCount
        #expect(shownCount == (hiddenCount ?? 0) + 1)
    }

    @Test func aSchemeNamedExactlyIsFoundWhileHidden() async {
        let store = await makeStore()
        store.sidebarSelection = .all
        store.searchText = "applenotes:"

        #expect(store.visibleKinds.map(\.id) == ["notes-link"])
        #expect(store.hiddenAppPrivateMatches == 0)
    }

    @Test func otherSearchesOfferToShowWhatTheyMatched() async {
        let store = await makeStore()
        store.sidebarSelection = .all

        store.searchText = "applenotes"
        #expect(store.visibleKinds.isEmpty)
        #expect(store.hiddenAppPrivateMatches == 1)

        store.searchText = "link ("
        #expect(store.hiddenAppPrivateMatches == 2)

        store.searchText = "itms-bo:"
        #expect(store.visibleKinds.isEmpty)
        #expect(store.hiddenAppPrivateMatches == 1)
    }

    @Test func theEmptyStateButtonShowsThemWhereTheyAppear() async {
        let store = await makeStore()
        store.sidebarSelection = .common
        store.searchText = "applenotes"
        #expect(store.hiddenAppPrivateMatches == 1)

        store.showAppPrivateMatches()

        #expect(store.showsAppPrivateKinds)
        #expect(store.sidebarSelection == .all)
        #expect(store.visibleKinds.map(\.id) == ["notes-link"])
    }

    @Test func anExactSchemeOutsideTheSectionPointsToAllTypes() async {
        let store = await makeStore()
        store.sidebarSelection = .common
        store.searchText = "itms-books:"

        #expect(store.visibleKinds.isEmpty)
        #expect(store.hiddenMatchesInAllTypes == 1)
    }

    @Test func hidingThemClearsASelectionThatWasOne() async {
        let store = await makeStore()
        store.sidebarSelection = .all
        store.showsAppPrivateKinds = true
        store.selectedKindID = "books-link"
        #expect(store.selectedKind?.id == "books-link")

        store.showsAppPrivateKinds = false

        #expect(store.selectedKindID == nil)
        #expect(store.selectedKind == nil)
    }

    @Test func theChoiceIsRememberedAndOffByDefault() async {
        let suite = "short-circuit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = await makeStore(defaults: defaults)
        #expect(!first.showsAppPrivateKinds)
        first.showsAppPrivateKinds = true

        let second = await makeStore(defaults: defaults)
        #expect(second.showsAppPrivateKinds)
    }

    @Test func exactSchemeParsing() {
        #expect(KindSearch("slack:").exactScheme == "slack")
        #expect(KindSearch("  Slack: ").exactScheme == "slack")
        #expect(KindSearch("slack").exactScheme == nil)
        #expect(KindSearch("slack:foo").exactScheme == nil)
        #expect(KindSearch(":").exactScheme == nil)
    }
}
