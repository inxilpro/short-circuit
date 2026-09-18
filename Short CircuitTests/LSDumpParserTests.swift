import Foundation
import Testing
@testable import Short_Circuit

struct LSDumpParserTests {
    @Test func readsHeader() throws {
        let snapshot = try Fixture.snapshot("markdown.lsdump")
        #expect(snapshot.systemVersion == "26.6.2 (25G83)")
        #expect(snapshot.cacheSequenceNumber == 21148)
    }

    @Test func parsesBundlesWithoutLeakingNestedPlistLines() throws {
        let snapshot = try Fixture.snapshot("markdown.lsdump")
        #expect(snapshot.bundles.count == 8)

        let mud = try #require(snapshot.bundles.first { $0.unitID == "0x2b40" })
        #expect(mud.name == "Mud")
        #expect(mud.identifier == "org.josephpearson.Mud")
        #expect(mud.path == "/Applications/Mud.app")
        #expect(mud.displayName == "Mud")
        #expect(mud.version == "4.2.0")
        #expect(mud.isApplication)
    }

    @Test func parsesTypeDeclarationsPerRecord() throws {
        let snapshot = try Fixture.snapshot("markdown.lsdump")
        let markdown = snapshot.types.filter { $0.identifier == "net.daringfireball.markdown" }
        #expect(Set(markdown.compactMap(\.unitID)) == ["0x6f0c", "0x4894", "0x4cac"])

        let mud = try #require(markdown.first { $0.unitID == "0x6f0c" })
        #expect(!mud.isActive, "'inactive' must not count as active")
        #expect(mud.bundleUnitID == "0x2b40")
        #expect(mud.extensions == ["md", "markdown", "mkd"])
        #expect(mud.conformsTo == ["public.plain-text"])
        #expect(mud.localizedDescription == "Markdown Document")

        let macWhisper = try #require(markdown.first { $0.unitID == "0x4cac" })
        #expect(macWhisper.isActive)
        #expect(macWhisper.mimeTypes == ["text/plain"])

        let utf8 = try #require(snapshot.types.first { $0.identifier == "public.utf8-plain-text" })
        #expect(utf8.extensions.isEmpty)
        #expect(utf8.mimeTypes.contains("text/plain;charset=utf-8"))
    }

    @Test func classifiesClaimBindings() throws {
        let snapshot = try Fixture.snapshot("markdown.lsdump")

        let mudDocument = try #require(snapshot.claims.first { $0.unitID == "0x4734" })
        #expect(mudDocument.name == "Markdown Document")
        #expect(mudDocument.utis == ["net.daringfireball.markdown", "public.markdown"])
        #expect(mudDocument.rank == "Alternate")
        #expect(mudDocument.roles == ["Viewer"])
        #expect(mudDocument.bundleUnitID == "0x2b40")
        #expect(mudDocument.canHandle)

        let mudDialect = try #require(snapshot.claims.first { $0.unitID == "0x4738" })
        #expect(mudDialect.extensions == ["qmd", "rmd", "mdx", "mdc"])
        #expect(mudDialect.utis.isEmpty)

        let cursor = try #require(snapshot.claims.first { $0.unitID == "0x189c" })
        #expect(cursor.extensions.contains("md"))
        #expect(cursor.utis.isEmpty, "OSTypes and wildcards are not UTIs")
    }

    @Test func parsesHandlerPrefs() throws {
        let snapshot = try Fixture.snapshot("schemes.lsdump")
        let prefs = Dictionary(uniqueKeysWithValues: snapshot.handlerPrefs.map { ($0.tag, $0) })

        #expect(prefs["http"]?.target == .urlScheme("http"))
        #expect(prefs["http"]?.handlerBundleID == "company.thebrowser.browser")
        #expect(prefs["com.apple.default-app.web-browser"]?.target == .contentType("com.apple.default-app.web-browser"))
        #expect(prefs["net.daringfireball.markdown"]?.target == .contentType("net.daringfireball.markdown"))
        #expect(prefs["lnk"]?.target == .filenameExtension("lnk"))
        #expect(prefs["etcher"]?.modificationDate == Date(timeIntervalSince1970: 1789153367))

        let pax = try #require(prefs["public.pax-archive"])
        #expect(pax.tagClass.isEmpty)
        #expect(pax.handlerBundleID == "cx.c3.theunarchiver")
    }

