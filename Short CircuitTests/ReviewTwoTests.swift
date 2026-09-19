import Foundation
import Testing
@testable import Short_Circuit

struct AppIdentityTests {
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Applications/Safari.app")))
    func safariSpellingsAreOneApp() {
        let spellings = [
            "/Applications/Safari.app",
            "/System/Cryptexes/App/System/Applications/Safari.app",
            "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app",
        ].map { URL(fileURLWithPath: $0) }
        let identities = Set(spellings.map(AppIdentity.canonical))
        #expect(identities.count == 1)

        let listed = HandlerService().applicationURLs(forScheme: "http").filter { $0.lastPathComponent == "Safari.app" }
        guard let listedSafari = listed.first else { return }
        let member = KindMember(target: .scheme("http"), candidateURLs: Set(listed.map(AppIdentity.canonical)))
        for url in spellings {
            #expect(member.accepts(AppRef(url: url, bundleID: "com.apple.Safari", name: "Safari", version: nil)), "\(url.path)")
            #expect(AppIdentity.same(url, listedSafari))
        }
    }

    @Test func symlinkedAppsMatchTheirTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "AppIdentityTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appending(path: "Real/Tool.app")
        let link = directory.appending(path: "Tool.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(AppIdentity.canonical(link) == AppIdentity.canonical(real))
        let member = KindMember(target: .uti("com.example.k"), candidateURLs: [LiveKindProvider.canonical(real)])
        #expect(member.accepts(AppRef(url: link, bundleID: nil, name: "Tool", version: nil)))

        let other = directory.appending(path: "Other/Tool.app")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect(AppIdentity.canonical(other) != AppIdentity.canonical(real), "Separate installs stay separate")
    }
}

struct CatalogShapeTests {
    private static let separator = String(repeating: "-", count: 80)

    private static func type(_ id: String, _ unit: String, conforms: String, tags: String) -> String {
        """
        \(separator)
        type id:                    \(id) (\(unit))
        uti:                        \(id)
        flags:                      active  exported  trusted (0000000000000051)
        conforms to:                \(conforms)
        tags:                       \(tags)
        """
    }

    @Test func packagesAreNotAdoptedIntoFlatFileEntries() throws {
        let catalog = try #require(Catalog.bundled)
        let json = try #require(catalog.kinds.first { $0.utis.contains("public.json") }, "The bundled catalog has a JSON entry")
        let text = """
        \(Self.separator)
        bundle id:                  Editor (0x10)
        path:                       /Applications/Editor.app (0x11)
        name:                       Editor
        identifier:                 com.example.editor
        class:                      kLSBundleClassApplication (0x2)
        \(Self.type("public.text", "0x19", conforms: "public.data, public.content", tags: ""))
        \(Self.type("com.apple.package", "0x1a", conforms: "public.directory", tags: ""))
        \(Self.type("public.json", "0x20", conforms: "public.text", tags: ".json, application/json"))
        \(Self.type("com.example.json-bundle", "0x21", conforms: "com.apple.package", tags: ".json"))
        \(Self.type("com.example.json-alias", "0x22", conforms: "public.json", tags: ".json"))
        \(Self.separator)
        claim id:                   Everything (0x30)
        rank:                       Default
        bundle:                     Editor (0x10)
        roles:                      Editor (0000000000000004)
        bindings:                   public.json, com.example.json-bundle, com.example.json-alias
        """
        var builder = Fixture.offlineBuilder
        builder.catalog = Catalog(kinds: [json])
        let kinds = builder.build(from: LSDumpParser.parse(text))
        let jsonKind = try #require(kinds.first { $0.catalogID == json.id })
        #expect(jsonKind.utis.contains("com.example.json-alias"), "A flat same-format vendor alias still joins")
        #expect(!jsonKind.utis.contains("com.example.json-bundle"))
        #expect(kinds.contains { $0.utis == ["com.example.json-bundle"] })
    }
}

