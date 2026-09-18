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
    static let word = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
    static let chromium = URL(fileURLWithPath: "/System/Applications/Preview.app/")
    static let chrome = URL(fileURLWithPath: "/System/Applications/Notes.app")

    struct FakeLookup: HandlerLookup {
        var defaults: [String: URL]
        var lists: [String: [URL]]
        var resolutions: [String: Set<String>] = [:]
        var declared: [String: [String]] = [:]

        func defaultApplicationURL(forContentType identifier: String) -> URL? { defaults[identifier] }
        func applicationURLs(forContentType identifier: String) -> [URL] { lists[identifier] ?? [] }
        func defaultApplicationURL(forScheme scheme: String) -> URL? { defaults["\(scheme):"] }
        func applicationURLs(forScheme scheme: String) -> [URL] { lists["\(scheme):"] ?? [] }
        func contentTypes(forFilenameExtension ext: String) -> Set<String> { resolutions[ext] ?? [] }
        func declaredExtensions(forContentType identifier: String) -> [String] { declared[identifier] ?? [] }
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

struct GovernedExtensionTests {
    typealias Lookup = MemberCandidateTests.FakeLookup
    private let music = MemberCandidateTests.word
    private let fission = MemberCandidateTests.chromium

    private func wav(_ lookup: Lookup) -> Kind {
        let kind = Kind(
            id: "wav", name: "WAV audio", category: .audio,
            members: [KindMember(target: .uti("public.wav")), KindMember(target: .uti("com.microsoft.waveform-audio"))],
            extensions: ["wav", "wave", "bwf"], mimeTypes: [], candidates: []
        )
        return LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: lookup).enrich([kind])[0]
    }

    private func lookup(resolutions: [String: Set<String>]) -> Lookup {
        Lookup(
            defaults: ["public.wav": fission, "com.microsoft.waveform-audio": music],
            lists: ["public.wav": [fission, music], "com.microsoft.waveform-audio": [fission, music]],
            resolutions: resolutions,
            declared: ["public.wav": ["wav", "wave"], "com.microsoft.waveform-audio": ["wav"]]
        )
    }

    @Test func shadowedMembersDoNotMakeAKindSplit() {
        let kind = wav(lookup(resolutions: ["wav": ["com.microsoft.waveform-audio"], "wave": ["com.microsoft.waveform-audio"]]))
        #expect(kind.members[0].governedExtensions == [])
        #expect(!kind.members[0].isEffective)
        #expect(kind.members[1].governedExtensions == ["wav", "wave"])
        #expect(!kind.hasMixedHandlers)
        #expect(!kind.isSplit)
        #expect(kind.defaultApp?.url == LiveKindProvider.canonical(music))
    }

    @Test func winningOneOddExtensionStillCounts() {
        let kind = wav(lookup(resolutions: ["wav": ["com.microsoft.waveform-audio"], "wave": ["public.wav"]]))
        #expect(kind.members[0].governedExtensions == ["wave"])
        #expect(kind.members[0].isEffective)
        #expect(kind.isSplit)
    }

    @Test func knownShadowedMembersLeaveNothingForWholeKindChanges() {
        let kind = wav(lookup(resolutions: ["wav": ["com.example.other"], "wave": ["com.example.other"]]))
        #expect(kind.members.allSatisfy { $0.governedExtensions == [] })
        #expect(kind.effectiveMembers.isEmpty, "Known-shadowed is not the same as unknown")
        #expect(kind.unifyingCandidates.isEmpty)
        #expect(!kind.isSplit)
        #expect(kind.defaultApp != nil, "Display still shows what the settable members open with")
    }

    @Test func unknownGovernanceStaysEffective() {
        var kind = wav(lookup(resolutions: ["wav": ["com.example.other"], "wave": ["com.example.other"]]))
        for index in kind.members.indices { kind.members[index].governedExtensions = nil }
        #expect(kind.effectiveMembers.count == 2)
    }

    @Test func typesWithNoExtensionsAreNotMistakenForShadowed() {
        let kind = Kind(
            id: "utf8", name: "UTF-8 text", category: .documents, members: [KindMember(target: .uti("public.utf8-plain-text"))],
            extensions: [], mimeTypes: [], candidates: []
        )
        let enriched = LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: lookup(resolutions: [:])).enrich([kind])[0]
        #expect(enriched.members[0].governedExtensions == nil)
        #expect(enriched.effectiveMembers.count == 1)
    }

    @Test func extensionsResolvingOutsideTheKindAreRecorded() {
        let kind = wav(lookup(resolutions: ["wav": ["com.microsoft.waveform-audio"], "wave": ["com.example.elsewhere"], "bwf": []]))
        #expect(kind.unclaimedExtensions == ["wave", "bwf"], "Another Kind's type, or only a dyn. type")
    }

    @Test func packageAndFlatWinnersBothGovern() {
        let kind = Kind(
            id: "pages", name: "Pages", category: .documents,
            members: [KindMember(target: .uti("com.apple.iwork.pages.pages")), KindMember(target: .uti("com.apple.iwork.pages.sffpages"))],
            extensions: ["pages"], mimeTypes: [], candidates: []
        )
        let lookup = Lookup(defaults: [:], lists: [:], resolutions: ["pages": ["com.apple.iwork.pages.pages", "com.apple.iwork.pages.sffpages"]])
        let enriched = LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: lookup).enrich([kind])[0]
        #expect(enriched.members.allSatisfy { $0.governedExtensions == ["pages"] })
        #expect(enriched.unclaimedExtensions.isEmpty)
    }

    @Test func schemesHaveNoGovernedExtensions() {
        let kind = Kind(id: "s", name: "S", category: .other, members: [KindMember(target: .scheme("mhtml"))], extensions: [], mimeTypes: [], candidates: [])
        let enriched = LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: lookup(resolutions: [:])).enrich([kind])[0]
        #expect(enriched.members[0].governedExtensions == nil)
        #expect(enriched.members[0].isEffective)
    }
}

