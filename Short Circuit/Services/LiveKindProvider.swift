import Foundation

/// Builds Kinds from the cached Launch Services snapshot, then overlays live NSWorkspace answers for
/// defaults and candidates, since handler choices change more often than the snapshot is refreshed.
nonisolated struct LiveKindProvider: KindProviding {
    let index: LaunchServicesIndex
    let handlers: HandlerService
    let builder: KindBuilder

    init(index: LaunchServicesIndex = LaunchServicesIndex(), handlers: HandlerService = HandlerService(), builder: KindBuilder = KindBuilder()) {
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
            if let cached = appCache[url] { return cached }
            let app = HandlerService.appRef(for: url)
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
                if let defaultURL { defaults.insert(defaultURL.standardizedFileURL) }
                liveCandidates.append(contentsOf: candidateURLs.map(app))
            }
            kind.candidates = Self.mergeCandidates(live: liveCandidates, snapshot: kind.candidates, defaults: defaults)
            return kind
        }
    }

    /// One entry per bundle ID. A copy that is currently a default wins, then whatever Launch Services
    /// listed first, then the snapshot's pick. Apps that no longer exist on disk are dropped.
    static func mergeCandidates(live: [AppRef], snapshot: [AppRef], defaults: Set<URL>) -> [AppRef] {
        var chosen: [String: AppRef] = [:]
        for app in live + snapshot {
            guard FileManager.default.fileExists(atPath: app.url.path) else { continue }
            let key = app.bundleID?.lowercased() ?? app.url.standardizedFileURL.path
            if let existing = chosen[key] {
                if !defaults.contains(existing.url.standardizedFileURL), defaults.contains(app.url.standardizedFileURL) {
                    chosen[key] = app
                }
                continue
            }
            chosen[key] = app
        }
        return chosen.values
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
