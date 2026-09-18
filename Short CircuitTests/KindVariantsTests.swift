import Foundation
import Testing
@testable import Short_Circuit

/// Cases from the first independent review, using real records in `variants.lsdump`.
struct KindVariantsTests {
    private let kinds: [Kind]
    private let output: KindBuilder.Output

    init() throws {
        output = Fixture.offlineBuilder.analyze(try Fixture.snapshot("variants.lsdump"))
        kinds = output.kinds
    }

    private func kind(containing uti: String) -> Kind? {
        kinds.first { $0.utis.contains(uti) }
    }

    @Test func secondaryExtensionCollisionsStaySplit() throws {
        let radiance = try #require(kind(containing: "public.radiance"))
        #expect(radiance.utis == ["public.radiance"], "PICT shares only .pic, which is not its preferred extension")
        let pict = try #require(kind(containing: "com.apple.pict"))
        #expect(pict.utis == ["com.apple.pict"])

        let cpio = try #require(kind(containing: "public.cpio-archive"))
        #expect(cpio.utis == ["public.cpio-archive"], ".pax is only a secondary extension of CPIO")
        #expect(kind(containing: "cx.c3.pax-archive") != nil)
    }

    @Test func aliasesWithTheSamePreferredExtensionMerge() throws {
        let mhtml = try #require(kind(containing: "org.ietf.mhtml"))
        #expect(Set(mhtml.utis) == ["org.ietf.mhtml", "com.microsoft.word.mhtml"])
        #expect(mhtml.category == .documents)
    }

    @Test func officeMacroDocumentsAreDocuments() throws {
        let docm = try #require(kind(containing: "org.openxmlformats.wordprocessingml.document.macroenabled"))
        #expect(docm.category == .documents, "public.executable ancestry must not outrank the Office namespace")
    }

    @Test func installsSharingABundleIDAreSeparateCandidates() throws {
        let psd = try #require(kind(containing: "com.adobe.photoshop-image"))
        let photoshops = psd.candidates.filter { $0.bundleID == "com.adobe.Photoshop" }
        #expect(photoshops.count == 2)
        #expect(Set(photoshops.map(\.url)).count == 2)
        #expect(Set(photoshops.compactMap(\.version)).count == 2, "Versions let the UI tell them apart")
    }

    @Test func bareExtensionClaimsCreateKindsForDeclaredTypes() throws {
        let snapshot = try Fixture.snapshot("variants.lsdump")
        #expect(!snapshot.claims.contains { $0.utis.contains("public.css") || $0.utis.contains("com.microsoft.typescript") },
                "Nothing claims these UTIs directly")

        let css = try #require(kind(containing: "public.css"))
        #expect(css.extensions.contains("css"))
        #expect(css.candidates.contains { $0.bundleID == "com.sublimetext.4" })

