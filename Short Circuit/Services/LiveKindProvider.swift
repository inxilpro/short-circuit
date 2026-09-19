import Foundation

/// Builds Kinds from the cached Launch Services snapshot, then overlays live NSWorkspace answers for
/// defaults and candidates, since handler choices change more often than the snapshot is refreshed.
nonisolated struct LiveKindProvider: KindProviding {
    let index: LaunchServicesIndex
    let handlers: any HandlerLookup
    let builder: KindBuilder

    init(
        index: LaunchServicesIndex = LaunchServicesIndex(),
        handlers: any HandlerLookup = HandlerService(),
        builder: KindBuilder = KindBuilder(catalog: Catalog.bundled)
    ) {
        self.index = index
        self.handlers = handlers
        self.builder = builder
    }

    @concurrent
    func loadKinds(forceRefresh: Bool) async throws -> [Kind] {
        let snapshot = try await index.snapshot(forceRefresh: forceRefresh)
        return enrich(builder.build(from: snapshot))
    }

    func enrich(_ kinds: [Kind]) -> [Kind] {
        var appCache: [URL: AppRef] = [:]
        func app(_ url: URL) -> AppRef {
            let url = Self.canonical(url)
            if let cached = appCache[url] { return cached }
            var app = HandlerService.appRef(for: url)
            app.url = url
            appCache[url] = app
            return app
        }

        let extensionOwners = extensionMemberOwners(kinds)

        return kinds.indices.map { kindIndex in
            var kind = kinds[kindIndex]
            let ownedExtensions = extensionOwners.compactMap { $0.value == kindIndex ? $0.key : nil }.sorted()
            for ext in ownedExtensions where !kind.members.contains(where: { $0.target == .fileExtension(ext) }) {
                kind.members.append(KindMember(target: .fileExtension(ext), governedExtensions: [ext]))
            }
            var liveCandidates: [AppRef] = []
            var defaults: Set<URL> = []
            for index in kind.members.indices {
                let defaultURL: URL?
                let candidateURLs: [URL]
                switch kind.members[index].target {
                case .uti(let identifier):
                    defaultURL = handlers.defaultApplicationURL(forContentType: identifier)
                    candidateURLs = handlers.applicationURLs(forContentType: identifier)
                case .scheme(let scheme):
                    defaultURL = handlers.defaultApplicationURL(forScheme: scheme)
                    candidateURLs = handlers.applicationURLs(forScheme: scheme)
                case .fileExtension(let ext):
                    defaultURL = handlers.defaultApplicationURL(forFilenameExtension: ext)
                    candidateURLs = handlers.applicationURLs(forFilenameExtension: ext)
                }
                if case .uti(let identifier) = kind.members[index].target {
                    kind.members[index].governedExtensions = governedExtensions(of: identifier, in: kind)
                }
                kind.members[index].defaultApp = defaultURL.map(app)
                if let defaultURL { defaults.insert(Self.canonical(defaultURL)) }
                // Launch Services' own list for this member is the only set its setter accepts; the
                // current default always counts, since it's already assigned.
                kind.members[index].candidateURLs = Set((candidateURLs + [defaultURL].compactMap { $0 }).map(Self.canonical))
                liveCandidates.append(contentsOf: candidateURLs.map(app))
            }
            let memberUTIs = Set(kind.utis)
            let memberExtensions = Set(kind.members.compactMap { member -> String? in
                if case .fileExtension(let ext) = member.target { ext } else { nil }
            })
            kind.unclaimedExtensions = kind.extensions.filter { ext in
                !memberExtensions.contains(ext) && handlers.contentTypes(forFilenameExtension: ext).isDisjoint(with: memberUTIs)
            }
            let explicit = Set(kind.candidates.map { Self.canonical($0.url) })
            kind.candidates = Self.mergeCandidates(live: liveCandidates, explicit: kind.candidates, defaults: defaults)
            kind.explicitCandidateURLs = explicit.intersection(kind.candidates.map(\.url))
            if kind.isAppPrivate {
                kind.isAppPrivate = Set(kind.candidates.map { $0.bundleID?.lowercased() ?? $0.url.path }).count <= 1
            }
            return kind
        }
    }

    /// Picks, for every extension that resolves only to a `dyn.` type, the one Kind that gets it as a
    /// `.fileExtension` member, so two Kinds never set the same extension. Catalog Kinds go first (by
    /// Common rank, then catalog order), then heuristic Kinds in their given order. An extension that
    /// resolves to any declared type never becomes a member: setting it through a file would change
    /// that type's handler. Nor does one no app is listed for, since there'd be nothing to choose.
    private func extensionMemberOwners(_ kinds: [Kind]) -> [String: Int] {
        let priority = kinds.indices.sorted { lhs, rhs in
            let lhsKey = (kinds[lhs].catalogID == nil ? 1 : 0, kinds[lhs].commonRank ?? Int.max, lhs)
            let rhsKey = (kinds[rhs].catalogID == nil ? 1 : 0, kinds[rhs].commonRank ?? Int.max, rhs)
            return lhsKey < rhsKey
        }
        var owners: [String: Int] = [:]
        var resolution: [String: Bool] = [:]
        for index in priority where !kinds[index].utis.isEmpty {
            for ext in kinds[index].extensions where owners[ext] == nil {
                let eligible = resolution[ext]
                    ?? (handlers.contentTypes(forFilenameExtension: ext).isEmpty && !handlers.applicationURLs(forFilenameExtension: ext).isEmpty)
                resolution[ext] = eligible
                if eligible { owners[ext] = index }
            }
        }
        return owners
    }

    /// Extensions, from the type's own tags and the Kind's list, that macOS resolves to exactly this
    /// type. Several types can declare `.docx`; only the winner's handler opens the file.
    /// Nil for a type with no extensions to win at all, so it isn't mistaken for a shadowed one.
    private func governedExtensions(of identifier: String, in kind: Kind) -> [String]? {
        var seen: Set<String> = []
        let candidates = (handlers.declaredExtensions(forContentType: identifier) + kind.extensions)
            .map { $0.lowercased() }
            .filter { seen.insert($0).inserted }
        guard !candidates.isEmpty else { return nil }
        return candidates.filter { handlers.contentTypes(forFilenameExtension: $0).contains(identifier) }
    }

    /// One spelling per app bundle, so `KindMember.accepts` can compare URLs from the snapshot and from
    /// NSWorkspace, which differ in trailing slashes and `..` components.
    static func canonical(_ url: URL) -> URL {
        AppIdentity.canonical(url)
    }

    /// Unique by standardized URL, so two installs sharing a bundle ID both stay. Ordered by relevance:
    /// current defaults, then apps that explicitly claim a member (the builder's list), then apps Launch
    /// Services only offers through broad conformance; alphabetical within each tier. Apps that no longer
    /// exist on disk are dropped.
    static func mergeCandidates(live: [AppRef], explicit: [AppRef], defaults: Set<URL>) -> [AppRef] {
        let defaults = Set(defaults.map(canonical))
        let explicitURLs = Set(explicit.map { canonical($0.url) })
        var chosen: [URL: AppRef] = [:]
        for var app in explicit + live {
            let url = canonical(app.url)
            guard chosen[url] == nil, FileManager.default.fileExists(atPath: url.path) else { continue }
            app.url = url
            chosen[url] = app
        }
        func tier(_ app: AppRef) -> Int {
            let url = app.url
            if defaults.contains(url) { return 0 }
            return explicitURLs.contains(url) ? 1 : 2
        }
        return chosen.values.sorted { lhs, rhs in
            let lhsTier = tier(lhs)
            let rhsTier = tier(rhs)
            if lhsTier != rhsTier { return lhsTier < rhsTier }
            return KindBuilder.alphabetical(lhs, rhs)
        }
    }
}
