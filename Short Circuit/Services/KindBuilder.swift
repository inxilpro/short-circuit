import Foundation
import UniformTypeIdentifiers

/// Groups Launch Services type declarations and URL schemes into human-level Kinds.
///
/// Merges drive batch default changes, so the rule prefers splitting over an uncertain merge.
///
/// Nodes are UTIs an app can open: claimed directly, or reached through a bare extension or MIME claim
/// that resolves to one declared type (an editor claiming `.css` makes `public.css` a node). A node needs
/// at least one filename extension; abstract types such as `public.data` or pasteboard-only types such as
/// `public.utf8-plain-text` never become Kinds, and `dyn.` types are never members.
///
/// Two nodes are unioned only when they look like aliases of one format: each one's *preferred*
/// extension (the first in an active declaration) appears among the other's active extensions.
/// Sharing a secondary extension is not enough — Radiance (`.pic, .hdr`) and PICT (`.pict, .pct, .pic`)
/// or CPIO (`.cpio, .pax`) and pax (`.pax`) stay apart, while the `.docx` or Markdown aliases merge.
/// MIME types never create edges: apps attach broad ones such as `text/plain` to specific formats.
/// An extension is also ignored for merging — "generic" — when it is a wildcard, more than
/// `maxDeclarersPerTag` UTIs declare it, or one declarer conforms to another declarer that is a broad base
/// type (at least `baseTypeMinimumDescendants` descendants), as with `.xml` and `.plist`.
/// Finally, a union is refused when it would put two different specific categories (audio and movie via
/// `.mp4`) or folders and flat files (`.ibooks` bundle vs. container) in one Kind.
///
/// Generic tags are only excluded from merging; they stay on Kinds for display and search.
nonisolated struct KindBuilder: Sendable {
    struct Options: Sendable {
        var maxDeclarersPerTag = 10
        var baseTypeMinimumDescendants = 20
    }

    struct Output: Sendable {
        var kinds: [Kind]
        var genericTags: Set<String>
        /// Bare extension or MIME claims that match no declared type, or several unrelated ones. They
        /// have no UTI a setter could act on, so they don't become Kinds.
        var unresolvedTags: Set<String>
        /// Members macOS won't assign a handler to; they stay visible but don't count toward splits.
        var unsettableUTIs: Set<String> = []
        /// Kinds dropped because none of their members could be set.
        var droppedUnsettableKindCount = 0
        /// Catalog entries with no claimed UTI or scheme on this Mac.
        var unmatchedCatalogEntries: [String] = []
        /// Per catalog entry, listed UTIs nothing on this Mac claims.
        var unmatchedCatalogUTIs: [String: [String]] = [:]
    }

    static let webPageID = "web-page"
    static let emailID = "email"

    /// Schemes that name a transport or a local resource rather than something a person picks a handler for.
    static let abstractSchemes: Set<String> = ["file", "about", "data", "blob", "javascript"]

    /// Means "unknown binary", so it describes nothing.
    static let meaninglessMIMETypes: Set<String> = ["application/octet-stream"]

    var options = Options()
    var describe: @Sendable (String) -> String? = { UTType($0)?.localizedDescription }
    var liveSupertypes: @Sendable (String) -> Set<String> = { identifier in
        guard let type = UTType(identifier) else { return [] }
        return Set(type.supertypes.map(\.identifier))
    }
    var isSettableType: @Sendable (String) -> Bool = KindBuilder.isSettableLive
    var catalog: Catalog?

    func build(from snapshot: LSSnapshot) -> [Kind] {
        analyze(snapshot).kinds
    }

    func analyze(_ snapshot: LSSnapshot) -> Output {
        let context = Context(snapshot: snapshot, options: options)
        let genericTags = context.genericTags()

        let tagClaims = context.resolveTagClaims()
        var claimers = context.claimersByUTI
        for claim in tagClaims.resolved where claim.utis.count == 1 || claim.areAliases {
            for uti in claim.utis { claimers[uti, default: []].formUnion(claim.claimers) }
        }
        let nodes = claimers.keys.filter { context.hasExtension($0) && !Self.isContainer($0, lineage: lineage($0, context: context)) }.sorted()

        var unionFind = UnionFind(nodes)
        var traits: [String: GroupTraits] = [:]
        var nodesByExtension: [String: [String]] = [:]
        for uti in nodes {
            let lineage = lineage(uti, context: context)
            let category = Self.category(identifier: uti, lineage: lineage)
            traits[uti] = GroupTraits(
                categories: category == .other ? [] : [category],
                isFolder: lineage.contains("public.folder") || lineage.contains("public.directory") ? [true] : [false]
            )
            for tag in context.mergeTags(uti) where tag.hasPrefix(".") && !genericTags.contains(tag) {
                nodesByExtension[tag, default: []].append(uti)
            }
        }
        for tag in nodesByExtension.keys.sorted() {
            let sharing = nodesByExtension[tag, default: []]
            // Every pair is tried, because a refused union with one node mustn't stop the rest from merging.
            for (offset, uti) in sharing.enumerated() {
                for earlier in sharing[..<offset] where context.areAliases(earlier, uti) {
                    guard let lhs = unionFind.find(earlier), let rhs = unionFind.find(uti), lhs != rhs else { continue }
                    let merged = traits[lhs, default: .init()].merging(traits[rhs, default: .init()])
                    guard merged.isCoherent else { continue }
                    if let root = unionFind.union(lhs, rhs) { traits[root] = merged }
                }
            }
        }

        var groups = unionFind.groups()
        var groupByNode: [String: String] = [:]
        for (root, members) in groups {
            for member in members { groupByNode[member] = root }
        }

        var drafts: [Draft] = []
        var catalogReport = CatalogReport()
        var catalogSchemes: Set<String> = []
        var catalogIDs: Set<String> = []
        if let catalog {
            let assignment = assignCatalog(catalog, nodes: nodes, groupByNode: groupByNode, groups: groups, claimers: claimers, context: context)
            catalogReport = assignment.report
            let assigned = Set(assignment.drafts.flatMap(\.utis))
            groups = groups.compactMapValues { members in
                let remaining = members.filter { !assigned.contains($0) }
                return remaining.isEmpty ? nil : remaining
            }
            drafts = assignment.drafts
            catalogSchemes = Set(assignment.drafts.flatMap(\.schemes))
            catalogIDs = Set(assignment.drafts.map(\.id))
        }

        let webRoots = Set(["public.html", "public.xhtml"].compactMap { unionFind.find($0) })
        let webUTIs = webRoots.flatMap { groups.removeValue(forKey: $0) ?? [] }

        drafts += groups.values.map { utis in
            let ordered = context.primaryOrder(utis, claimers: claimers)
            return Draft(id: "uti:\(ordered[0])", utis: ordered, schemes: [])
        }

        let webSchemes = ["http", "https"].filter { context.claimersByScheme[$0] != nil && !catalogSchemes.contains($0) }
        if (!webUTIs.isEmpty || !webSchemes.isEmpty) && !catalogIDs.contains(Self.webPageID) {
            let utis = context.primaryOrder(webUTIs, claimers: claimers)
            drafts.append(Draft(id: Self.webPageID, utis: utis, schemes: webSchemes, name: "Web page", category: .web))
        }
        if context.claimersByScheme["mailto"] != nil && !catalogSchemes.contains("mailto") && !catalogIDs.contains(Self.emailID) {
            drafts.append(Draft(id: Self.emailID, utis: [], schemes: ["mailto"], name: "Email", category: .communication))
        }
        for scheme in context.claimersByScheme.keys.sorted()
        where !["http", "https", "mailto"].contains(scheme) && !Self.abstractSchemes.contains(scheme) && !catalogSchemes.contains(scheme) {
            let owners = context.claimersByScheme[scheme, default: []].compactMap { context.apps[$0] }
            let isWellKnown = Self.schemeNames[scheme] != nil || Self.schemeCategory(scheme) != .other
            drafts.append(Draft(
                id: "scheme:\(scheme)",
                utis: [],
                schemes: [scheme],
                name: Self.schemeName(scheme, owners: owners),
                category: Self.schemeCategory(scheme),
                isAppPrivate: !isWellKnown && Set(owners.map { $0.bundleID ?? $0.url.path }).count <= 1
            ))
        }

        // Tag claims whose candidate types ended up in one Kind add their apps to it (the `.md` editors).
        var draftIndexByUTI: [String: Int] = [:]
        for (index, draft) in drafts.enumerated() {
            for uti in draft.utis { draftIndexByUTI[uti] = index }
        }
        var tagClaimers: [Int: Set<String>] = [:]
        var unresolvedTags = tagClaims.unresolved
        for claim in tagClaims.resolved {
            let owners = Set(claim.utis.compactMap { draftIndexByUTI[$0] })
            if owners.count == 1, let owner = owners.first {
                tagClaimers[owner, default: []].formUnion(claim.claimers)
            } else {
                unresolvedTags.insert(claim.tag)
            }
        }

        var activeTagOwners: [String: Set<Int>] = [:]
        for (index, draft) in drafts.enumerated() {
            for uti in draft.utis {
                for tag in context.mergeTags(uti) { activeTagOwners[tag, default: []].insert(index) }
            }
        }

        var kinds = drafts.indices.map { index in
            makeKind(
                drafts[index],
                context: context,
                claimers: claimers,
                extraClaimers: tagClaimers[index] ?? [],
                showsTag: { tag, uti in
                    // An inactive import's tag only shows when no other Kind actively declares it; Xcode's
                    // stale Markdown import lists `.text`, which belongs to plain text.
                    if let owners = activeTagOwners[tag], !owners.contains(index) { return false }
                    return !context.isInheritedPollution(tag, on: uti)
                }
            )
        }
        let unsettableUTIs = Set(kinds.flatMap { $0.members.filter { !$0.isSettable } }.compactMap { member -> String? in
            if case .uti(let identifier) = member.target { identifier } else { nil }
        })
        let unsettableKindCount = kinds.count { $0.settableMembers.isEmpty }
        kinds.removeAll { $0.settableMembers.isEmpty }
        Self.disambiguateNames(&kinds)
        kinds.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Output(
            kinds: kinds,
            genericTags: genericTags,
            unresolvedTags: unresolvedTags,
            unsettableUTIs: unsettableUTIs,
            droppedUnsettableKindCount: unsettableKindCount,
            unmatchedCatalogEntries: catalogReport.unmatchedEntries,
            unmatchedCatalogUTIs: catalogReport.unmatchedUTIs
        )
    }

    // MARK: - Catalog

    private struct CatalogReport {
        var unmatchedEntries: [String] = []
        var unmatchedUTIs: [String: [String]] = [:]
    }

    /// The catalog is authoritative for the UTIs it lists: they form one Kind per entry however the
    /// heuristic grouped them, and no other entry or heuristic group can take them. A node the catalog
    /// doesn't list joins an entry when
    ///   - a heuristic cluster-mate is listed by that entry and the node declares one of the entry's
    ///     extensions (Kaleidoscope's CSS type next to `public.css`), or otherwise
    ///   - its preferred extension is one of the entry's extensions and its category doesn't conflict
    ///     (a vendor's own `.csv` type).
    /// A node that matches several entries joins none. Entries matching nothing on this Mac produce no Kind.
    private func assignCatalog(
        _ catalog: Catalog,
        nodes: [String],
        groupByNode: [String: String],
        groups: [String: [String]],
        claimers: [String: Set<String>],
        context: Context
    ) -> (drafts: [Draft], report: CatalogReport) {
        var owner: [String: Int] = [:]
        for (index, entry) in catalog.kinds.enumerated() {
            for uti in entry.utis where owner[uti] == nil { owner[uti] = index }
        }

        let nodeSet = Set(nodes)
        var members: [Int: [String]] = [:]
        var report = CatalogReport()
        for (index, entry) in catalog.kinds.enumerated() {
            for uti in entry.utis where owner[uti] == index {
                let isAvailable = nodeSet.contains(uti)
                    || (!(claimers[uti]?.isEmpty ?? true) && !Self.isContainer(uti, lineage: lineage(uti, context: context)))
                if isAvailable {
                    members[index, default: []].append(uti)
                } else {
                    report.unmatchedUTIs[entry.id, default: []].append(uti)
                }
            }
        }

        let entryExtensions = catalog.kinds.map { Set($0.extensions.map { ".\($0)" }) }
        for uti in nodes where owner[uti] == nil {
            let tags = context.mergeTags(uti)
            let mates = groupByNode[uti].flatMap { groups[$0] } ?? []
            let clusterEntries = Set(mates.compactMap { owner[$0] }).filter { !entryExtensions[$0].isDisjoint(with: tags) }

            var chosen: Int?
            if clusterEntries.count == 1 {
                chosen = clusterEntries.first
            } else if clusterEntries.isEmpty {
                let category = Self.category(identifier: uti, lineage: lineage(uti, context: context))
                let adopting = catalog.kinds.indices.filter { index in
                    guard !entryExtensions[index].isDisjoint(with: context.preferredExtensions(uti)) else { return false }
                    guard let wanted = catalog.kinds[index].category, category != .other else { return true }
                    return wanted == category
                }
                if adopting.count == 1 { chosen = adopting[0] }
            }
            if let chosen { members[chosen, default: []].append(uti) }
        }

        var drafts: [Draft] = []
        for (index, entry) in catalog.kinds.enumerated() {
            let schemes = entry.schemes.filter { context.claimersByScheme[$0] != nil }
            let utis = context.primaryOrder(members[index] ?? [], claimers: claimers)
            guard !utis.isEmpty || !schemes.isEmpty else {
                report.unmatchedEntries.append(entry.id)
                continue
            }
            drafts.append(Draft(
                id: entry.id,
                utis: utis,
                schemes: schemes,
                name: entry.name,
                category: entry.category ?? (utis.isEmpty ? schemes.first.map(Self.schemeCategory) : nil),
                commonRank: entry.common,
                keywords: entry.keywords,
                catalogExtensions: entry.extensions,
                catalogID: entry.id
            ))
        }
        return (drafts, report)
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

    /// Apps, loadable bundles (plug-ins, prefpanes, test bundles), volumes and plain folders are opened
    /// by the system, not by an app a person picks. Document packages (`.rtfd`, `.pages`, photo
    /// libraries) are directories too, but they're packages, and bundles that are content stay.
    static func isContainer(_ identifier: String, lineage: Set<String>) -> Bool {
        if lineage.contains("com.apple.application") || lineage.contains("public.volume") { return true }
        if documentBundlePrefixes.contains(where: identifier.hasPrefix) { return false }
        let isContent = lineage.contains("public.content") || lineage.contains("public.composite-content")
        if lineage.contains("com.apple.bundle"), !isContent { return true }
        let isDirectory = lineage.contains("public.directory") || lineage.contains("public.folder")
        return isDirectory && !lineage.contains("com.apple.package") && !isContent
    }

    /// Bundle-shaped formats people do reassign (Installer vs. Suspicious Package, Wallet passes)
    /// even though they don't declare content conformance.
    private static let documentBundlePrefixes = ["com.apple.installer-", "com.apple.pkpass"]

    /// macOS refuses to assign a handler to a type that conforms to neither `public.item` nor
    /// `public.data` (Word's bare `public.markdown` import), and no file resolves to it anyway.
    static func isSettableLive(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .item) || type.conforms(to: .data)
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
        var isAppPrivate = false
        var commonRank: Int?
        var keywords: [String] = []
        var catalogExtensions: [String] = []
        var catalogID: String?
    }

    private func makeKind(
        _ draft: Draft,
        context: Context,
        claimers: [String: Set<String>],
        extraClaimers: Set<String>,
        showsTag: (String, String) -> Bool
    ) -> Kind {
        var extensions = draft.catalogExtensions
        var mimeTypes: [String] = []
        for uti in draft.utis {
            for tag in context.displayTags(uti) where showsTag(tag, uti) && !Self.meaninglessMIMETypes.contains(tag) {
                if tag.hasPrefix(".") {
                    let ext = String(tag.dropFirst())
                    if !extensions.contains(ext) { extensions.append(ext) }
                } else if !mimeTypes.contains(tag) {
                    mimeTypes.append(tag)
                }
            }
        }

        let members = draft.utis.map { KindMember(target: .uti($0), defaultApp: context.defaultApp(forContentType: $0), isSettable: isSettableType($0)) }
            + draft.schemes.map { KindMember(target: .scheme($0), defaultApp: context.defaultApp(forScheme: $0)) }

        var candidateKeys = extraClaimers
        for uti in draft.utis { candidateKeys.formUnion(claimers[uti] ?? []) }
        for scheme in draft.schemes { candidateKeys.formUnion(context.claimersByScheme[scheme] ?? []) }
        let defaults = Set(members.compactMap(\.defaultApp?.url))
        let candidates = candidateKeys.compactMap { context.apps[$0] }
            .sorted { lhs, rhs in
                let lhsTier = defaults.contains(lhs.url) ? 0 : 1
                let rhsTier = defaults.contains(rhs.url) ? 0 : 1
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                return Self.alphabetical(lhs, rhs)
            }

        return Kind(
            id: draft.id,
            name: draft.name ?? name(for: draft.utis, extensions: extensions, context: context),
            category: draft.category ?? category(for: draft.utis, context: context),
            members: members,
            extensions: extensions,
            mimeTypes: mimeTypes,
            candidates: candidates,
            isAppPrivate: draft.isAppPrivate,
            commonRank: draft.commonRank,
            keywords: draft.keywords,
            catalogID: draft.catalogID
        )
    }

    /// Capitalizes a leading all-lowercase word ("text" → "Text") but leaves deliberate casing such as
    /// "iTunes Extra" or "macOS" alone.
    static func sentenceCased(_ name: String) -> String {
        let firstWord = name.prefix { !$0.isWhitespace }
        guard let first = firstWord.first, first.isLowercase, firstWord.allSatisfy({ !$0.isUppercase }) else { return name }
        return first.uppercased() + name.dropFirst()
    }

    static func alphabetical(_ lhs: AppRef, _ rhs: AppRef) -> Bool {
        let order = lhs.name.localizedStandardCompare(rhs.name)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.url.path < rhs.url.path
    }

    /// A vendor type's system description that merely repeats a supertype's ("script" for TypeScript)
    /// says nothing about the format, so the declaring app's own description or the extension is used
    /// instead. `public.*` descriptions are Apple's canonical names even when a parent shares them.
    private func name(for utis: [String], extensions: [String], context: Context) -> String {
        for uti in utis {
            guard let description = describe(uti), !description.isEmpty, description != uti else { continue }
            if uti.hasPrefix("public.") { return Self.sentenceCased(description) }
            let inherited = lineage(uti, context: context).subtracting([uti, "public.item", "public.data"])
                .compactMap(describe).map { $0.lowercased() }
            if !inherited.contains(description.lowercased()) { return Self.sentenceCased(description) }
        }
        for uti in utis {
            let decls = context.decls[uti, default: []].sorted { $0.isActive && !$1.isActive }
            if let description = decls.lazy.compactMap(\.localizedDescription).first(where: { !$0.isEmpty }) {
                return Self.sentenceCased(description)
            }
        }
        if let ext = extensions.first { return "\(ext.uppercased()) file" }
        return utis.first ?? "Unknown"
    }

    /// Kinds that share a name get the first extension the others lack (then a MIME type, then the
    /// identifier) so "HEIF Image (.heic)" and "HEIF Image (.heif)" can be told apart.
    static func disambiguateNames(_ kinds: inout [Kind]) {
        let groups = Dictionary(grouping: kinds.indices, by: { kinds[$0].name.lowercased() }).values.filter { $0.count > 1 }
        for group in groups {
            var suffixes: [Int: String] = [:]
            for index in group {
                let others = group.filter { $0 != index }
                let otherExtensions = Set(others.flatMap { kinds[$0].extensions })
                let otherMIMETypes = Set(others.flatMap { kinds[$0].mimeTypes })
                if let ext = kinds[index].extensions.first(where: { !otherExtensions.contains($0) }) {
                    suffixes[index] = ".\(ext)"
                } else if let mime = kinds[index].mimeTypes.first(where: { !otherMIMETypes.contains($0) }) {
                    suffixes[index] = mime
                } else {
                    suffixes[index] = kinds[index].utis.first ?? kinds[index].schemes.first.map { "\($0):" } ?? kinds[index].id
                }
            }
            if Set(suffixes.values).count < group.count {
                for index in group {
                    suffixes[index] = kinds[index].utis.first ?? kinds[index].schemes.first.map { "\($0):" } ?? kinds[index].id
                }
            }
            // Catalog names are curated; only heuristic Kinds get a suffix.
            for index in group where kinds[index].catalogID == nil {
                if let suffix = suffixes[index] { kinds[index].name += " (\(suffix))" }
            }
        }
    }

    private func category(for utis: [String], context: Context) -> KindCategory {
        for uti in utis {
            let category = Self.category(identifier: uti, lineage: lineage(uti, context: context))
            if category != .other { return category }
        }
        return .other
    }

    private static let developerPrefixes = [
        "com.apple.dt.", "com.apple.xcode.", "com.apple.instruments.", "com.apple.interfacebuilder.", "com.apple.coreml.",
    ]

    /// Office formats often declare only XML or data ancestry, and macro-enabled ones add
    /// `public.executable`; their vendor namespace is the better signal.
    private static let documentPrefixes = [
        "com.microsoft.word.", "com.microsoft.excel.", "com.microsoft.powerpoint.", "org.openxmlformats.",
        "org.oasis-open.opendocument.", "com.apple.iwork.",
    ]

    /// Checked in order; earlier rules win.
    private static let categoryRules: [(KindCategory, Set<String>)] = [
        (.web, ["public.html", "com.apple.webarchive"]),
        (.documents, ["public.composite-content", "com.adobe.pdf", "public.presentation", "public.spreadsheet"]),
        (.code, ["public.source-code", "public.script", "public.shell-script", "public.json", "public.xml", "public.yaml"]),
        (.images, ["public.image"]),
        (.audio, ["public.audio"]),
        (.video, ["public.movie", "public.video", "public.audiovisual-content"]),
        (.archives, ["public.archive", "com.pkware.zip-archive", "public.disk-image", "com.apple.disk-image"]),
        (.communication, ["public.email-message", "public.message", "public.vcard", "public.contact", "public.calendar-event", "com.apple.ical.ics"]),
        (.developer, ["public.executable", "public.unix-executable", "com.apple.mach-o-binary", "com.apple.property-list"]),
        (.documents, ["public.text", "public.content"]),
    ]

    static func category(identifier: String, lineage: Set<String>) -> KindCategory {
        if developerPrefixes.contains(where: identifier.hasPrefix) { return .developer }
        if documentPrefixes.contains(where: identifier.hasPrefix) { return .documents }
        for (category, markers) in categoryRules where !lineage.isDisjoint(with: markers) {
            return category
        }
        return .other
    }

    // MARK: - Schemes

    static let schemeNames: [String: String] = [
        "tel": "Phone call", "sms": "Text message", "facetime": "FaceTime", "facetime-audio": "FaceTime audio",
        "ftp": "FTP", "sftp": "SFTP", "ssh": "SSH", "telnet": "Telnet", "vnc": "Screen sharing (VNC)",
        "x-man-page": "Man page", "webcal": "Calendar subscription", "feed": "News feed", "feeds": "News feed (secure)",
        "news": "Newsgroup", "itms-apps": "App Store link", "maps": "Maps link", "message": "Mail message link",
        "afp": "AFP server", "smb": "SMB server", "sip": "SIP call", "slack": "Slack link", "zoommtg": "Zoom meeting",
        "msteams": "Microsoft Teams link", "vscode": "VS Code link", "x-github-client": "GitHub Desktop link",
    ]

    private static let webSchemes: Set<String> = ["http", "https", "ftp", "ftps", "sftp", "feed", "feeds", "rss", "ws", "wss", "gopher"]
    private static let communicationSchemes: Set<String> = [
        "mailto", "tel", "sms", "facetime", "facetime-audio", "facetime-group", "imessage", "im", "xmpp", "sip", "sips",
        "callto", "skype", "slack", "discord", "zoommtg", "zoomus", "zoomphonecall", "zoomphonesms", "msteams", "whatsapp",
        "tg", "sgnl", "signal", "message", "webcal",
    ]
    private static let developerSchemes: Set<String> = [
        "ssh", "telnet", "x-man-page", "git", "xcode", "vscode", "vscode-insiders", "cursor", "iterm2", "docker-desktop",
        "github-mac", "jetbrains", "idea", "phpstorm", "fork", "tower", "sourcetree",
    ]
    private static let developerSchemePrefixes = ["x-github", "xcode-", "x-xcode", "vscode-", "jetbrains-"]

    /// Well-known schemes get a fixed name; others are named after the app that registers them, with the
    /// scheme itself in parentheses so people can recognise it in URLs.
    static func schemeName(_ scheme: String, owners: [AppRef] = []) -> String {
        if let name = schemeNames[scheme] { return name }
        let names = Set(owners.map(\.name))
        if names.count == 1, let app = names.first { return "\(app) link (\(scheme):)" }
        return "\(scheme): link"
    }

    static func schemeCategory(_ scheme: String) -> KindCategory {
        if webSchemes.contains(scheme) { return .web }
        if communicationSchemes.contains(scheme) { return .communication }
        if developerSchemes.contains(scheme) || developerSchemePrefixes.contains(where: scheme.hasPrefix) { return .developer }
        return .other
    }
}

