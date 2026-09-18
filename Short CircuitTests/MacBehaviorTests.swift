import Foundation
import Testing
@testable import Short_Circuit

@MainActor
struct GridNavigatorTests {
    // Two sections, three columns:
    //   a b c      (section 1)
    //   d e
    //   x y z      (section 2)
    //   w
    private let navigator = GridNavigator(sections: [["a", "b", "c", "d", "e"], ["x", "y", "z", "w"]], columns: 3)

    @Test func leftAndRightWalkReadingOrderAcrossRowsAndSections() {
        #expect(navigator.target(from: "c", .right) == "d")
        #expect(navigator.target(from: "e", .right) == "x")
        #expect(navigator.target(from: "x", .left) == "e")
        #expect(navigator.target(from: "a", .left) == "a")
        #expect(navigator.target(from: "w", .right) == "w")
    }

    @Test func upAndDownKeepTheColumn() {
        #expect(navigator.target(from: "b", .down) == "e")
        #expect(navigator.target(from: "e", .up) == "b")
        #expect(navigator.target(from: "y", .down) == "w")
    }

    @Test func verticalMovesCrossSectionsAndClampToShortRows() {
        #expect(navigator.target(from: "e", .down) == "y")
        #expect(navigator.target(from: "c", .down) == "e")
        #expect(navigator.target(from: "z", .up) == "e")
        #expect(navigator.target(from: "x", .up) == "d")
        #expect(navigator.target(from: "a", .up) == "a")
        #expect(navigator.target(from: "w", .down) == "w")
    }

    @Test func homeEndAndNoSelection() {
        #expect(navigator.target(from: "y", .first) == "a")
        #expect(navigator.target(from: "a", .last) == "w")
        #expect(navigator.target(from: nil, .down) == "a")
        #expect(navigator.target(from: nil, .last) == "w")
        #expect(navigator.target(from: "missing", .right) == "a")
        #expect(GridNavigator<String>(sections: [[], []], columns: 4).target(from: nil, .right) == nil)
    }
}

@MainActor
struct TypeSelectTests {
    private let names = ["JPEG image", "Markdown", "MP3 audio", "PDF document", "Plain text"]

    @Test func keystrokesInQuickSuccessionBuildOnePrefix() {
        var buffer = TypeSelectBuffer()
        let start = Date()
        #expect(buffer.append("p", at: start) == "p")
        #expect(buffer.append("l", at: start.addingTimeInterval(0.3)) == "pl")
        #expect(buffer.append("m", at: start.addingTimeInterval(2)) == "m")
    }

    @Test func matchesAPrefixCaseInsensitivelyElseTheNextNameAfterIt() {
        #expect(TypeSelectBuffer.match("pl", in: names) { $0 } == "Plain text")
        #expect(TypeSelectBuffer.match("MP", in: names) { $0 } == "MP3 audio")
        #expect(TypeSelectBuffer.match("n", in: names) { $0 } == "PDF document")
        #expect(TypeSelectBuffer.match("zz", in: names) { $0 } == nil)
    }
}

@MainActor
struct RememberedStateTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "short-circuit-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func viewChoicesSurviveANewStore() {
        let defaults = makeDefaults()
        let first = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview, defaults: defaults)
        first.layout = .list
        first.sidebarSelection = .category(.images)
        first.isInspectorPresented = false
        first.showsShadowedMembers = true

        let second = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview, defaults: defaults)
        #expect(second.layout == .list)
        #expect(second.sidebarSelection == .category(.images))
        #expect(!second.isInspectorPresented)
        #expect(second.showsShadowedMembers)
    }

    @Test func withoutDefaultsNothingIsRememberedOrRead() {
        let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview)
        store.layout = .list
        #expect(KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview).layout == .grid)
    }

    @Test func aRememberedCategoryWithNoTypesFallsBackToCommon() async {
        let defaults = makeDefaults()
        defaults.set(SidebarItem.category(.developer).storageKey, forKey: PreferenceKey.sidebar)
        let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview, defaults: defaults)
        #expect(store.sidebarSelection == .category(.developer))

        await store.refresh()

        #expect(!store.categoriesWithKinds.contains(.developer))
        #expect(store.sidebarSelection == .common)
    }

    @Test func everySidebarItemRoundTrips() {
        let items: [SidebarItem] = [.split, .common, .all, .applications] + KindCategory.allCases.map { .category($0) }
        for item in items {
            #expect(SidebarItem(storageKey: item.storageKey) == item)
        }
        #expect(SidebarItem(storageKey: "category.nonsense") == nil)
    }
}

@MainActor
struct PasteboardRepresentationTests {
    @Test func textNamesTheTypeAndItsIdentifiers() throws {
        let web = try #require(SampleKindProvider.kinds.first { $0.id == "web-page" })
        #expect(web.pasteboardText == "Web page (http:, https:, public.html, public.xhtml)")
        #expect(web.identifierList == ["http:", "https:", "public.html", "public.xhtml"])
    }

    @Test func jsonCarriesTheDefaultAppPerIdentifier() throws {
        let markdown = try #require(SampleKindProvider.kinds.first { $0.id == "markdown" })
        let export = KindExport(markdown)
        #expect(export.name == "Markdown")
        #expect(export.identifiers == markdown.identifierList)
        #expect(export.defaultApps.count == markdown.members.compactMap(\.defaultApp).count)
    }
}

@MainActor
struct OtherAppAndDropTests {
    @Test func otherAppChoiceIsRefusedWhileWriting() async throws {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, latency: .milliseconds(200))
        let store = KindStore(provider: SampleKindProvider(), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        let jpeg = try #require(store.kinds.first { $0.id == "jpeg" })
        let running = Task { await store.setDefault(.photos, for: jpeg) }
        for _ in 0..<200 where !store.isWriting { try? await Task.sleep(for: .milliseconds(5)) }

        store.requestOtherApp(for: .kind("png"))
        #expect(store.pendingAppChoice == nil)
        await running.value

        store.requestOtherApp(for: .member("png", .uti("public.png")))
        #expect(store.pendingAppChoice == .member("png", .uti("public.png")))
        store.cancelAppChoice()
        #expect(store.pendingAppChoice == nil)
    }

    @Test func anAppDroppedOnTheWindowExplainsWhereToDropIt() async {
        let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview)
        await store.refresh()
        store.handleDrop(of: URL(filePath: "/System/Applications/TextEdit.app", directoryHint: .isDirectory))

        #expect(store.message?.text.contains("Opens With") == true)
        #expect(store.selectedKindID == nil)
    }

    @Test func failuresStayUntilDismissedAndInformationFades() async {
        let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview)
        store.showMessage("Refresh failed", isFailure: true)
        #expect(store.message?.isFailure == true)
        store.dismissMessage()
        #expect(store.message == nil)
    }
}
