import Foundation
import Testing
@testable import Short_Circuit

@MainActor
struct AppSortOrderTests {
    private func summary(_ name: String, defaults: Int) -> AppSummary {
        let app = AppRef(url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory), bundleID: "test.\(name)", name: name)
        return AppSummary(app: app, label: name, defaultCount: defaults, explicitCount: defaults, offeredCount: 0)
    }

    @Test func nameOrderIgnoresCounts() {
        let sorted = [summary("Zed", defaults: 9), summary("BBEdit", defaults: 1), summary("app10", defaults: 0), summary("app9", defaults: 0)]
            .sorted(by: .name)

        #expect(sorted.map(\.label) == ["app9", "app10", "BBEdit", "Zed"])
    }

    @Test func defaultCountOrderPutsTheBusiestAppFirstAndBreaksTiesByName() {
        let sorted = [summary("Preview", defaults: 3), summary("Zed", defaults: 12), summary("BBEdit", defaults: 3), summary("Chess", defaults: 0)]
            .sorted(by: .defaultCount)

        #expect(sorted.map(\.label) == ["Zed", "BBEdit", "Preview", "Chess"])
    }

    @Test func theSortOrderIsRememberedBetweenLaunches() async throws {
        let suite = "AppSortOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview, defaults: defaults)
        #expect(first.appSortOrder == .name)
        first.appSortOrder = .defaultCount

        let second = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview, defaults: defaults)
        #expect(second.appSortOrder == .defaultCount)
    }
}
