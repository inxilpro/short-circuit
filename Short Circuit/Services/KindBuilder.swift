import Foundation
import UniformTypeIdentifiers

/// Groups Launch Services type declarations and URL schemes into human-level Kinds.
///
/// Merges drive batch default changes, so the rule prefers splitting over an uncertain merge.
///
/// UTIs that at least one app can open are unioned only when they share a filename *extension* from their
/// *active* declarations (inactive imports are often stale or sloppy). MIME types never create edges:
/// apps attach broad ones such as `text/plain` to specific formats (MacWhisper exports Markdown with it),
/// and vendor MIME types glue different formats (Excel workbook, template and workspace). An extension is
/// ignored — "generic" — when
///   - it is a wildcard,
///   - more than `maxDeclarersPerTag` UTIs declare it, or
///   - one declarer conforms to another declarer that is a broad base type (at least
///     `baseTypeMinimumDescendants` known descendants), as with `.xml` (`public.xml` and Word XML) or
///     `.plist`. Vendor aliases such as the two `.docx` UTIs still merge.
/// Finally, a union is refused when it would put two different known categories (audio and movie via
/// `.mp4`, DV movie and Excel DIF via `.dif`) or folders and flat files (`.ibooks` bundle vs. container)
/// in one Kind.
///
/// `dyn.` types are never members, and a UTI needs at least one extension or MIME tag to become a Kind.
nonisolated struct KindBuilder: Sendable {
    struct Options: Sendable {
        var maxDeclarersPerTag = 10
        var baseTypeMinimumDescendants = 20
    }

    struct Output: Sendable {
        var kinds: [Kind]
        var genericTags: Set<String>
    }

    static let webPageID = "web-page"

    /// Too broad to describe a Kind; apps attach them to specific formats.
    static let genericMIMETypes: Set<String> = [
        "text/plain", "application/octet-stream", "application/xml", "text/xml", "application/zip", "application/json",
    ]
    static let emailID = "email"

    var options = Options()
    var describe: @Sendable (String) -> String? = { UTType($0)?.localizedDescription }
    var liveSupertypes: @Sendable (String) -> Set<String> = { identifier in
        guard let type = UTType(identifier) else { return [] }
        return Set(type.supertypes.map(\.identifier))
    }

    func build(from snapshot: LSSnapshot) -> [Kind] {
        analyze(snapshot).kinds
    }

    func analyze(_ snapshot: LSSnapshot) -> Output {
        let context = Context(snapshot: snapshot, options: options)
        let genericTags = context.genericTags()

        let claimedUTIs = context.claimersByUTI.keys.filter { !context.displayTags($0).isEmpty }
        var unionFind = UnionFind(claimedUTIs)
        var declarersByTag: [String: [String]] = [:]
        for uti in claimedUTIs {
            for tag in context.mergeTags(uti) where tag.hasPrefix(".") && !genericTags.contains(tag) {
                declarersByTag[tag, default: []].append(uti)
            }
        }

        var traits: [String: GroupTraits] = [:]
        for uti in claimedUTIs {
            let lineage = lineage(uti, context: context)
            let category = Self.category(identifier: uti, lineage: lineage)
            // A UTI no declaration gives any conformance (Word's `public.markdown`) has an unknown
            // category and may join anything; one that only conforms to `public.data` is known "other".
            let declaresConformance = context.decls[uti, default: []].contains { !$0.conformsTo.isEmpty }
            traits[uti] = GroupTraits(
                categories: declaresConformance ? [category] : [],
                isFolder: lineage.contains("public.folder") || lineage.contains("public.directory") ? [true] : [false]
            )
        }
        for tag in declarersByTag.keys.sorted() {
            let declarers = declarersByTag[tag, default: []].sorted()
            // Every pair is tried, because a refused union with one declarer mustn't stop the rest from merging.
            for (offset, uti) in declarers.enumerated() {
                for earlier in declarers[..<offset] {
                    guard let lhs = unionFind.find(earlier), let rhs = unionFind.find(uti), lhs != rhs else { continue }
                    let merged = traits[lhs, default: .init()].merging(traits[rhs, default: .init()])
                    guard merged.isCoherent else { continue }
                    if let root = unionFind.union(lhs, rhs) { traits[root] = merged }
                }
            }
        }

        var groups = unionFind.groups()
        let webRoots = Set(["public.html", "public.xhtml"].compactMap { unionFind.find($0) })
        let webUTIs = webRoots.flatMap { groups.removeValue(forKey: $0) ?? [] }

        var drafts: [Draft] = groups.values.map { utis in
            Draft(id: "", utis: context.primaryOrder(utis), schemes: [])
        }
        for index in drafts.indices { drafts[index].id = "uti:\(drafts[index].utis[0])" }

        let webSchemes = ["http", "https"].filter { context.claimersByScheme[$0] != nil }
        if !webUTIs.isEmpty || !webSchemes.isEmpty {
            drafts.append(Draft(id: Self.webPageID, utis: context.primaryOrder(webUTIs), schemes: webSchemes, name: "Web page", category: .web))
        }
        if context.claimersByScheme["mailto"] != nil {
            drafts.append(Draft(id: Self.emailID, utis: [], schemes: ["mailto"], name: "Email", category: .communication))
        }
        for scheme in context.claimersByScheme.keys where !["http", "https", "mailto"].contains(scheme) {
            drafts.append(Draft(id: "scheme:\(scheme)", utis: [], schemes: [scheme], name: Self.schemeName(scheme), category: Self.schemeCategory(scheme)))
        }

        let bareExtensions = context.bareExtensionOwners(drafts: drafts.map(\.utis))
        var activeTagOwners: [String: Set<Int>] = [:]
        for (index, draft) in drafts.enumerated() {
            for uti in draft.utis {
                for tag in context.mergeTags(uti) { activeTagOwners[tag, default: []].insert(index) }
            }
        }
        let kinds = drafts.indices.map { index in
            // An inactive import's tag is only shown when no other Kind actively declares it; Xcode's
            // stale Markdown import lists `.text`, which belongs to plain text.
            let isOwnTag: (String) -> Bool = { tag in activeTagOwners[tag].map { $0.contains(index) } ?? true }
            return makeKind(drafts[index], context: context, genericTags: genericTags, bareExtensions: bareExtensions[index] ?? [], isOwnTag: isOwnTag)
        }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Output(kinds: kinds, genericTags: genericTags)
    }

    // MARK: - Kind assembly

    private struct GroupTraits {
        var categories: Set<KindCategory> = []
        var isFolder: Set<Bool> = []

        var isCoherent: Bool { categories.count <= 1 && isFolder.count <= 1 }

        func merging(_ other: GroupTraits) -> GroupTraits {
            GroupTraits(categories: categories.union(other.categories), isFolder: isFolder.union(other.isFolder))
        }
    }

    private func lineage(_ uti: String, context: Context) -> Set<String> {
        context.ancestors(uti).union(liveSupertypes(uti)).union([uti])
    }

    private struct Draft {
        var id: String
        var utis: [String]
        var schemes: [String]
        var name: String?
        var category: KindCategory?
    }

    private func makeKind(
        _ draft: Draft,
        context: Context,
        genericTags: Set<String>,
        bareExtensions: [String],
        isOwnTag: (String) -> Bool
    ) -> Kind {
        var extensions: [String] = []
        var mimeTypes: [String] = []
        for uti in draft.utis {
            for tag in context.displayTags(uti) where !genericTags.contains(tag) && !Self.genericMIMETypes.contains(tag) && isOwnTag(tag) {
                if tag.hasPrefix(".") {
                    let ext = String(tag.dropFirst())
                    if !extensions.contains(ext) { extensions.append(ext) }
                } else if !mimeTypes.contains(tag) {
                    mimeTypes.append(tag)
                }
            }
        }

        var candidateKeys: Set<String> = []
        for uti in draft.utis { candidateKeys.formUnion(context.claimersByUTI[uti] ?? []) }
        for scheme in draft.schemes { candidateKeys.formUnion(context.claimersByScheme[scheme] ?? []) }
        for ext in bareExtensions { candidateKeys.formUnion(context.claimersByExtension[ext] ?? []) }
        let candidates = candidateKeys.compactMap { context.apps[$0] }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        let members = draft.utis.map { KindMember(target: .uti($0), defaultApp: context.defaultApp(forContentType: $0)) }
            + draft.schemes.map { KindMember(target: .scheme($0), defaultApp: context.defaultApp(forScheme: $0)) }

        return Kind(
            id: draft.id,
            name: draft.name ?? name(for: draft.utis, extensions: extensions, context: context),
            category: draft.category ?? category(for: draft.utis, context: context),
            members: members,
            extensions: extensions,
            mimeTypes: mimeTypes,
            candidates: candidates
        )
    }

    private func name(for utis: [String], extensions: [String], context: Context) -> String {
        for uti in utis {
            if let description = describe(uti), !description.isEmpty, description != uti {
                return description.capitalizingFirstLetter
            }
        }
        for uti in utis {
            let decls = context.decls[uti, default: []].sorted { $0.isActive && !$1.isActive }
            if let description = decls.lazy.compactMap(\.localizedDescription).first(where: { !$0.isEmpty }) {
                return description.capitalizingFirstLetter
            }
        }
        if let ext = extensions.first { return "\(ext.uppercased()) file" }
        return utis.first ?? "Unknown"
    }

    private func category(for utis: [String], context: Context) -> KindCategory {
        for uti in utis {
            let category = Self.category(identifier: uti, lineage: lineage(uti, context: context))
            if category != .other { return category }
        }
        return .other
    }

    private static let categoryRules: [(KindCategory, Set<String>)] = [
        (.web, ["public.html", "com.apple.webarchive"]),
        (.code, ["public.source-code", "public.script", "public.shell-script", "public.json", "public.xml", "public.yaml"]),
        (.images, ["public.image"]),
        (.audio, ["public.audio"]),
        (.video, ["public.movie", "public.video", "public.audiovisual-content"]),
        (.archives, ["public.archive", "com.pkware.zip-archive", "public.disk-image", "com.apple.disk-image"]),
        (.communication, ["public.email-message", "public.message", "public.vcard", "public.contact", "public.calendar-event", "com.apple.ical.ics"]),
        (.documents, ["public.text", "public.composite-content", "com.adobe.pdf", "public.presentation", "public.spreadsheet", "public.content"]),
    ]

    private static let developerPrefixes = [
        "com.apple.dt.", "com.apple.xcode.", "com.apple.instruments.", "com.apple.interfacebuilder.", "com.apple.coreml.",
    ]

    private static let developerTypes: Set<String> = [
        "public.executable", "public.unix-executable", "com.apple.mach-o-binary", "com.apple.property-list",
    ]

    static func category(identifier: String, lineage: Set<String>) -> KindCategory {
        if developerPrefixes.contains(where: identifier.hasPrefix) || !lineage.isDisjoint(with: developerTypes) {
            return .developer
        }
        for (category, markers) in categoryRules where !lineage.isDisjoint(with: markers) {
            return category
        }
        return .other
    }

    // MARK: - Schemes

    private static let schemeNames: [String: String] = [
        "tel": "Phone call", "sms": "Text message", "facetime": "FaceTime", "facetime-audio": "FaceTime audio",
        "ftp": "FTP", "sftp": "SFTP", "ssh": "SSH", "telnet": "Telnet", "vnc": "Screen sharing (VNC)",
        "x-man-page": "Man page", "webcal": "Calendar subscription", "feed": "News feed", "feeds": "News feed (secure)",
        "news": "Newsgroup", "itms-apps": "App Store link", "maps": "Maps link", "message": "Mail message link",
        "file": "File URL", "afp": "AFP server", "smb": "SMB server",
    ]

    private static let webSchemes: Set<String> = ["ftp", "ftps", "sftp", "feed", "feeds", "rss", "ws", "wss", "gopher"]
    private static let communicationSchemes: Set<String> = [
        "tel", "sms", "facetime", "facetime-audio", "facetime-group", "imessage", "im", "xmpp", "sip", "sips", "callto",
        "skype", "slack", "discord", "zoommtg", "zoomus", "msteams", "whatsapp", "tg", "sgnl", "message", "webcal",
    ]
    private static let developerSchemes: Set<String> = [
        "ssh", "telnet", "x-man-page", "git", "xcode", "vscode", "vscode-insiders", "cursor", "iterm2", "docker-desktop",
        "github-mac", "x-github-client", "jetbrains", "idea", "phpstorm", "fork", "tower", "sourcetree",
    ]

    static func schemeName(_ scheme: String) -> String {
        schemeNames[scheme] ?? "\(scheme): link"
    }

    static func schemeCategory(_ scheme: String) -> KindCategory {
        if webSchemes.contains(scheme) { return .web }
        if communicationSchemes.contains(scheme) { return .communication }
        if developerSchemes.contains(scheme) { return .developer }
        return .other
    }
}

