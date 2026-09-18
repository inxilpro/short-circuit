import Foundation
import Testing
@testable import Short_Circuit

struct LiveKindProviderTests {
    private func app(_ path: String, _ bundleID: String, _ name: String) -> AppRef {
        AppRef(url: URL(fileURLWithPath: path), bundleID: bundleID, name: name, version: nil)
    }

    @Test func candidatesAreTieredAndUniqueByURL() {
        let textEdit = app("/System/Applications/TextEdit.app", "com.apple.TextEdit", "TextEdit")
        let preview = app("/System/Applications/Preview.app", "com.apple.Preview", "Preview")
        let notes = app("/System/Applications/Notes.app", "com.apple.Notes", "Notes")
        let calculator = app("/System/Applications/Calculator.app", "com.apple.calculator", "Calculator")
        let chess = app("/System/Applications/Chess.app", "com.apple.Chess", "Chess")
        let missing = app("/Applications/Definitely Not Installed.app", "com.example.missing", "Missing")

        let merged = LiveKindProvider.mergeCandidates(
            live: [chess, textEdit, calculator, notes, missing],
            explicit: [preview, notes, textEdit],
            defaults: [textEdit.url]
        )
        #expect(merged.map(\.name) == ["TextEdit", "Notes", "Preview", "Calculator", "Chess"])
    }

    @Test func sameBundleIDAtTwoPathsStaysTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LiveKindProviderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appending(path: "Tool 2025.app")
        let new = directory.appending(path: "Tool 2026.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let merged = LiveKindProvider.mergeCandidates(
            live: [AppRef(url: new, bundleID: "com.example.tool", name: "Tool", version: "2026")],
            explicit: [AppRef(url: old, bundleID: "com.example.tool", name: "Tool", version: "2025"),
                       AppRef(url: new, bundleID: "com.example.tool", name: "Tool", version: "2026")],
            defaults: []
        )
        #expect(merged.count == 2)
        #expect(merged.map(\.version) == ["2025", "2026"])
    }
}

struct MemberCandidateTests {
    /// Real apps, because enrichment drops candidates that don't exist on disk.
    private static let word = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    private static let chromium = URL(fileURLWithPath: "/System/Applications/Preview.app/")
    private static let chrome = URL(fileURLWithPath: "/System/Applications/Notes.app")

    private struct FakeLookup: HandlerLookup {
        var defaults: [String: URL]
        var lists: [String: [URL]]

        func defaultApplicationURL(forContentType identifier: String) -> URL? { defaults[identifier] }
        func applicationURLs(forContentType identifier: String) -> [URL] { lists[identifier] ?? [] }
        func defaultApplicationURL(forScheme scheme: String) -> URL? { defaults["\(scheme):"] }
        func applicationURLs(forScheme scheme: String) -> [URL] { lists["\(scheme):"] ?? [] }
    }

    private func enrich(_ lookup: FakeLookup) -> Kind {
        let kind = Kind(
            id: "mhtml", name: "MIME HTML", category: .documents,
            members: [KindMember(target: .uti("org.ietf.mhtml")), KindMember(target: .uti("com.microsoft.word.mhtml")), KindMember(target: .scheme("mhtml"))],
            extensions: ["mht"], mimeTypes: [], candidates: []
        )
        return LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: lookup).enrich([kind])[0]
    }

    @Test func eachMemberGetsItsOwnList() throws {
        let kind = enrich(FakeLookup(
            defaults: ["org.ietf.mhtml": Self.chrome, "com.microsoft.word.mhtml": Self.word, "mhtml:": Self.chrome],
            lists: [
                "org.ietf.mhtml": [Self.chrome, Self.chromium, Self.word],
                "com.microsoft.word.mhtml": [Self.word, Self.chromium],
                "mhtml:": [Self.chrome],
            ]
        ))
        let chrome = try #require(kind.candidates.first { $0.url.path == Self.chrome.path })
        let word = try #require(kind.candidates.first { $0.url.path == Self.word.path })
        let chromium = try #require(kind.candidates.first { $0.url.path == Self.chromium.path })
        #expect(kind.candidates.count == 3, "The Kind's candidates stay the union")

        let ietf = kind.members[0]
        let wordMHTML = kind.members[1]
        let scheme = kind.members[2]
        #expect(ietf.accepts(chrome) && ietf.accepts(word) && ietf.accepts(chromium))
        #expect(!wordMHTML.accepts(chrome), "Word's MHTML type isn't listed for Chrome, so setting it would fail with 256")
        #expect(wordMHTML.accepts(word) && wordMHTML.accepts(chromium))
        #expect(scheme.accepts(chrome) && !scheme.accepts(word))
    }

    @Test func theCurrentDefaultIsAlwaysAccepted() throws {
        let kind = enrich(FakeLookup(defaults: ["com.microsoft.word.mhtml": Self.word], lists: ["com.microsoft.word.mhtml": [Self.chromium]]))
        let word = try #require(kind.members[1].defaultApp)
        #expect(kind.members[1].accepts(word))
    }

    @Test func urlSpellingsDoNotMatter() throws {
        let kind = enrich(FakeLookup(defaults: [:], lists: ["org.ietf.mhtml": [URL(fileURLWithPath: "/System/Applications/../Applications/Preview.app")]]))
        let preview = try #require(kind.candidates.first)
        #expect(kind.members[0].accepts(preview))
        #expect(preview.url == LiveKindProvider.canonical(URL(fileURLWithPath: "/System/Applications/Preview.app")))
    }
}