    @Test func toleratesIrregularRecords() throws {
        let snapshot = try Fixture.snapshot("schemes.lsdump")

        let unnamed = try #require(snapshot.claims.first { $0.unitID == "0x1ca8" })
        #expect(unnamed.name.isEmpty)
        #expect(unnamed.schemes == ["sip"])

        let javascript = try #require(snapshot.claims.first { $0.unitID == "0x2a54" })
        #expect(javascript.utis == ["com.netscape.javascript-\u{200B}source"], "Zero-width spaces are preserved, not normalized")

        #expect(snapshot.skippedRecordCounts["plugin id"] == 1)
        #expect(snapshot.skippedRecordCounts["extensionpoint id"] == 1)
        #expect(snapshot.skippedRecordCounts["service id"] == 1)
        #expect(snapshot.skippedRecordCounts["container id"] == 1)
        #expect(snapshot.skippedRecordCounts["values"] == 1)
    }

    @Test func deduplicatesRecordsPrintedTwice() throws {
        let data = try Fixture.data("markdown.lsdump")
        let once = LSDumpParser.parse(data)
        let twice = LSDumpParser.parse(data + data)
        #expect(twice.types.count == once.types.count)
        #expect(twice.claims.count == once.claims.count)
        #expect(twice.bundles.count == once.bundles.count)
        #expect(twice.handlerPrefs.count == once.handlerPrefs.count)
    }

    @Test func skipsUnknownRecordsAndMalformedLines() {
        let separator = String(repeating: "-", count: 80)
        let text = """
        preamble without a colon
        \(separator)
        frobnicator id:             something (0x1)
        weird key:                  value
        \(separator)
        no colon here at all
        type id:                    com.example.thing (0x2)
        uti:                        com.example.thing
        tags:                       .thing, application/x-thing, N104AP, iPhone12,1
                                    { indented garbage: yes }
        mystery key:                ignored
        \(separator)
        claim id:                   Thing (0x3)
        bundle:                     Example (0x4)
        roles:                      Viewer (0000000000000002)
        bindings:                   com.example.thing, .thing, thing:, text/x-thing, '****', .*
        """
        let snapshot = LSDumpParser.parse(text)
        #expect(snapshot.skippedRecordCounts["frobnicator id"] == 1)

        let type = snapshot.types.first
        #expect(type?.identifier == "com.example.thing")
        #expect(type?.extensions == ["thing"])
        #expect(type?.mimeTypes == ["application/x-thing"])

        let claim = snapshot.claims.first
        #expect(claim?.utis == ["com.example.thing"])
        #expect(claim?.extensions == ["thing"])
        #expect(claim?.schemes == ["thing"])
        #expect(claim?.mimeTypes == ["text/x-thing"])
        #expect(claim?.rank == nil)
    }

    @Test func splitsListsOnlyOnCommaSpace() {
        #expect(LSDumpParser.list("N104AP, iPhone12,1, .md") == ["N104AP", "iPhone12,1", ".md"])
        #expect(LSDumpParser.list(#".html, "Apple HTML, pasteboard", text/html"#) == [".html", #""Apple HTML, pasteboard""#, "text/html"])
    }

    @Test func splitsUnitReferences() {
        #expect(LSDumpParser.splitUnitReference("Mud (0x2b40)") == ("Mud", "0x2b40"))
        #expect(LSDumpParser.splitUnitReference("(0x1ca8)") == ("", "0x1ca8"))
        #expect(LSDumpParser.splitUnitReference("Markdown (.md) (0x9414)") == ("Markdown (.md)", "0x9414"))
        #expect(LSDumpParser.splitUnitReference("/Applications/Mud.app") == ("/Applications/Mud.app", nil))
    }

    @Test func extractsLocalizedDefault() {
        #expect(LSDumpParser.localizedValue(#""en" = ?, "LSDefaultLocalizedValue" = "Markdown Document""#) == "Markdown Document")
        #expect(LSDumpParser.localizedValue(#""de" = "Markdown", "en" = "Markdown text""#) == "Markdown text")
    }
}