struct LiveResolutionTests {
    @Test func resolvesFlatFilesAndPackagesSeparately() {
        let lookup = HandlerService()
        #expect(lookup.contentTypes(forFilenameExtension: "rtfd") == ["com.apple.rtfd"], "Packages only resolve through com.apple.package")
        #expect(lookup.contentTypes(forFilenameExtension: "txt") == ["public.plain-text"])
        #expect(lookup.contentTypes(forFilenameExtension: "no-such-extension-anywhere").isEmpty, "dyn. results are dropped")
    }
}

struct ExplicitCandidateTests {
    @Test func builderMarksUTIAndBareExtensionClaimantsExplicit() throws {
        let markdown = try #require(Fixture.offlineBuilder.build(from: try Fixture.snapshot("markdown.lsdump")).first { $0.utis.contains("public.markdown") })
        let explicitIDs = Set(markdown.candidates.filter { markdown.explicitCandidateURLs.contains($0.url) }.compactMap(\.bundleID))
        #expect(explicitIDs.contains("org.josephpearson.Mud"), "Claims the Markdown UTIs")
        #expect(explicitIDs.contains("com.todesktop.230313mzl4w4u92"), "Cursor only claims the bare .md extension")
        #expect(markdown.explicitCandidateURLs.count == markdown.candidates.count)
    }

    @Test func conformanceOnlyAppsAreNotExplicit() throws {
        let claimant = AppRef(url: MemberCandidateTests.word, bundleID: "com.apple.TextEdit", name: "TextEdit", version: nil)
        let kind = Kind(
            id: "k", name: "K", category: .documents, members: [KindMember(target: .uti("com.example.k"))],
            extensions: [], mimeTypes: [], candidates: [claimant]
        )
        let lookup = MemberCandidateTests.FakeLookup(defaults: [:], lists: ["com.example.k": [MemberCandidateTests.chrome, MemberCandidateTests.word]])
        let enriched = LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: lookup).enrich([kind])[0]

        #expect(enriched.candidates.count == 2)
        #expect(enriched.explicitCandidateURLs == [LiveKindProvider.canonical(MemberCandidateTests.word)])
        let offered = try #require(enriched.candidates.first { $0.url == LiveKindProvider.canonical(MemberCandidateTests.chrome) })
        #expect(!enriched.explicitCandidateURLs.contains(offered.url))
        #expect(enriched.candidates.allSatisfy { enriched.candidates.map(\.url).contains($0.url) })
    }

    @Test func explicitURLsMatchCandidateSpelling() throws {
        let spelled = AppRef(url: URL(fileURLWithPath: "/System/Applications/../Applications/TextEdit.app"), bundleID: nil, name: "TextEdit", version: nil)
        let kind = Kind(id: "k", name: "K", category: .documents, members: [KindMember(target: .uti("com.example.k"))], extensions: [], mimeTypes: [], candidates: [spelled])
        let enriched = LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil), handlers: MemberCandidateTests.FakeLookup(defaults: [:], lists: [:])).enrich([kind])[0]
        let candidate = try #require(enriched.candidates.first)
        #expect(enriched.explicitCandidateURLs == [candidate.url])
    }

    @Test func systemAppsAreRecognizedByLocation() {
        #expect(AppRef(url: URL(fileURLWithPath: "/System/Applications/TextEdit.app"), bundleID: nil, name: "TextEdit", version: nil).isSystemApp)
        #expect(AppRef(url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"), bundleID: nil, name: "Finder", version: nil).isSystemApp)
        #expect(!AppRef(url: URL(fileURLWithPath: "/Applications/Safari.app"), bundleID: nil, name: "Safari", version: nil).isSystemApp)
    }
}