// MARK: - Snapshot indexes

nonisolated private struct Context {
    let options: KindBuilder.Options
    var decls: [String: [TypeDecl]] = [:]
    var apps: [String: AppRef] = [:]
    var claimersByUTI: [String: Set<String>] = [:]
    var claimersByExtension: [String: Set<String>] = [:]
    var claimersByScheme: [String: Set<String>] = [:]
    private var bundleIDToAppKey: [String: String] = [:]
    private var prefsByContentType: [String: String] = [:]
    private var prefsByScheme: [String: String] = [:]
    private var mergeTagsByUTI: [String: Set<String>] = [:]
    private var displayTagsByUTI: [String: [String]] = [:]
    private var ancestorsByUTI: [String: Set<String>] = [:]

    init(snapshot: LSSnapshot, options: KindBuilder.Options) {
        self.options = options
        for decl in snapshot.types where !decl.isDynamic {
            decls[decl.identifier, default: []].append(decl)
        }
        for (uti, all) in decls {
            let active = all.filter(\.isActive)
            mergeTagsByUTI[uti] = Set((active.isEmpty ? all : active).flatMap(Self.tags))
            var seen: Set<String> = []
            displayTagsByUTI[uti] = (active + all.filter { !$0.isActive }).flatMap(Self.tags).filter { seen.insert($0).inserted }
        }
        for uti in decls.keys {
            var lineage: Set<String> = []
            var stack = decls[uti, default: []].flatMap(\.conformsTo)
            while let next = stack.popLast() {
                guard lineage.insert(next).inserted else { continue }
                stack.append(contentsOf: decls[next, default: []].flatMap(\.conformsTo))
            }
            ancestorsByUTI[uti] = lineage
        }

        var bestBundle: [String: BundleRecord] = [:]
        var appKeyByUnit: [String: String] = [:]
        for bundle in snapshot.bundles where bundle.isApplication {
            guard let key = bundle.identifier ?? bundle.path else { continue }
            if let unit = bundle.unitID { appKeyByUnit[unit] = key }
            if let current = bestBundle[key], Self.pathPreference(current.path) <= Self.pathPreference(bundle.path) { continue }
            bestBundle[key] = bundle
        }
        for (key, bundle) in bestBundle {
            guard let path = bundle.path else { continue }
            apps[key] = AppRef(
                url: URL(fileURLWithPath: path),
                bundleID: bundle.identifier,
                name: bundle.displayName ?? bundle.name,
                version: bundle.version
            )
            if let identifier = bundle.identifier { bundleIDToAppKey[identifier.lowercased()] = key }
        }

        for claim in snapshot.claims where claim.canHandle {
            guard let unit = claim.bundleUnitID, let key = appKeyByUnit[unit], apps[key] != nil else { continue }
            for uti in claim.utis where !uti.hasPrefix("dyn.") { claimersByUTI[uti, default: []].insert(key) }
            for ext in claim.extensions { claimersByExtension[ext, default: []].insert(key) }
            if !claim.flags.contains("private-scheme") {
                for scheme in claim.schemes { claimersByScheme[scheme, default: []].insert(key) }
            }
        }

        for pref in snapshot.handlerPrefs {
            guard let handler = pref.handlerBundleID else { continue }
            switch pref.target {
            case .contentType(let uti): prefsByContentType[uti] = handler
            case .urlScheme(let scheme): prefsByScheme[scheme] = handler
            case .other(let tagClass, let tag) where tagClass.isEmpty:
                if decls[tag] != nil || claimersByUTI[tag] != nil {
                    prefsByContentType[tag] = handler
                } else if claimersByScheme[tag.lowercased()] != nil {
                    prefsByScheme[tag.lowercased()] = handler
                }
            case .filenameExtension, .other: break
            }
        }
    }

    /// Lower is better. Stale copies in DerivedData, the Trash, or mounted volumes lose to installed apps.
    static func pathPreference(_ path: String?) -> Int {
        guard let path else { return 10 }
        if path.contains("/DerivedData/") || path.contains("/.Trash/") || path.hasPrefix("/Volumes/") { return 9 }
        if path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/") { return 0 }
        if path.contains("/Applications/") { return 1 }
        if path.hasPrefix("/System/") { return 2 }
        return 5
    }

    func defaultApp(forContentType uti: String) -> AppRef? {
        prefsByContentType[uti].flatMap(app(forBundleID:))
    }

    func defaultApp(forScheme scheme: String) -> AppRef? {
        prefsByScheme[scheme].flatMap(app(forBundleID:))
    }

    private func app(forBundleID bundleID: String) -> AppRef? {
        bundleIDToAppKey[bundleID.lowercased()].flatMap { apps[$0] }
    }

    /// Tags used for grouping: active declarations only, unless nothing is active.
    func mergeTags(_ uti: String) -> Set<String> {
        mergeTagsByUTI[uti] ?? []
    }

    /// Tags shown to people and used for search: every declaration, active ones first.
    func displayTags(_ uti: String) -> [String] {
        displayTagsByUTI[uti] ?? []
    }

    private static func tags(_ decl: TypeDecl) -> [String] {
        decl.extensions.map { ".\($0)" } + decl.mimeTypes
    }

    func ancestors(_ uti: String) -> Set<String> {
        ancestorsByUTI[uti] ?? []
    }

    func genericTags() -> Set<String> {
        var descendantCounts: [String: Int] = [:]
        var declarersByTag: [String: [String]] = [:]
        for uti in decls.keys {
            for ancestor in ancestors(uti) { descendantCounts[ancestor, default: 0] += 1 }
            for tag in mergeTags(uti) { declarersByTag[tag, default: []].append(uti) }
        }

        var generic: Set<String> = []
        for tag in declarersByTag.keys where tag == ".*" || tag.contains("*") { generic.insert(tag) }
        for (tag, declarers) in declarersByTag where declarers.count > 1 {
            if declarers.count > options.maxDeclarersPerTag {
                generic.insert(tag)
                continue
            }
            let inheritsFromBase = declarers.contains { base in
                descendantCounts[base, default: 0] >= options.baseTypeMinimumDescendants
                    && declarers.contains { $0 != base && ancestors($0).contains(base) }
            }
            if inheritsFromBase { generic.insert(tag) }
        }
        return generic
    }

    /// Decides which Kind each bare extension binding (e.g. an editor claiming `.md` without a UTI) joins,
    /// keyed by draft index. When several Kinds list the extension, prefer ones declaring it actively, then
    /// the one holding a base type the others inherit from; if that is still ambiguous the binding is dropped.
    func bareExtensionOwners(drafts: [[String]]) -> [Int: [String]] {
        var draftsByTag: [String: [Int]] = [:]
        for (index, utis) in drafts.enumerated() {
            var tags: Set<String> = []
            for uti in utis { tags.formUnion(displayTags(uti)) }
            for tag in tags where tag.hasPrefix(".") { draftsByTag[tag, default: []].append(index) }
        }

        var result: [Int: [String]] = [:]
        for ext in claimersByExtension.keys {
            guard let owners = draftsByTag[".\(ext)"], !owners.isEmpty else { continue }
            var owner: Int?
            if owners.count == 1 {
                owner = owners[0]
            } else {
                let active = owners.filter { drafts[$0].contains { mergeTags($0).contains(".\(ext)") } }
                let pool = active.isEmpty ? owners : active
                if pool.count == 1 {
                    owner = pool[0]
                } else {
                    let bases = pool.filter { index in
                        drafts[index].contains { base in
                            pool.contains { other in other != index && drafts[other].contains { ancestors($0).contains(base) } }
                        }
                    }
                    if bases.count == 1 { owner = bases[0] }
                }
            }
            if let owner { result[owner, default: []].append(ext) }
        }
        return result
    }

    /// Public types name Kinds best, then actively declared ones, then the most widely claimed.
    func primaryOrder(_ utis: [String]) -> [String] {
        utis.sorted { lhs, rhs in
            let lhsKey = (lhs.hasPrefix("public.") ? 0 : 1, decls[lhs, default: []].contains(where: \.isActive) ? 0 : 1, -(claimersByUTI[lhs]?.count ?? 0))
            let rhsKey = (rhs.hasPrefix("public.") ? 0 : 1, decls[rhs, default: []].contains(where: \.isActive) ? 0 : 1, -(claimersByUTI[rhs]?.count ?? 0))
            if lhsKey != rhsKey { return lhsKey < rhsKey }
            return lhs < rhs
        }
    }
}

nonisolated private struct UnionFind {
    private var parent: [String: String]

    init(_ elements: some Sequence<String>) {
        parent = Dictionary(uniqueKeysWithValues: elements.map { ($0, $0) })
    }

    mutating func find(_ element: String) -> String? {
        guard var root = parent[element] else { return nil }
        while let next = parent[root], next != root { root = next }
        var current = element
        while let next = parent[current], next != root {
            parent[current] = root
            current = next
        }
        return root
    }

    @discardableResult
    mutating func union(_ lhs: String, _ rhs: String) -> String? {
        guard let lhsRoot = find(lhs), let rhsRoot = find(rhs) else { return nil }
        guard lhsRoot != rhsRoot else { return lhsRoot }
        let root = min(lhsRoot, rhsRoot)
        parent[max(lhsRoot, rhsRoot)] = root
        return root
    }

    mutating func groups() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for element in Array(parent.keys) {
            if let root = find(element) { result[root, default: []].append(element) }
        }
        return result
    }
}

nonisolated private extension String {
    var capitalizingFirstLetter: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
