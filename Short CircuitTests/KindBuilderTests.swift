import Foundation
import Testing
@testable import Short_Circuit

struct KindBuilderTests {
    private func kinds(_ fixture: String, builder: KindBuilder = Fixture.offlineBuilder) throws -> [Kind] {
        builder.build(from: try Fixture.snapshot(fixture))
    }

    @Test func markdownBecomesOneKindWithBothUTIsAndMD() throws {
        let kinds = try kinds("markdown.lsdump")
        let markdownKinds = kinds.filter { !Set($0.utis).isDisjoint(with: ["public.markdown", "net.daringfireball.markdown"]) }
        #expect(markdownKinds.count == 1)

        let markdown = try #require(markdownKinds.first)
        #expect(Set(markdown.utis) == ["public.markdown", "net.daringfireball.markdown"])
        #expect(markdown.extensions.contains("md"))
        #expect(markdown.extensions.contains("markdown"))
        #expect(markdown.mimeTypes.contains("text/markdown"))
        #expect(markdown.category == .documents)
        #expect(markdown.name.localizedCaseInsensitiveContains("markdown"))
    }

    @Test func markdownDoesNotAbsorbPlainTextOrCSV() throws {
        let kinds = try kinds("markdown.lsdump")
        let markdown = try #require(kinds.first { $0.utis.contains("public.markdown") })
        #expect(!markdown.utis.contains("public.plain-text"))
        #expect(!markdown.utis.contains("public.comma-separated-values-text"))
        #expect(!markdown.mimeTypes.contains("text/plain"), "MacWhisper's text/plain export is too generic to describe Markdown")

        let plainText = try #require(kinds.first { $0.utis.contains("public.plain-text") })
        #expect(plainText.utis == ["public.plain-text"])
        let csv = try #require(kinds.first { $0.utis.contains("public.comma-separated-values-text") })
        #expect(csv.utis == ["public.comma-separated-values-text"])
    }

    @Test func textPlainIsGenericOnceItsBaseTypeIsBroad() throws {
        let snapshot = try Fixture.snapshot("markdown.lsdump")
        var builder = Fixture.offlineBuilder
        builder.options.baseTypeMinimumDescendants = 3
        #expect(builder.analyze(snapshot).genericTags.contains("text/plain"))

        builder.options.baseTypeMinimumDescendants = 20
        #expect(!builder.analyze(snapshot).genericTags.contains("text/plain"), "The fixture alone doesn't make public.plain-text broad")
    }

