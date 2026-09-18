import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case split
    case common
    case category(KindCategory)
    case all
    case applications
}

enum BrowserLayout: String, CaseIterable, Identifiable {
    case grid, list

    var id: Self { self }
}

@Observable
final class KindStore {
    enum LoadState {
        case loading
        case loaded([Kind])
        case failed(String)
    }

    enum WriteActivity: Equatable {
        case idle
        case applying(Kind.ID)
    }

    private let provider: any KindProviding
    let writer: any HandlerWriting
    private var loadGeneration = 0
    private var messageTask: Task<Void, Never>?

    private(set) var state: LoadState = .loading
    private(set) var isRefreshing = false
    var searchText = ""
    var sidebarSelection: SidebarItem? = .common
    var selectedKindID: Kind.ID?
    var layout: BrowserLayout = .grid
    var isInspectorPresented = true
    var showsShadowedMembers = false
    private(set) var transientMessage: String?
    /// One app-wide gate: consent prompts from two batches must never interleave, and a batch's
    /// live reads are only valid while nothing else is writing.
    private(set) var activity: WriteActivity = .idle
    private(set) var results: [Kind.ID: [MemberResult]] = [:]
    private var splitSnapshotIDs: Set<Kind.ID> = []
    private var writeGeneration = 0
    private var verifiedHandlers: [KindMember.Target: AppRef?] = [:]
    /// The setter call currently waiting on a macOS consent prompt, if any.
    private(set) var progress: WriteProgress?

    init(provider: any KindProviding, writer: any HandlerWriting) {
        self.provider = provider
        self.writer = writer
    }

    var kinds: [Kind] {
        if case .loaded(let kinds) = state { kinds } else { [] }
    }

    /// The catalog's curated list, in its own order, regardless of how many apps are installed.
    var commonKinds: [Kind] {
        kinds.filter(\.isCommon).sorted(by: Self.catalogOrder)
    }

    /// Types only one app can open offer nothing to choose, so the category views hide them.
    var choosableKinds: [Kind] {
        kinds.filter { $0.candidates.count >= 2 }
    }

    /// Kinds that were split at the last load or explicit refresh, plus any that became split
    /// since. Fixed ones stay listed for the session so progress stays visible.
    var splitKinds: [Kind] {
        kinds.filter { splitSnapshotIDs.contains($0.id) || $0.isSplit }
    }

    var unresolvedSplitCount: Int {
        kinds.filter(\.isSplit).count
    }

    var resolvedSplitIDs: Set<Kind.ID> {
        Set(kinds.filter { splitSnapshotIDs.contains($0.id) && !$0.isSplit }.map(\.id))
    }

    var categoriesWithKinds: [KindCategory] {
        let present = Set(choosableKinds.map(\.category))
        return KindCategory.allCases.filter(present.contains)
    }

    /// Only a Kind the user can currently see, so the inspector never describes a hidden tile.
    var selectedKind: Kind? {
        guard let selectedKindID else { return nil }
        return visibleKinds.first { $0.id == selectedKindID }
    }

    func kinds(in item: SidebarItem?) -> [Kind] {
        switch item {
        case .split: splitKinds
        case .common, nil: commonKinds
        case .category(let category): choosableKinds.filter { $0.category == category }.sorted(by: Self.catalogOrder)
        case .all: kinds
        case .applications: []
        }
    }

