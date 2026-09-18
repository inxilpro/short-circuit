import Foundation
import Testing
@testable import Short_Circuit

struct CatalogLoadingTests {
    @Test func decodesTolerantly() throws {
        let catalog = try Catalog.decode(try Fixture.data("catalog-test.json"))
        #expect(catalog.kinds.count == 8, "The entry without an id is skipped, the rest survive")
        let heif = try #require(catalog.kinds.first { $0.id == "heif" })
        #expect(heif.extensions == ["heif", "heic"], "Leading dots are normalized away")
        #expect(heif.common == nil)
        #expect(heif.schemes.isEmpty)
        #expect(catalog.kinds.first { $0.id == "bad-category" }?.category == nil)
    }

    @Test func rejectsOtherVersions() {
        let data = Data(#"{"version": 2, "kinds": []}"#.utf8)
        #expect(throws: Catalog.LoadError.unsupportedVersion(2)) { try Catalog.decode(data) }
    }

    @Test func malformedFilesLoadAsNil() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "CatalogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for (name, contents) in [("truncated.json", #"{"version": 1, "kinds": ["#), ("wrong-shape.json", #"{"kinds": {}}"#), ("future.json", #"{"version": 9, "kinds": []}"#)] {
            let url = directory.appending(path: name)
            try Data(contents.utf8).write(to: url)
            #expect(Catalog.load(from: url) == nil, "\(name)")
        }
        #expect(Catalog.load(from: directory.appending(path: "missing.json")) == nil)
        #expect(Catalog.load(from: nil) == nil)
    }

    @Test func bundledCatalogIsValid() throws {
        let url = try #require(Bundle.main.url(forResource: "Catalog", withExtension: "json"), "Catalog.json ships in the app")
        let catalog = try Catalog.decode(try Data(contentsOf: url))
        #expect(!catalog.kinds.isEmpty)
        #expect(Set(catalog.kinds.map(\.id)).count == catalog.kinds.count, "Entry ids are unique")
    }
}

struct CatalogMergeTests {
    private let output: KindBuilder.Output

    init() throws {
        var builder = Fixture.offlineBuilder
        builder.catalog = try Catalog.decode(try Fixture.data("catalog-test.json"))
        output = builder.analyze(try Fixture.snapshot("variants.lsdump"))
    }

    private func kind(_ id: String) -> Kind? {
        output.kinds.first { $0.id == id }
    }

    @Test func listedUTIsMergeEvenWhenTheHeuristicSplitsThem() throws {
        let heuristic = Fixture.offlineBuilder.build(from: try Fixture.snapshot("variants.lsdump"))
        #expect(!heuristic.contains { Set($0.utis).isSuperset(of: ["public.radiance", "com.apple.pict"]) })

        let picture = try #require(kind("legacy-picture"))
        #expect(Set(picture.utis) == ["public.radiance", "com.apple.pict"])
        #expect(picture.name == "Legacy picture")
        #expect(picture.category == .images)
        #expect(picture.commonRank == 5)
        #expect(picture.isCommon)
        #expect(picture.keywords == ["quickdraw"])
        #expect(picture.catalogID == "legacy-picture")
        #expect(output.kinds.filter { $0.utis.contains("public.radiance") || $0.utis.contains("com.apple.pict") }.count == 1)
    }

    @Test func aListedUTIIsNeverTakenByAnotherEntry() throws {
        let heic = try #require(kind("heic"))
        let heif = try #require(kind("heif"))
        #expect(heic.utis == ["public.heic"])
        #expect(heif.utis == ["public.heif"], "heif lists .heic as an extension but must not take public.heic")
    }

    @Test func unlistedTypesAreAdoptedByPreferredExtension() throws {
        let photoshop = try #require(kind("photoshop"))
        #expect(photoshop.utis == ["com.adobe.photoshop-image"])
        #expect(photoshop.candidates.filter { $0.bundleID == "com.adobe.Photoshop" }.count == 2)
    }

    @Test func adoptionRespectsCategories() throws {
        #expect(kind("wrong-category-pic") == nil)
    }

    @Test func clusterMatesJoinWhenTheyShareACatalogExtension() throws {
        let css = try #require(kind("css"))
        #expect(css.utis.contains("public.css"))
        #expect(css.candidates.contains { $0.bundleID == "com.sublimetext.4" }, "Bare .css claims still reach the Kind")
    }

    @Test func unknownCategoriesFallBackToTheHeuristic() throws {
        let mhtml = try #require(kind("bad-category"))
        #expect(Set(mhtml.utis) == ["org.ietf.mhtml", "com.microsoft.word.mhtml"])
        #expect(mhtml.category == .documents)
    }

    @Test func entriesMissingFromThisMacProduceNoKind() {
        #expect(kind("absent") == nil)
        #expect(output.unmatchedCatalogEntries.contains("absent"))
        #expect(output.unmatchedCatalogUTIs["absent"] == ["com.example.nothing-claims-this"])
    }

    @Test func heuristicKindsAreNeverCommon() {
        #expect(output.kinds.filter { $0.catalogID == nil }.allSatisfy { !$0.isCommon })
    }

    @Test func catalogExtensionsAreSearchable() throws {
        #expect(kind("legacy-picture")?.extensions.starts(with: ["pic", "pict", "hdr"]) == true)
    }
}

struct CatalogSchemeTests {
    @Test func schemesAttachToTheirEntry() throws {
        let catalog = Catalog(kinds: [
            Catalog.Entry(id: "browser", name: "Web browser", category: .web, common: 1, utis: ["public.html"], schemes: ["http", "https:"]),
            Catalog.Entry(id: "flashing", name: "Disk flashing link", schemes: ["etcher"]),
        ])
        var builder = Fixture.offlineBuilder
        builder.catalog = catalog
        let kinds = builder.build(from: try Fixture.snapshot("schemes.lsdump"))

        let browser = try #require(kinds.first { $0.id == "browser" })
        #expect(Set(browser.schemes) == ["http", "https"])
        #expect(browser.utis.contains("public.html"))
        #expect(!kinds.contains { $0.id == KindBuilder.webPageID }, "The heuristic Web page has nothing left to hold")
        #expect(kinds.filter { $0.schemes.contains("http") }.count == 1)

        let flashing = try #require(kinds.first { $0.id == "flashing" })
        #expect(flashing.schemes == ["etcher"])
        #expect(flashing.category == .other)
        #expect(!kinds.contains { $0.id == "scheme:etcher" })
    }

    @Test func catalogNamesAreNotDisambiguated() throws {
        var builder = Fixture.offlineBuilder
        builder.describe = { $0 == "com.adobe.photoshop-image" ? "Radiance" : nil }
        builder.catalog = Catalog(kinds: [Catalog.Entry(id: "radiance", name: "Radiance", utis: ["public.radiance"])])
        let kinds = builder.build(from: try Fixture.snapshot("variants.lsdump"))
        #expect(kinds.first { $0.id == "radiance" }?.name == "Radiance")
        #expect(kinds.first { $0.utis.contains("com.adobe.photoshop-image") }?.name.hasPrefix("Radiance (") == true)
    }
}
