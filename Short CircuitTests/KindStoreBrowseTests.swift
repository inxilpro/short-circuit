import Foundation
import Testing
@testable import Short_Circuit

@MainActor
struct KindStoreBrowseTests {
    private func loadedStore(_ kinds: [Kind] = SampleKindProvider.kinds) async -> KindStore {
        let store = KindStore(provider: FixedKindProvider(kinds: kinds), writer: SimulatedHandlerWriter.preview)
        await store.refresh()
        return store
    }

    private func kind(
        _ id: String, _ category: KindCategory = .documents, rank: Int? = nil, catalogued: Bool = false,
        candidates: [AppRef] = [.textEdit, .preview], keywords: [String] = []
    ) -> Kind {
        Kind(
            id: id, name: id, category: category,
            members: [KindMember(target: .uti("test.\(id)"), defaultApp: candidates.first)],
            extensions: [], mimeTypes: [], candidates: candidates,
            commonRank: rank, keywords: keywords, catalogID: catalogued || rank != nil ? id : nil
        )
    }

    @Test func commonIsTheRankedCatalogListRegardlessOfCandidates() async {
        let store = await loadedStore([
            kind("Zeta", rank: 2),
            kind("Alpha", rank: 3),
            kind("Solo", rank: 1, candidates: [.textEdit]),
            kind("Heuristic"),
        ])

        #expect(store.sidebarSelection == .common)
        #expect(store.commonKinds.map(\.id) == ["Solo", "Zeta", "Alpha"])
        #expect(store.visibleKinds.map(\.id) == ["Solo", "Zeta", "Alpha"])
    }

    @Test func categoriesPutCatalogKindsFirstAndKeepTheCandidateFilter() async {
        let store = await loadedStore([
            kind("Aardvark format"),
            kind("PDF", rank: 5),
            kind("Catalogued unranked", catalogued: true),
            kind("Word", rank: 2),
            kind("Lonely", rank: 1, candidates: [.textEdit]),
        ])

        store.sidebarSelection = .category(.documents)

        #expect(store.visibleKinds.map(\.id) == ["Word", "PDF", "Catalogued unranked", "Aardvark format"])
    }

    @Test func allTypesStaysAlphabetical() async {
        let store = await loadedStore([kind("b", rank: 1), kind("c"), kind("a", rank: 2)])

        store.sidebarSelection = .all

        #expect(store.visibleKinds.map(\.id) == ["a", "b", "c"])
    }

    @Test func searchMatchesCatalogKeywords() async {
        let store = await loadedStore()
        store.sidebarSelection = .all

        store.searchText = "photo"
        #expect(Set(store.visibleKinds.map(\.id)) == ["jpeg", "heic"])

        store.searchText = "readme"
        #expect(store.visibleKinds.map(\.id) == ["markdown"])

        store.searchText = "jpg"
        #expect(store.visibleKinds.map(\.id) == ["jpeg"])
    }

    @Test func sampleDataHasARankedCommonList() async {
        let store = await loadedStore()

        #expect(store.commonKinds.first?.id == "web-page")
        #expect(store.commonKinds.map(\.commonRank) == store.commonKinds.map(\.commonRank).sorted { ($0 ?? .max) < ($1 ?? .max) })
    }
}

private struct FixedKindProvider: KindProviding {
    let kinds: [Kind]

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] { kinds }
}

@MainActor
struct KindIconTypeTests {
    private func kind(_ members: [KindMember], extensions: [String]) -> Kind {
        Kind(id: "k", name: "K", category: .images, members: members, extensions: extensions, mimeTypes: [], candidates: [])
    }

    @Test func theExtensionsResolvedTypeWinsWhenItIsASettableMember() {
        let icon = kind([KindMember(target: .uti("public.png")), KindMember(target: .uti("public.jpeg"))], extensions: ["jpg"])

        #expect(icon.iconTypeIdentifier == "public.jpeg")
    }

    @Test func anUnsettableMemberNeverSuppliesTheIcon() {
        let icon = kind(
            [KindMember(target: .uti("public.jpeg"), isSettable: false), KindMember(target: .uti("public.png"))],
            extensions: ["jpg"]
        )

        #expect(icon.iconTypeIdentifier == "public.png")
    }

    @Test func withoutAMatchingExtensionTheFirstSettableUTIIsUsed() {
        let icon = kind(
            [KindMember(target: .scheme("http")), KindMember(target: .uti("public.tiff"), isSettable: false), KindMember(target: .uti("public.png"))],
            extensions: ["zzz-unknown"]
        )

        #expect(icon.iconTypeIdentifier == "public.png")
    }

    @Test func schemeOnlyOrFullyUnsettableKindsHaveNoTypeIcon() {
        #expect(kind([KindMember(target: .scheme("mailto"))], extensions: []).iconTypeIdentifier == nil)
        #expect(kind([KindMember(target: .uti("public.png"), isSettable: false)], extensions: ["png"]).iconTypeIdentifier == nil)
    }
}
