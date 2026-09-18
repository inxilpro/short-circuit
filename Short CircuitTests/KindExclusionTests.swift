import Foundation
import Testing
@testable import Short_Circuit

/// Declarations mirror the real CoreTypes/Pages records for these identifiers.
struct KindExclusionTests {
    private static let separator = String(repeating: "-", count: 80)

    private static func type(_ id: String, _ unit: String, conforms: String, tags: String) -> String {
        """
        \(separator)
        type id:                    \(id) (\(unit))
        bundle:                     CoreTypes (0x9)
        uti:                        \(id)
        flags:                      active  apple-internal  exported  core  trusted (0000000000000075)
        conforms to:                \(conforms)
        tags:                       \(tags)
        """
    }

    private static func snapshot(types: [String], claiming utis: [String]) -> LSSnapshot {
        let text = """
        \(separator)
        bundle id:                  Opener (0x10)
        path:                       /Applications/Opener.app (0x11)
        name:                       Opener
        identifier:                 com.example.opener
        class:                      kLSBundleClassApplication (0x2)
        \(types.joined(separator: "\n"))
        \(separator)
        claim id:                   Everything (0x30)
        rank:                       Default
        bundle:                     Opener (0x10)
        roles:                      Viewer (0000000000000002)
        bindings:                   \(utis.joined(separator: ", "))
        """
        return LSDumpParser.parse(text)
    }

    @Test func containersAreNotKindsButDocumentPackagesAre() {
        let types = [
            Self.type("com.apple.application", "0x20", conforms: "public.executable", tags: ""),
            Self.type("com.apple.package", "0x21", conforms: "public.directory", tags: ""),
            Self.type("com.apple.bundle", "0x22", conforms: "public.directory", tags: ""),
            Self.type("public.volume", "0x23", conforms: "public.folder", tags: ""),
            Self.type("com.apple.application-bundle", "0x24", conforms: "com.apple.application, com.apple.localizable-name-bundle, com.apple.package", tags: ".app"),
            Self.type("com.apple.application-file", "0x25", conforms: "com.apple.application, public.data", tags: ".app"),
            Self.type("com.apple.plugin", "0x26", conforms: "com.apple.bundle, com.apple.package", tags: ".plugin"),
            Self.type("com.apple.finder.burn-folder", "0x27", conforms: "public.folder", tags: ".fpbf"),
            Self.type("com.example.volume-thing", "0x28", conforms: "public.volume", tags: ".vol"),
            Self.type("com.apple.rtfd", "0x29", conforms: "com.apple.package, public.composite-content", tags: ".rtfd"),
            Self.type("com.apple.iwork.pages.pages", "0x2a", conforms: "com.apple.package, public.composite-content", tags: ".pages"),
            Self.type("com.apple.photos.library", "0x2b", conforms: "com.apple.package", tags: ".photoslibrary"),
        ]
        let claimed = ["com.apple.application-bundle", "com.apple.application-file", "com.apple.plugin",
                       "com.apple.finder.burn-folder", "com.example.volume-thing", "com.apple.rtfd",
                       "com.apple.iwork.pages.pages", "com.apple.photos.library"]
        let utis = Set(Fixture.offlineBuilder.build(from: Self.snapshot(types: types, claiming: claimed)).flatMap(\.utis))
        #expect(utis == ["com.apple.rtfd", "com.apple.iwork.pages.pages", "com.apple.photos.library"])
    }

    @Test func vendorRawFormatsSharingOnlyAnExtensionStaySplit() {
        let types = [
            Self.type("com.leica.raw-image", "0x40", conforms: "public.camera-raw-image", tags: ".raw, image/x-leica-raw"),
            Self.type("com.panasonic.raw-image", "0x41", conforms: "public.camera-raw-image", tags: ".raw, image/x-panasonic-raw"),
            Self.type("com.example.vendor.doc", "0x42", conforms: "public.data", tags: ".vdoc, application/x-vdoc"),
            Self.type("com.example.vendor.doc-alias", "0x43", conforms: "public.data", tags: ".vdoc, application/x-vdoc-legacy"),
        ]
        let claimed = ["com.leica.raw-image", "com.panasonic.raw-image", "com.example.vendor.doc", "com.example.vendor.doc-alias"]
        let groups = Set(Fixture.offlineBuilder.build(from: Self.snapshot(types: types, claiming: claimed)).map { Set($0.utis) })
        #expect(groups == [
            ["com.leica.raw-image"],
            ["com.panasonic.raw-image"],
            ["com.example.vendor.doc", "com.example.vendor.doc-alias"],
        ], "One vendor's variants with different MIME types are still aliases")
    }
}
