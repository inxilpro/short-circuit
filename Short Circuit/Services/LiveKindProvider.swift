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

        return kinds.map { kind in
            var kind = kind
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
                }
                kind.members[index].defaultApp = defaultURL.map(app)
                if let defaultURL { defaults.insert(Self.canonical(defaultURL)) }
                // Launch Services' own list for this member is the only set its setter accepts; the
                // current default always counts, since it's already assigned.
                kind.members[index].candidateURLs = Set((candidateURLs + [defaultURL].compactMap { $0 }).map(Self.canonical))
                liveCandidates.append(contentsOf: candidateURLs.map(app))
            }
            kind.candidates = Self.mergeCandidates(live: liveCandidates, explicit: kind.candidates, defaults: defaults)
            if kind.isAppPrivate {
                kind.isAppPrivate = Set(kind.candidates.map { $0.bundleID?.lowercased() ?? $0.url.path }).count <= 1
            }
            return kind
        }
    }

    /// One spelling per app bundle, so `KindMember.accepts` can compare URLs from the snapshot and from
    /// NSWorkspace, which differ in trailing slashes and `..` components.
    static func canonical(_ url: URL) -> URL {
        URL(filePath: url.standardizedFileURL.path(percentEncoded: false), directoryHint: .isDirectory)
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
