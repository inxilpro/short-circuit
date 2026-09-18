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

    struct PendingChange: Identifiable {
        var id = UUID()
        var kindID: Kind.ID
        var kindName: String
        var app: AppRef
        var targets: [KindMember.Target]
        var promptCount: Int
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
    private(set) var transientMessage: String?
    private(set) var applyingKindIDs: Set<Kind.ID> = []
    private(set) var results: [Kind.ID: [MemberResult]] = [:]
    var pendingChange: PendingChange?

    init(provider: any KindProviding, writer: any HandlerWriting) {
        self.provider = provider
        self.writer = writer
    }

    var kinds: [Kind] {
        if case .loaded(let kinds) = state { kinds } else { [] }
    }

    /// Types only one app can open offer nothing to choose, so the curated views hide them.
    var commonKinds: [Kind] {
        kinds.filter { $0.candidates.count >= 2 }
    }

    var splitKinds: [Kind] {
        kinds.filter(\.isSplit)
    }

    var categoriesWithKinds: [KindCategory] {
        let present = Set(commonKinds.map(\.category))
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
        case .category(let category): commonKinds.filter { $0.category == category }
        case .all: kinds
        case .applications: []
        }
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

    func refresh(force: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        isRefreshing = true
        if case .failed = state { state = .loading }
        defer { if generation == loadGeneration { isRefreshing = false } }

        do {
            let loaded = try await provider.loadKinds(forceRefresh: force)
            guard generation == loadGeneration else { return }
            results = [:]
            state = .loaded(loaded.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            if let selectedKindID, !loaded.contains(where: { $0.id == selectedKindID }) {
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
        applyingKindIDs.contains(kind.id)
    }

    func results(for kind: Kind) -> [MemberResult] {
        results[kind.id] ?? []
    }

    func setDefault(_ app: AppRef, for kind: Kind) {
        requestChange(app, targets: kind.members.map(\.target), in: kind)
    }

    func setDefault(_ app: AppRef, for target: KindMember.Target, in kind: Kind) {
        requestChange(app, targets: [target], in: kind)
    }

    func fixSplit(_ kind: Kind) {
        guard let majority = kind.majorityApp else { return }
        requestChange(majority, targets: kind.members.map(\.target), in: kind)
    }

    /// Every changed member costs the user a system consent prompt, so anything beyond one is
    /// confirmed first.
    private func requestChange(_ app: AppRef, targets: [KindMember.Target], in kind: Kind) {
        guard !isApplying(kind) else { return }
        let known = Dictionary(kind.members.map { ($0.target, $0.defaultApp?.url) }, uniquingKeysWith: { first, _ in first })
        let plan = WritePlan(app: app.url, targets: targets) { known[$0] ?? nil }
        guard plan.promptCount > 0 else {
            showMessage("\(kind.name) already opens with \(app.name).")
            return
        }

        let change = PendingChange(kindID: kind.id, kindName: kind.name, app: app, targets: targets, promptCount: plan.promptCount)
        if plan.promptCount > 1 {
            pendingChange = change
        } else {
            Task { await apply(change) }
        }
    }

    func confirmPendingChange() async {
        guard let change = pendingChange else { return }
        pendingChange = nil
        await apply(change)
    }

    func apply(_ change: PendingChange) async {
        guard !applyingKindIDs.contains(change.kindID) else { return }
        applyingKindIDs.insert(change.kindID)
        results[change.kindID] = nil
        defer { applyingKindIDs.remove(change.kindID) }

        let outcome = await writer.apply(app: change.app, to: change.targets)
        results[change.kindID] = outcome
        await reloadHandlers(forKindID: change.kindID)
    }

    /// Re-reads every member from the system rather than trusting the writer's outcome, since a
    /// Kind can end up partially applied.
    private func reloadHandlers(forKindID id: Kind.ID) async {
        guard var kind = kinds.first(where: { $0.id == id }) else { return }
        for memberIndex in kind.members.indices {
            kind.members[memberIndex].defaultApp = await writer.currentHandler(for: kind.members[memberIndex].target)
        }
        for app in kind.members.compactMap(\.defaultApp) where !kind.candidates.contains(where: { $0.url == app.url }) {
            kind.candidates.append(app)
        }

        // The reads above suspend, so merge into whatever is loaded now rather than a stale copy.
        guard case .loaded(var all) = state, let latestIndex = all.firstIndex(where: { $0.id == id }) else { return }
        all[latestIndex] = kind
        IconCache.invalidate(typeIdentifiers: kind.utis)
        state = .loaded(all)
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
