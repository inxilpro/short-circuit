import Foundation
import Testing
@testable import Short_Circuit

struct SnapshotExporterTests {
    @Test func exportsClaimedTypesSchemesAndTagClaims() throws {
        let snapshot = try Fixture.snapshot("markdown.lsdump")
        let kinds = Fixture.offlineBuilder.build(from: snapshot)
        let export = SnapshotExporter.export(snapshot, kinds: kinds, describe: { _ in nil }, liveSupertypes: { _ in [] }, isSettable: { _ in true })

        let explicitlyClaimed = Set(snapshot.claims.flatMap(\.utis))
        #expect(Set(export.types.map(\.identifier)).isSuperset(of: explicitlyClaimed))

        let markdown = try #require(export.types.first { $0.identifier == "net.daringfireball.markdown" })
        #expect(markdown.extensions.contains("md"))
        #expect(markdown.conformsTo.contains("public.plain-text"))
        #expect(markdown.claimedBy.contains { $0.bundleID == "org.josephpearson.Mud" })
        #expect(markdown.declaredBy.contains("MacWhisper"))
        #expect(markdown.kindID == kinds.first { $0.utis.contains("net.daringfireball.markdown") }?.id)

        #expect(export.tagClaims[".md"]?.contains { $0.bundleID == "com.sublimetext.4" } == true)
    }

    @Test func encodesAsStableJSON() throws {
        let snapshot = try Fixture.snapshot("schemes.lsdump")
        let export = SnapshotExporter.export(snapshot, describe: { _ in nil }, liveSupertypes: { _ in [] }, isSettable: { _ in true })
        let data = try SnapshotExporter.encode(export)
        let decoded = try JSONDecoder.iso8601.decode(SnapshotExporter.Export.self, from: data)
        #expect(decoded.schemes.map(\.scheme) == export.schemes.map(\.scheme))
        #expect(decoded.schemes.contains { $0.scheme == "mailto" && $0.claimedBy.contains { $0.bundleID == "com.apple.mail" } })
        #expect(try SnapshotExporter.encode(export) == data)
    }

    /// Writes this Mac's export for catalog authors. Opt in with `TEST_RUNNER_SHORT_CIRCUIT_EXPORT=/abs/path.json`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHORT_CIRCUIT_EXPORT"]?.hasPrefix("/") == true))
    func exportThisMac() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SHORT_CIRCUIT_EXPORT"])
        let snapshot = LSDumpParser.parse(try await LaunchServicesIndex.runDump())
        let kinds = KindBuilder(catalog: Catalog.bundled).build(from: snapshot)
        try SnapshotExporter.encode(SnapshotExporter.export(snapshot, kinds: kinds)).write(to: URL(fileURLWithPath: path))
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