        let typescript = try #require(kind(containing: "com.microsoft.typescript"))
        #expect(typescript.extensions.contains("ts"))
        #expect(typescript.candidates.contains { $0.bundleID == "com.sublimetext.4" })
    }

    @Test func extensionsWithoutADeclaredTypeAreReportedNotInvented() throws {
        let sublime = try #require(try Fixture.snapshot("variants.lsdump").claims.first { $0.unitID == "0x23f4" })
        let declared = Set(try Fixture.snapshot("variants.lsdump").types.flatMap(\.extensions))
        let undeclared = sublime.extensions.filter { !declared.contains($0) }
        #expect(!undeclared.isEmpty)
        for ext in undeclared {
            #expect(output.unresolvedTags.contains(".\(ext)"))
            #expect(!kinds.contains { $0.extensions.contains(ext) })
        }
    }

    @Test func abstractTypesAreNotKinds() throws {
        let snapshot = try Fixture.snapshot("variants.lsdump")
        #expect(snapshot.claims.contains { $0.utis.contains("public.data") }, "The fixture has apps claiming public.data")
        #expect(kind(containing: "public.data") == nil)
    }

    @Test func genericTagsStaySearchable() throws {
        let xml = try #require(kind(containing: "public.xml"))
        #expect(xml.extensions.contains("xml"))
        #expect(xml.mimeTypes.contains("application/xml"))

        let json = try #require(kind(containing: "public.json"))
        #expect(json.mimeTypes.contains("application/json"))

        var builder = Fixture.offlineBuilder
        builder.options.maxDeclarersPerTag = 0
        let everythingGeneric = builder.build(from: try Fixture.snapshot("variants.lsdump"))
        #expect(everythingGeneric.first { $0.utis.contains("public.xml") }?.extensions.contains("xml") == true,
                "Excluding a tag from merging must not hide it")
    }

    @Test func sharedNamesAreDisambiguated() throws {
        var builder = Fixture.offlineBuilder
        // The system describes both as "HEIF Image".
        builder.describe = { ["public.heic", "public.heif"].contains($0) ? "HEIF Image" : nil }
        let kinds = builder.build(from: try Fixture.snapshot("variants.lsdump"))
        let names = kinds.map(\.name)
        #expect(Set(names).count == names.count)

        let heic = try #require(kinds.first { $0.utis.contains("public.heic") })
        let heif = try #require(kinds.first { $0.utis.contains("public.heif") })
        #expect(heic.name != heif.name)
        #expect(heic.name.contains(".heic"))
        #expect(heif.name.contains(".heif"))
    }

    @Test func disambiguationFallsBackWhenExtensionsDontDiffer() {
        func kind(_ id: String, extensions: [String]) -> Kind {
            Kind(id: "uti:\(id)", name: "Text", category: .documents, members: [KindMember(target: .uti(id))],
                 extensions: extensions, mimeTypes: [], candidates: [])
        }
        var kinds = [kind("a.one", extensions: ["txt"]), kind("a.two", extensions: ["txt"]), kind("a.three", extensions: [])]
        KindBuilder.disambiguateNames(&kinds)
        #expect(Set(kinds.map(\.name)).count == 3)
    }

    @Test func synthesizedNamesKeepSystemCasing() throws {
        var builder = Fixture.offlineBuilder
        builder.describe = { $0 == "public.heic" ? "iPhone photo" : nil }
        let heic = try #require(builder.build(from: try Fixture.snapshot("variants.lsdump")).first { $0.utis.contains("public.heic") })
        #expect(heic.name.hasPrefix("iPhone photo"))
    }

    @Test func defaultsComeFirstThenAlphabetical() throws {
        for kind in kinds {
            let defaults = Set(kind.members.compactMap(\.defaultApp?.url))
            let rest = kind.candidates.drop { defaults.contains($0.url) }
            #expect(!rest.contains { defaults.contains($0.url) })
            #expect(Array(rest) == rest.sorted(by: KindBuilder.alphabetical))
        }
    }
}

struct KindNamingTests {
    @Test func sentenceCasingOnlyTouchesAllLowercaseFirstWords() {
        #expect(KindBuilder.sentenceCased("text") == "Text")
        #expect(KindBuilder.sentenceCased("iTunes Extra") == "iTunes Extra")
        #expect(KindBuilder.sentenceCased("ICS File") == "ICS File")
        #expect(KindBuilder.sentenceCased("macOS installer") == "macOS installer")
    }

    @Test func inheritedDescriptionsAreNotUsedAsNames() throws {
        var builder = Fixture.offlineBuilder
        builder.describe = { ["com.microsoft.typescript", "public.script"].contains($0) ? "script" : nil }
        builder.liveSupertypes = { $0 == "com.microsoft.typescript" ? ["public.script"] : [] }
        let typescript = try #require(builder.build(from: try Fixture.snapshot("variants.lsdump")).first { $0.utis.contains("com.microsoft.typescript") })
        #expect(typescript.name != "script")
        #expect(typescript.name != "Script")
    }
}

struct PublicTypeNamingTests {
    @Test func publicTypesKeepTheirSystemNameEvenWhenAParentSharesIt() throws {
        var builder = Fixture.offlineBuilder
        builder.describe = { ["public.plain-text", "public.text"].contains($0) ? "text" : nil }
        let plainText = try #require(builder.build(from: try Fixture.snapshot("markdown.lsdump")).first { $0.utis.contains("public.plain-text") })
        #expect(plainText.name == "Text")
    }
}
