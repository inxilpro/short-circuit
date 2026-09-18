import Foundation
import Testing
@testable import Short_Circuit

/// Runs the real pipeline against this Mac and prints counts for comparison with independent analysis.
/// Opt in with `TEST_RUNNER_SHORT_CIRCUIT_LIVE=1 xcodebuild test …` (xcodebuild strips the prefix).
/// xcodebuild doesn't show the test host's stdout, so an absolute path as the value also writes the report there.
/// It only reads: `lsregister -dump` plus NSWorkspace lookups.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SHORT_CIRCUIT_LIVE"] != nil))
struct LivePipelineDebugTests {
    @Test func printLiveCounts() async throws {
        let clock = ContinuousClock()

        var data = Data()
        let dumpTime = try await clock.measure { data = try await LaunchServicesIndex.runDump() }

        var snapshot: LSSnapshot?
        let parseTime = clock.measure { snapshot = LSDumpParser.parse(data) }
        let parsed = try #require(snapshot)

        var output: KindBuilder.Output?
        let buildTime = clock.measure { output = KindBuilder(catalog: Catalog.bundled).analyze(parsed) }
        let built = try #require(output)

        var enriched: [Kind] = []
        let enrichTime = clock.measure { enriched = LiveKindProvider(index: LaunchServicesIndex(cacheURL: nil)).enrich(built.kinds) }

        let declaredUTIs = Set(parsed.types.map(\.identifier))
        let bundlesByUnit = Dictionary(parsed.bundles.compactMap { bundle in bundle.unitID.map { ($0, bundle) } }, uniquingKeysWith: { first, _ in first })
        let appClaims = parsed.claims.filter { $0.bundleUnitID.flatMap { bundlesByUnit[$0] }?.isApplication == true }
        let claimedSchemes = Set(appClaims.flatMap(\.schemes))
        let claimedUTIs = Set(appClaims.flatMap(\.utis))

        var prefKinds: [String: Int] = [:]
        for pref in parsed.handlerPrefs {
            let label = switch pref.target {
            case .contentType: "content-type"
            case .urlScheme: "scheme"
            case .filenameExtension: "extension"
            case .other(let tagClass, _): tagClass.isEmpty ? "header-only" : "other(\(tagClass))"
            }
            prefKinds[label, default: 0] += 1
        }

        let multiCandidate = enriched.filter { $0.candidates.count >= 2 }
        let split = enriched.filter(\.isSplit)
        let largest = built.kinds.sorted { ($0.members.count, $1.name) > ($1.members.count, $0.name) }.prefix(10)

        var lines: [String] = []
        lines.append("dump: \(data.count) bytes in \(dumpTime)")
        lines.append("parse: \(parseTime) (debug build)")
        lines.append("build kinds: \(buildTime); live enrich: \(enrichTime)")
        lines.append("type records: \(parsed.types.count), unique declared UTIs: \(declaredUTIs.count), dyn.: \(declaredUTIs.filter { $0.hasPrefix("dyn.") }.count)")
        lines.append("claims: \(parsed.claims.count) (app-owned \(appClaims.count)), bundles: \(parsed.bundles.count) (apps \(parsed.bundles.filter(\.isApplication).count))")
        lines.append("app-claimed UTIs: \(claimedUTIs.count), app-claimed schemes: \(claimedSchemes.count)")
        lines.append("handlerprefs: \(parsed.handlerPrefs.count) \(prefKinds.sorted { $0.key < $1.key })")
        lines.append("skipped records: \(parsed.skippedRecordCounts.sorted { $0.key < $1.key })")
        lines.append("generic tags: \(built.genericTags.sorted())")
        lines.append("kinds: \(built.kinds.count) (UTI-based \(built.kinds.filter { !$0.utis.isEmpty }.count), with ≥2 candidates \(multiCandidate.count)), split: \(split.count)")
        for kind in largest {
            lines.append("  \(kind.members.count) members — \(kind.name) [\(kind.category.rawValue)]: \(kind.members.map { "\($0.target)" }.joined(separator: ", "))")
        }
        for kind in split {
            let members = kind.members.map { "\($0.target) → \($0.defaultApp?.name ?? "none")" }.joined(separator: "; ")
            lines.append("  split: \(kind.name): \(members)")
        }
        let categoryTotals = Dictionary(grouping: enriched, by: \.category).mapValues(\.count)
        lines.append("categories: \(KindCategory.allCases.map { "\($0.rawValue) \(categoryTotals[$0] ?? 0)" }.joined(separator: ", "))")
        let common = Dictionary(grouping: multiCandidate, by: \.category).mapValues(\.count)
        lines.append("categories (≥2 candidates): \(KindCategory.allCases.map { "\($0.rawValue) \(common[$0] ?? 0)" }.joined(separator: ", "))")
        let duplicateNames = Dictionary(grouping: enriched, by: \.name).filter { $0.value.count > 1 }.keys.sorted()
        lines.append("duplicate names: \(duplicateNames.count) \(duplicateNames.prefix(20))")
        lines.append("unresolved tag claims: \(built.unresolvedTags.count) \(built.unresolvedTags.sorted().prefix(40))")
        lines.append("unsettable UTI members: \(built.unsettableUTIs.count) \(built.unsettableUTIs.sorted().prefix(30)); Kinds dropped as unsettable: \(built.droppedUnsettableKindCount)")
        lines.append("catalog: \(Catalog.bundled.map { "\($0.kinds.count) entries" } ?? "not loaded"); catalog Kinds: \(enriched.filter { $0.catalogID != nil }.count)")
        lines.append("unmatched catalog entries: \(built.unmatchedCatalogEntries)")
        lines.append("unmatched catalog UTIs: \(built.unmatchedCatalogUTIs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" })")
        let commonKinds = enriched.filter(\.isCommon).sorted { ($0.commonRank ?? 0, $0.name) < ($1.commonRank ?? 0, $1.name) }
        lines.append("common (\(commonKinds.count)):")
        for kind in commonKinds {
            lines.append("  \(kind.commonRank ?? 0). \(kind.name) [\(kind.category.rawValue)] \(kind.members.map { "\($0.target)" }.joined(separator: ", ")) — default: \(kind.isSplit ? "split" : kind.defaultApp?.name ?? "none"), \(kind.candidates.count) apps")
        }
        lines.append("app-private schemes: \(enriched.filter(\.isAppPrivate).count)")
        for probe in [".css", ".ts", ".go", ".rs"] {
            let owners = enriched.filter { $0.extensions.contains(String(probe.dropFirst())) }.map { "\($0.name) \($0.utis)" }
            lines.append("probe \(probe): \(owners)")
        }
        if let markdown = enriched.first(where: { $0.utis.contains("public.markdown") }) {
            lines.append("markdown: \(markdown.name) utis=\(markdown.utis) ext=\(markdown.extensions) candidates=\(markdown.candidates.map(\.name))")
        }
        let report = lines.joined(separator: "\n")
        print(report)
        if let path = ProcessInfo.processInfo.environment["SHORT_CIRCUIT_LIVE"], path.hasPrefix("/") {
            try report.write(toFile: path, atomically: true, encoding: .utf8)
            let rows = enriched.map { kind in
                [kind.name, kind.category.rawValue, kind.members.map { "\($0.target)" }.joined(separator: ", "),
                 kind.extensions.joined(separator: ", "), kind.mimeTypes.joined(separator: ", "),
                 kind.candidates.map(\.name).joined(separator: ", ")].joined(separator: "\t")
            }
            try (["Name\tCategory\tMembers\tExtensions\tMIME\tCandidates"] + rows).joined(separator: "\n")
                .write(toFile: path + ".tsv", atomically: true, encoding: .utf8)
        }
    }
}
