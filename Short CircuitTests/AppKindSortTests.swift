import Foundation
import Testing
@testable import Short_Circuit

@MainActor
struct AppKindSortTests {
    private func app(_ name: String) -> AppRef {
        AppRef(url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory), bundleID: "test.\(name)", name: name)
    }

    private func item(_ name: String, candidates: [String], explicit: [String]) throws -> AppKindItem {
        var kind = try #require(SampleKindProvider.kinds.first)
        kind.name = name
        kind.candidates = candidates.map(app)
        kind.explicitCandidateURLs = Set(explicit.map { app($0).url })
        return AppKindItem(kind: kind, relation: .defaultFor, targetsText: "")
    }

    @Test func theAppCountLeavesOutAppsOfferedOnlyThroughBroadConformance() throws {
        let item = try item("Swift source", candidates: ["Xcode", "BBEdit", "Chrome", "TextEdit"], explicit: ["Xcode", "BBEdit"])

        #expect(item.appCount == 2)
    }

    @Test func everyCandidateCountsWhenNothingIsKnownToDeclareTheType() throws {
        let item = try item("Mystery", candidates: ["Xcode", "BBEdit", "Chrome"], explicit: [])

        #expect(item.appCount == 3)
    }

    @Test func sortingByAppCountDescendingPutsTheMostContestedTypeFirst() throws {
        let items = [
            try item("Privacy manifest", candidates: ["Xcode"], explicit: ["Xcode"]),
            try item("Property list", candidates: ["Xcode", "BBEdit", "Zed"], explicit: ["Xcode", "BBEdit", "Zed"]),
            try item("API notes", candidates: ["Xcode", "BBEdit"], explicit: ["Xcode", "BBEdit"]),
        ]

        let sorted = items.sorted(using: AppKindSort.decode("apps:descending"))

        #expect(sorted.map(\.name) == ["Property list", "API notes", "Privacy manifest"])
    }

    @Test func aStoredSortSurvivesARoundTrip() {
        for id in AppKindSort.columnIDs {
            for direction in ["ascending", "descending"] {
                let stored = "\(id):\(direction)"
                #expect(AppKindSort.encode(AppKindSort.decode(stored)) == stored)
            }
        }
        #expect(AppKindSort.decode("nonsense").isEmpty)
        #expect(AppKindSort.encode([]) == "")
    }
}