// MARK: - Snapshot indexes

nonisolated private struct Context {
    struct TagClaim {
        var tag: String
        /// Declared types the tag most plausibly means; several only when none stands out.
        var utis: [String]
        var claimers: Set<String>
        /// Several equally good declarers that are aliases of one format (Kaleidoscope's own `.css` type
        /// next to `public.css`); they will merge, so each can become a node.
        var areAliases = false
    }

    let options: KindBuilder.Options
    var decls: [String: [TypeDecl]] = [:]
    /// Keyed by standardized bundle path: two installs sharing a bundle ID are different candidates.
    var apps: [String: AppRef] = [:]
    var claimersByUTI: [String: Set<String>] = [:]
    var claimersByTag: [String: Set<String>] = [:]
    var claimersByScheme: [String: Set<String>] = [:]
    private var preferredAppByBundleID: [String: String] = [:]
    private var prefsByContentType: [String: String] = [:]
    private var prefsByScheme: [String: String] = [:]
    private var mergeTagsByUTI: [String: Set<String>] = [:]
    private var preferredExtensionsByUTI: [String: Set<String>] = [:]
    private var displayTagsByUTI: [String: [String]] = [:]
    private var ancestorsByUTI: [String: Set<String>] = [:]

    init(snapshot: LSSnapshot, options: KindBuilder.Options) {
        self.options = options
        for decl in snapshot.types where !decl.isDynamic {
            decls[decl.identifier, default: []].append(decl)
        }
        for (uti, all) in decls {
            let active = all.filter(\.isActive)
            let merging = active.isEmpty ? all : active
            mergeTagsByUTI[uti] = Set(merging.flatMap(Self.tags))
            preferredExtensionsByUTI[uti] = Set(merging.compactMap { $0.extensions.first.map { ".\($0)" } })
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

        var appKeyByUnit: [String: String] = [:]
        for bundle in snapshot.bundles where bundle.isApplication {
            guard let path = bundle.path else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let key = url.path
            if let unit = bundle.unitID { appKeyByUnit[unit] = key }
            if apps[key] == nil {
                apps[key] = AppRef(url: url, bundleID: bundle.identifier, name: bundle.displayName ?? bundle.name, version: bundle.version)
            }
            if let identifier = bundle.identifier?.lowercased() {
                if let current = preferredAppByBundleID[identifier], Self.pathPreference(current) <= Self.pathPreference(key) { continue }
                preferredAppByBundleID[identifier] = key
            }
        }

        for claim in snapshot.claims where claim.canHandle {
            guard let unit = claim.bundleUnitID, let key = appKeyByUnit[unit] else { continue }
            for uti in claim.utis where !uti.hasPrefix("dyn.") { claimersByUTI[uti, default: []].insert(key) }
            for ext in claim.extensions { claimersByTag[".\(ext)", default: []].insert(key) }
            for mime in claim.mimeTypes { claimersByTag[mime, default: []].insert(key) }
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

    /// Lower is better. Only used to pick which install a bundle-ID preference refers to.
    static func pathPreference(_ path: String) -> Int {
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
        preferredAppByBundleID[bundleID.lowercased()].flatMap { apps[$0] }
    }

    /// Tags used for grouping: active declarations only, unless nothing is active.
    func mergeTags(_ uti: String) -> Set<String> {
        mergeTagsByUTI[uti] ?? []
    }

    /// Tags shown to people and used for search: every declaration, active ones first.
    func displayTags(_ uti: String) -> [String] {
        displayTagsByUTI[uti] ?? []
    }

    func preferredExtensions(_ uti: String) -> Set<String> {
        preferredExtensionsByUTI[uti] ?? []
    }

    func hasExtension(_ uti: String) -> Bool {
        displayTags(uti).contains { $0.hasPrefix(".") && $0 != ".*" }
    }

    /// Each type's preferred extension must be one the other declares. Types from different vendor
    /// namespaces that each name their own MIME types are distinct formats that happen to share a
    /// generic extension (Leica and Panasonic `.raw`).
    func areAliases(_ lhs: String, _ rhs: String) -> Bool {
        let lhsTags = mergeTags(lhs)
        let rhsTags = mergeTags(rhs)
        guard preferredExtensionsByUTI[lhs, default: []].contains(where: rhsTags.contains),
              preferredExtensionsByUTI[rhs, default: []].contains(where: lhsTags.contains)
        else { return false }
        let lhsMIME = lhsTags.filter { !$0.hasPrefix(".") }
        let rhsMIME = rhsTags.filter { !$0.hasPrefix(".") }
        if !lhsMIME.isEmpty, !rhsMIME.isEmpty, lhsMIME.isDisjoint(with: rhsMIME), Self.vendor(lhs) != Self.vendor(rhs) {
            return false
        }
        return true
    }

    /// `com.leica.raw-image` → `com.leica`.
    static func vendor(_ uti: String) -> String {
        uti.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// A tag a type repeats from its own base type (MacWhisper's Markdown export lists `text/plain`) is
    /// noise on that type, unless it's the type's only tag of that kind (Word XML's only extension is `.xml`).
    func isInheritedPollution(_ tag: String, on uti: String) -> Bool {
        let lineage = ancestors(uti)
        guard lineage.contains(where: { mergeTags($0).contains(tag) }) else { return false }
        let isExtension = tag.hasPrefix(".")
        return displayTags(uti).contains { other in
            other != tag && other.hasPrefix(".") == isExtension && !lineage.contains { mergeTags($0).contains(other) }
        }
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
        for tag in declarersByTag.keys where tag.contains("*") { generic.insert(tag) }
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

    /// Maps each bare extension or MIME claim to the declared type(s) it means. Among several declarers,
    /// those whose preferred tag it is win; among those, a single base type the rest inherit from wins.
    func resolveTagClaims() -> (resolved: [TagClaim], unresolved: Set<String>) {
        var declarersByTag: [String: Set<String>] = [:]
        var activeDeclarersByTag: [String: Set<String>] = [:]
        for uti in decls.keys {
            for tag in displayTags(uti) { declarersByTag[tag, default: []].insert(uti) }
            for tag in mergeTags(uti) { activeDeclarersByTag[tag, default: []].insert(uti) }
        }

        var resolved: [TagClaim] = []
        var unresolved: Set<String> = []
        for (tag, claimers) in claimersByTag where !tag.contains("*") {
            guard var candidates = activeDeclarersByTag[tag] ?? declarersByTag[tag], !candidates.isEmpty else {
                unresolved.insert(tag)
                continue
            }
            if candidates.count > 1 {
                let preferring = candidates.filter { uti in
                    tag.hasPrefix(".") ? preferredExtensionsByUTI[uti, default: []].contains(tag) : decls[uti, default: []].contains { $0.mimeTypes.first == tag }
                }
                if !preferring.isEmpty { candidates = preferring }
            }
            if candidates.count > 1 {
                let bases = candidates.filter { base in candidates.allSatisfy { $0 == base || ancestors($0).contains(base) } }
                if bases.count == 1 { candidates = bases }
            }
            let sorted = candidates.sorted()
            let areAliases = sorted.count > 1 && sorted.indices.allSatisfy { lhs in
                sorted.indices.allSatisfy { rhs in lhs == rhs || self.areAliases(sorted[lhs], sorted[rhs]) }
            }
            resolved.append(TagClaim(tag: tag, utis: sorted, claimers: claimers, areAliases: areAliases))
        }
        return (resolved, unresolved)
    }

    /// Public types name Kinds best, then actively declared ones, then the most widely claimed.
    func primaryOrder(_ utis: [String], claimers: [String: Set<String>]) -> [String] {
        utis.sorted { lhs, rhs in
            let lhsKey = (lhs.hasPrefix("public.") ? 0 : 1, decls[lhs, default: []].contains(where: \.isActive) ? 0 : 1, -(claimers[lhs]?.count ?? 0))
            let rhsKey = (rhs.hasPrefix("public.") ? 0 : 1, decls[rhs, default: []].contains(where: \.isActive) ? 0 : 1, -(claimers[rhs]?.count ?? 0))
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