    /// Curated Kinds first (ranked, then the rest of the catalog), then heuristic ones, each
    /// alphabetical within its tier, so familiar formats lead over obscure ones.
    static func catalogOrder(_ lhs: Kind, _ rhs: Kind) -> Bool {
        func tier(_ kind: Kind) -> Int {
            kind.isCommon ? 0 : kind.catalogID != nil ? 1 : 2
        }
        if tier(lhs) != tier(rhs) { return tier(lhs) < tier(rhs) }
        if let left = lhs.commonRank, let right = rhs.commonRank, left != right { return left < right }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    var scopedKinds: [Kind] {
        kinds(in: sidebarSelection)
    }

    var visibleKinds: [Kind] {
        KindSearch(searchText).filter(scopedKinds)
    }

    var hiddenMatchesInAllTypes: Int {
        guard sidebarSelection != .all, !KindSearch(searchText).isEmpty else { return 0 }
        return KindSearch(searchText).filter(kinds).count - visibleKinds.count
    }

    var isWriting: Bool { activity != .idle }

    var canWrite: Bool { activity == .idle && !isRefreshing }

    func refresh(force: Bool = false) async {
        // A refresh started mid-write would read handlers from before the change and overwrite
        // the verified result.
        guard !isWriting else {
            showMessage("Wait for the current change to finish before refreshing.")
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        let startingWriteGeneration = writeGeneration
        isRefreshing = true
        if case .failed = state { state = .loading }
        defer { if generation == loadGeneration { isRefreshing = false } }

        do {
            var loaded = try await provider.loadKinds(forceRefresh: force)
            guard generation == loadGeneration else { return }
            if writeGeneration != startingWriteGeneration {
                loaded = Self.overlay(verifiedHandlers, onto: loaded)
            }
            state = .loaded(loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            splitSnapshotIDs = Set(loaded.filter(\.isSplit).map(\.id))
            let ids = Set(loaded.map(\.id))
            results = results.filter { ids.contains($0.key) }
            if let selectedKindID, !ids.contains(selectedKindID) {
                self.selectedKindID = nil
            }
        } catch {
            guard generation == loadGeneration else { return }
            // Keep showing stale data on a failed refresh rather than blanking the window.
            if kinds.isEmpty {
                state = .failed(error.localizedDescription)
            } else {
                showMessage("Refresh failed: \(error.localizedDescription)")
            }
        }
    }

    func revealKind(forFileAt url: URL) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)

        guard let kind = KindMatcher(kinds: kinds).bestMatch(for: type, fileExtension: url.pathExtension) else {
            let description = type?.localizedDescription ?? url.pathExtension
            showMessage("No type matches “\(url.lastPathComponent)”" + (description.isEmpty ? "" : " (\(description))"))
            return
        }

        if !KindSearch(searchText).matches(kind) {
            searchText = ""
        }
        if !scopedKinds.contains(where: { $0.id == kind.id }) {
            sidebarSelection = kinds(in: .common).contains(where: { $0.id == kind.id }) ? .common : .all
        }
        selectedKindID = kind.id
        isInspectorPresented = true
    }

    func isApplying(_ kind: Kind) -> Bool {
        activity == .applying(kind.id)
    }

    func results(for kind: Kind) -> [MemberResult] {
        results[kind.id] ?? []
    }

    /// Unsettable members are left out of every plan: macOS refuses them without a prompt, and
    /// no file resolves to them, so a call could only fail.
    /// Covers only the members whose handlers decide what opens; shadowed members would cost a
    /// prompt each and change nothing a user could notice. They change through their own menu.
    func setDefault(_ app: AppRef, for kind: Kind) async {
        await requestChange(app, members: kind.effectiveMembers, in: kind)
    }

    func setDefault(_ app: AppRef, for target: KindMember.Target, in kind: Kind) async {
        guard let member = kind.settableMembers.first(where: { $0.target == target }) else { return }
        await requestChange(app, members: [member], in: kind)
    }

    func fixSplit(_ kind: Kind) async {
        guard let app = kind.fixSplitApp else { return }
        await requestChange(app, members: kind.effectiveMembers, in: kind)
    }

    /// Applies straight away: macOS asks the user to confirm every handler change itself, so an
    /// app-level confirmation only doubled the questions. The writer plans from live reads, not
    /// the displayed Kind, immediately before it runs.
    ///
    /// macOS only accepts an app it lists for that exact type (anything else fails with error 256
    /// and no prompt), so members that don't list the app are reported as not supported instead
    /// of being attempted.
    private func requestChange(_ app: AppRef, members: [KindMember], in kind: Kind) async {
        guard canWrite else {
            showMessage("Another change is still in progress.")
            return
        }
        activity = .applying(kind.id)
        results[kind.id] = nil
        defer {
            activity = .idle
            progress = nil
        }

        let supported = members.filter { kind.member($0, accepts: app) }
        let unsupported = members.filter { !kind.member($0, accepts: app) }
        let targets = supported.map(\.target)
        let appName = AppLabels(kind.candidates + kind.members.compactMap(\.defaultApp) + [app]).label(for: app)

        let applied = targets.isEmpty ? [] : await writer.apply(app: app, targets: targets) { [weak self] step in
            self?.progress = step
        }
        let skippedAsUnsupported = unsupported.map {
            MemberResult(target: $0.target, outcome: .skipped(.notSupported(app)), handlerAfter: $0.defaultApp)
        }
        let outcome = applied + skippedAsUnsupported

        if supported.isEmpty {
            showMessage("\(appName) can’t open \(members.count == 1 ? "this type" : "any of these types").")
        } else if outcome.allSatisfy({ $0.outcome == .skipped(.alreadyDefault) }) {
            showMessage("\(kind.name) already opens with \(appName).")
        } else {
            results[kind.id] = outcome
        }
        await reloadHandlers(for: members.map(\.target) + applied.map(\.target))
    }

    /// Re-reads handlers from the system rather than trusting the writer's outcome, since a Kind
    /// can end up partially applied, and patches them by target into every Kind that has them.
    private func reloadHandlers(for targets: [KindMember.Target]) async {
        var read: [KindMember.Target: AppRef?] = [:]
        for target in targets where read[target] == nil {
            read[target] = await writer.currentHandler(for: target)
        }
        writeGeneration += 1
        verifiedHandlers.merge(read) { _, new in new }

        // The reads above suspend, so merge into whatever is loaded now rather than a stale copy.
        guard case .loaded(let all) = state else { return }
        let merged = Self.overlay(read, onto: all)
        splitSnapshotIDs.formUnion(merged.filter(\.isSplit).map(\.id))
        for kind in merged where kind.members.contains(where: { read[$0.target] != nil }) {
            IconCache.invalidate(typeIdentifiers: kind.utis)
        }
        state = .loaded(merged)
    }

    private static func overlay(_ handlers: [KindMember.Target: AppRef?], onto kinds: [Kind]) -> [Kind] {
        kinds.map { kind in
            var kind = kind
            for index in kind.members.indices {
                guard let handler = handlers[kind.members[index].target] else { continue }
                kind.members[index].defaultApp = handler
                if let handler, !kind.candidates.contains(where: { $0.url == handler.url }) {
                    kind.candidates.append(handler)
                }
            }
            return kind
        }
    }

    func showMessage(_ message: String) {
        transientMessage = message
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}

struct KindSearch {
    private enum Mode {
        case any(String)
        case fileExtension(String)
        case scheme(String)
    }

    private let mode: Mode?

    init(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            mode = nil
        } else if query.hasPrefix("."), query.count > 1 {
            mode = .fileExtension(String(query.dropFirst()))
        } else if let range = query.range(of: ":"), range.lowerBound != query.startIndex {
            mode = .scheme(String(query[..<range.lowerBound]))
        } else {
            mode = .any(query)
        }
    }

    var isEmpty: Bool { mode == nil }

    func filter(_ kinds: [Kind]) -> [Kind] {
        isEmpty ? kinds : kinds.filter(matches)
    }

    func matches(_ kind: Kind) -> Bool {
        switch mode {
        case nil:
            true
        case .fileExtension(let ext):
            kind.extensions.contains { $0.lowercased().hasPrefix(ext) }
        case .scheme(let scheme):
            kind.schemes.contains { $0.lowercased().hasPrefix(scheme) }
        case .any(let query):
            kind.name.lowercased().contains(query)
                || kind.extensions.contains { $0.lowercased().hasPrefix(query) }
                || kind.mimeTypes.contains { $0.lowercased().contains(query) }
                || kind.utis.contains { $0.lowercased().contains(query) }
                || kind.schemes.contains { $0.lowercased().hasPrefix(query) }
                || kind.keywords.contains { $0.lowercased().contains(query) }
        }
    }
}

struct KindMatcher {
    let kinds: [Kind]

    func bestMatch(for type: UTType?, fileExtension: String) -> Kind? {
        if let type, let exact = kinds.first(where: { $0.utis.contains(type.identifier) }) {
            return exact
        }

        let ext = fileExtension.lowercased()
        if !ext.isEmpty, let byExtension = kinds.first(where: { $0.extensions.contains { $0.lowercased() == ext } }) {
            return byExtension
        }

        guard let type else { return nil }
        // Prefer the most specific conforming type, otherwise every text file lands on whatever
        // Kind happens to include public.plain-text.
        return kinds
            .compactMap { kind -> (Kind, Int)? in
                let depths = kind.utis
                    .compactMap { UTType($0) }
                    .filter { type.conforms(to: $0) && !Self.tooGeneric.contains($0) }
                    .map { $0.supertypes.count }
                return depths.max().map { (kind, $0) }
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static let tooGeneric: Set<UTType> = [.item, .content, .data, .compositeContent]
}