struct AppNamingTests {
    @Test func identifierLikeNamesAreRejected() {
        #expect(AppNaming.looksLikeIdentifier("85C27NK92C.com.flexibits.fantastical2.mac.helper"))
        #expect(AppNaming.looksLikeIdentifier("com.example.helper"))
        #expect(!AppNaming.looksLikeIdentifier("zoom.us"))
        #expect(!AppNaming.looksLikeIdentifier("Microsoft Word"))
        #expect(!AppNaming.looksLikeIdentifier("Xcode"))
    }

    @Test func helpersFallBackToTheirLocalizedNameThenTheirParent() {
        let path = "/Applications/Fantastical.app/Contents/Library/LoginItems/85C27NK92C.com.flexibits.fantastical2.mac.helper.app"
        let id = "85C27NK92C.com.flexibits.fantastical2.mac.helper"
        #expect(AppNaming.name(candidates: [id, "Fantastical Helper", id], path: path) == "Fantastical Helper")
        #expect(AppNaming.name(candidates: [id, nil, id], path: path) == "Fantastical")
    }

    @Test func parsedHelperRecordsGetReadableNames() throws {
        let separator = String(repeating: "-", count: 80)
        let text = """
        \(separator)
        bundle id:                  85C27NK92C.com.flexibits.fantastical2.mac.helper (0x512c)
        path:                       /Applications/Fantastical.app/Contents/Library/LoginItems/85C27NK92C.com.flexibits.fantastical2.mac.helper.app (0x6604)
        name:                       85C27NK92C.com.flexibits.fantastical2.mac.helper
        displayName:                85C27NK92C.com.flexibits.fantastical2.mac.helper
        localizedNames:             "Base" = "Fantastical Helper", "en" = "Fantastical Helper"
        identifier:                 85C27NK92C.com.flexibits.fantastical2.mac.helper
        class:                      kLSBundleClassApplication (0x2)
        \(separator)
        claim id:                   Mini (0x30)
        rank:                       Default
        bundle:                     85C27NK92C.com.flexibits.fantastical2.mac.helper (0x512c)
        roles:                      Viewer (0000000000000002)
        bindings:                   x-fantastical-mini:
        """
        let snapshot = LSDumpParser.parse(text)
        #expect(snapshot.bundles.first?.preferredName == "Fantastical Helper")
        let kind = try #require(Fixture.offlineBuilder.build(from: snapshot).first { $0.schemes == ["x-fantastical-mini"] })
        #expect(kind.name == "Fantastical Helper link (x-fantastical-mini:)")
    }

    @Test func twoInstallsOfOneAppNameTheirScheme() {
        let owners = [
            AppRef(url: URL(fileURLWithPath: "/Users/me/.Trash/Bartender 5.app"), bundleID: "com.surteesstudios.Bartender", name: "Bartender 5", version: "5"),
            AppRef(url: URL(fileURLWithPath: "/Volumes/Bartender 6/Bartender 6.app"), bundleID: "com.surteesstudios.Bartender", name: "Bartender 6", version: "6"),
            AppRef(url: URL(fileURLWithPath: "/Applications/Bartender 6.app"), bundleID: "com.surteesstudios.Bartender", name: "Bartender 6", version: "6"),
        ]
        #expect(KindBuilder.schemeName("bartender4license", owners: owners) == "Bartender 6 link (bartender4license:)",
                "The installed copy wins over the Trash and a disk image")
        #expect(KindBuilder.schemeName("bartender4license", owners: Array(owners.prefix(2))).hasSuffix("link (bartender4license:)"))

        let music = AppRef(url: URL(fileURLWithPath: "/System/Applications/Music.app"), bundleID: "com.apple.Music", name: "Music", version: nil)
        let tv = AppRef(url: URL(fileURLWithPath: "/System/Applications/TV.app"), bundleID: "com.apple.TV", name: "TV", version: nil)
        #expect(KindBuilder.schemeName("daap", owners: [tv, music]) == "Music and TV link (daap:)")
    }
}