    @Test func markdownCandidatesIncludeUTIAndBareExtensionClaimants() throws {
        let markdown = try #require(try kinds("markdown.lsdump").first { $0.utis.contains("public.markdown") })
        let bundleIDs = Set(markdown.candidates.compactMap(\.bundleID))
        #expect(bundleIDs == [
            "org.josephpearson.Mud",
            "com.microsoft.Word",
            "com.todesktop.230313mzl4w4u92",
            "com.sublimetext.4",
            "com.anthropic.claudefordesktop",
        ])
        #expect(markdown.candidates.count == bundleIDs.count, "Candidates are unique by bundle ID")
    }

    @Test func declaringATypeDoesNotMakeAnAppACandidate() throws {
        let markdown = try #require(try kinds("markdown.lsdump").first { $0.utis.contains("public.markdown") })
        let bundleIDs = Set(markdown.candidates.compactMap(\.bundleID))
        #expect(!bundleIDs.contains("com.goodsnooze.MacWhisper"))
        #expect(!bundleIDs.contains("com.apple.Notes"))
    }

    @Test func handlerPrefsSeedDefaultsAndRevealSplits() throws {
        let markdown = try #require(try kinds("markdown.lsdump").first { $0.utis.contains("public.markdown") })
        let daringFireball = try #require(markdown.members.first { $0.target == .uti("net.daringfireball.markdown") })
        #expect(daringFireball.defaultApp?.bundleID == "com.sublimetext.4")
        #expect(markdown.members.first { $0.target == .uti("public.markdown") }?.defaultApp == nil)
        #expect(markdown.isSplit)
    }

    @Test func webPageCombinesBrowserSchemesAndHTML() throws {
        let kinds = try kinds("schemes.lsdump")
        let web = try #require(kinds.first { $0.id == KindBuilder.webPageID })
        #expect(web.name == "Web page")
        #expect(web.category == .web)
        #expect(Set(web.schemes) == ["http", "https"])
        #expect(web.utis.contains("public.html"))
        #expect(web.candidates.contains { $0.bundleID == "com.apple.Safari" })
        #expect(!kinds.contains { $0.id != KindBuilder.webPageID && $0.utis.contains("public.html") })
    }

    @Test func mailtoBecomesEmail() throws {
        let email = try #require(try kinds("schemes.lsdump").first { $0.id == KindBuilder.emailID })
        #expect(email.schemes == ["mailto"])
        #expect(email.category == .communication)
        #expect(email.candidates.map(\.bundleID) == ["com.apple.mail"])
    }

    @Test func otherSchemesBecomeTheirOwnKinds() throws {
        let kinds = try kinds("schemes.lsdump")
        let etcher = try #require(kinds.first { $0.id == "scheme:etcher" })
        #expect(etcher.schemes == ["etcher"])
        #expect(etcher.category == .other)
        #expect(Set(etcher.candidates.compactMap(\.bundleID)) == ["io.balena.etcher"])
    }

    @Test func appOnlySchemesAreNamedAfterTheirAppAndMarkedPrivate() throws {
        let kinds = try kinds("schemes.lsdump")
        let etcher = try #require(kinds.first { $0.id == "scheme:etcher" })
        let app = try #require(etcher.candidates.first)
        #expect(etcher.name == "\(app.name) link (etcher:)")
        #expect(etcher.isAppPrivate, "Only one app registers etcher:, so it is that app's own callback")

        let email = try #require(kinds.first { $0.id == KindBuilder.emailID })
        #expect(!email.isAppPrivate)
        let sip = try #require(kinds.first { $0.id == "scheme:sip" })
        #expect(!sip.isAppPrivate, "Well-known schemes stay public even with one claimant")
    }

    @Test func wellKnownSchemesGetCategories() {
        for scheme in ["mailto", "tel", "facetime", "sms", "slack", "zoommtg", "msteams", "sip"] {
            #expect(KindBuilder.schemeCategory(scheme) == .communication, "\(scheme)")
        }
        for scheme in ["http", "https", "ftp", "feed"] {
            #expect(KindBuilder.schemeCategory(scheme) == .web, "\(scheme)")
        }
        for scheme in ["vscode", "cursor", "xcode", "git", "ssh", "x-github-client"] {
            #expect(KindBuilder.schemeCategory(scheme) == .developer, "\(scheme)")
        }
        #expect(KindBuilder.schemeCategory("etcher") == .other)
    }

    @Test func abstractSchemesAreNotKinds() throws {
        let snapshot = try Fixture.snapshot("schemes.lsdump")
        #expect(snapshot.claims.contains { $0.schemes.contains("file") }, "The fixture has Finder's file: claim")
        #expect(!(try kinds("schemes.lsdump")).contains { $0.schemes.contains("file") })
    }

    @Test func mixedCategoriesAndShapesStaySplit() {
        let separator = String(repeating: "-", count: 80)
        func type(_ id: String, _ unit: String, conforms: String, tags: String) -> String {
            """
            \(separator)
            type id:                    \(id) (\(unit))
            uti:                        \(id)
            flags:                      active  exported  trusted (0000000000000051)
            conforms to:                \(conforms)
            tags:                       \(tags)
            """
        }
        let text = """
        \(separator)
        bundle id:                  Player (0x10)
        path:                       /Applications/Player.app (0x11)
        name:                       Player
        identifier:                 com.example.player
        class:                      kLSBundleClassApplication (0x2)
        \(type("com.example.movie", "0x20", conforms: "public.movie", tags: ".mp9, video/mp9"))
        \(type("com.example.movie-alias", "0x21", conforms: "public.movie", tags: ".mp9"))
        \(type("com.example.audio", "0x22", conforms: "public.audio", tags: ".mp9, audio/mp9"))
        \(type("com.example.bundle-folder", "0x23", conforms: "com.apple.package, public.directory", tags: ".pkgx"))
        \(type("com.example.bundle-file", "0x24", conforms: "public.data", tags: ".pkgx"))
        \(type("com.example.secondary", "0x25", conforms: "public.data", tags: ".mpx, .mp9"))
        \(separator)
        claim id:                   Everything (0x30)
        rank:                       Default
        bundle:                     Player (0x10)
        roles:                      Viewer (0000000000000002)
        bindings:                   com.example.movie, com.example.movie-alias, com.example.audio, com.example.bundle-folder, com.example.bundle-file, com.example.secondary
        """
        let kinds = Fixture.offlineBuilder.build(from: LSDumpParser.parse(text))
        let groups = Set(kinds.map { Set($0.utis) })
        #expect(groups == [
            ["com.example.movie", "com.example.movie-alias"],
            ["com.example.audio"],
            ["com.example.bundle-folder"],
            ["com.example.bundle-file"],
            ["com.example.secondary"],
        ])
    }
}
