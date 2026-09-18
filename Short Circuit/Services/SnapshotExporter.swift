import Foundation
import UniformTypeIdentifiers

/// Writes what catalog authors need to classify a Mac's Launch Services data: every type and scheme
/// an app claims, with tags, conformance, the claiming apps, and the Kind the heuristic put it in.
/// Home-directory paths are abbreviated to `~` so exports from other people's Macs can be shared.
nonisolated enum SnapshotExporter {
    static let formatVersion = 1

    struct Export: Codable, Sendable {
        var formatVersion = SnapshotExporter.formatVersion
        var generatedAt: Date
        var systemVersion: String?
        var types: [TypeEntry]
        var schemes: [SchemeEntry]
        /// Bare extension or MIME claims, keyed by `.ext` or MIME type.
        var tagClaims: [String: [AppEntry]]
    }

    struct TypeEntry: Codable, Sendable {
        var identifier: String
        var description: String?
        var extensions: [String]
        var mimeTypes: [String]
        /// Every ancestor, from declarations plus the live type tree.
        var conformsTo: [String]
        var declaredBy: [String]
        var claimedBy: [AppEntry]
        var isSettable: Bool
        var kindID: String?
    }

    struct SchemeEntry: Codable, Sendable {
        var scheme: String
        var claimedBy: [AppEntry]
        var kindID: String?
    }

    struct AppEntry: Codable, Sendable, Hashable {
        var bundleID: String?
        var name: String
        var path: String?
        var rank: String?
        var roles: [String]
    }

    static func export(
        _ snapshot: LSSnapshot,
        kinds: [Kind] = [],
        describe: (String) -> String? = { UTType($0)?.localizedDescription },
        liveSupertypes: (String) -> Set<String> = { identifier in UTType(identifier).map { Set($0.supertypes.map(\.identifier)) } ?? [] },
        isSettable: (String) -> Bool = KindBuilder.isSettableLive
    ) -> Export {
        let bundles = Dictionary(snapshot.bundles.compactMap { bundle in bundle.unitID.map { ($0, bundle) } }, uniquingKeysWith: { first, _ in first })
        let decls = Dictionary(grouping: snapshot.types.filter { !$0.isDynamic }, by: \.identifier)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        var byUTI: [String: Set<AppEntry>] = [:]
        var byScheme: [String: Set<AppEntry>] = [:]
        var byTag: [String: Set<AppEntry>] = [:]
        for claim in snapshot.claims {
            guard let unit = claim.bundleUnitID, let bundle = bundles[unit], bundle.isApplication else { continue }
            let path = bundle.path.map { $0.hasPrefix(home) ? "~" + $0.dropFirst(home.count) : $0 }
            let app = AppEntry(bundleID: bundle.identifier, name: bundle.displayName ?? bundle.name, path: path, rank: claim.rank, roles: claim.roles)
            for uti in claim.utis where !uti.hasPrefix("dyn.") { byUTI[uti, default: []].insert(app) }
            for scheme in claim.schemes { byScheme[scheme, default: []].insert(app) }
            for ext in claim.extensions { byTag[".\(ext)", default: []].insert(app) }
            for mime in claim.mimeTypes { byTag[mime, default: []].insert(app) }
        }

        var kindByUTI: [String: String] = [:]
        var kindByScheme: [String: String] = [:]
        for kind in kinds {
            for uti in kind.utis { kindByUTI[uti] = kind.id }
            for scheme in kind.schemes { kindByScheme[scheme] = kind.id }
        }

        func ancestors(_ uti: String) -> Set<String> {
            var result: Set<String> = []
            var stack = decls[uti, default: []].flatMap(\.conformsTo)
            while let next = stack.popLast() {
                guard result.insert(next).inserted else { continue }
                stack.append(contentsOf: decls[next, default: []].flatMap(\.conformsTo))
            }
            return result.union(liveSupertypes(uti))
        }

        func sorted(_ apps: Set<AppEntry>) -> [AppEntry] {
            apps.sorted { ($0.name, $0.path ?? "") < ($1.name, $1.path ?? "") }
        }

        let claimedUTIs = Set(byUTI.keys).union(kindByUTI.keys)
        let types = claimedUTIs.sorted().map { uti in
            let declarations = decls[uti, default: []].sorted { $0.isActive && !$1.isActive }
            var extensions: [String] = []
            var mimeTypes: [String] = []
            for declaration in declarations {
                for ext in declaration.extensions where !extensions.contains(ext) { extensions.append(ext) }
                for mime in declaration.mimeTypes where !mimeTypes.contains(mime) { mimeTypes.append(mime) }
            }
            return TypeEntry(
                identifier: uti,
                description: describe(uti) ?? declarations.lazy.compactMap(\.localizedDescription).first,
                extensions: extensions,
                mimeTypes: mimeTypes,
                conformsTo: ancestors(uti).sorted(),
                declaredBy: Array(Set(declarations.compactMap(\.bundleName))).sorted(),
                claimedBy: sorted(byUTI[uti] ?? []),
                isSettable: isSettable(uti),
                kindID: kindByUTI[uti]
            )
        }
        let schemes = byScheme.keys.sorted().map { scheme in
            SchemeEntry(scheme: scheme, claimedBy: sorted(byScheme[scheme] ?? []), kindID: kindByScheme[scheme])
        }

        return Export(
            generatedAt: snapshot.capturedAt,
            systemVersion: snapshot.systemVersion,
            types: types,
            schemes: schemes,
            tagClaims: byTag.mapValues(sorted)
        )
    }

    static func encode(_ export: Export) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(export)
    }
}
