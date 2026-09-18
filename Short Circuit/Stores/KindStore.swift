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
        var appName: String
        var plan: WritePlan
        /// Set when the system changed after an earlier approval and this plan replaces it.
        var isRevised = false
    }

    enum WriteActivity: Equatable {
        case idle
        case planning(Kind.ID)
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
    private(set) var transientMessage: String?
    /// One app-wide gate: consent prompts from two batches must never interleave, and a batch's
    /// live reads are only valid while nothing else is writing.
    private(set) var activity: WriteActivity = .idle
    private(set) var results: [Kind.ID: [MemberResult]] = [:]
    private var splitSnapshotIDs: Set<Kind.ID> = []
    private var writeGeneration = 0
    private var verifiedHandlers: [KindMember.Target: AppRef?] = [:]
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

    var isWriting: Bool { activity != .idle }

    var canWrite: Bool { activity == .idle && !isRefreshing && pendingChange == nil }

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
        activity == .applying(kind.id) || activity == .planning(kind.id)
    }

    func results(for kind: Kind) -> [MemberResult] {
        results[kind.id] ?? []
    }

    /// Unsettable members are left out of every plan: macOS refuses them without a prompt, and
    /// no file resolves to them, so a call could only fail.
    func setDefault(_ app: AppRef, for kind: Kind) async {
        await requestChange(app, targets: kind.settableMembers.map(\.target), in: kind)
    }

    func setDefault(_ app: AppRef, for target: KindMember.Target, in kind: Kind) async {
        guard kind.settableMembers.contains(where: { $0.target == target }) else { return }
        await requestChange(app, targets: [target], in: kind)
    }

    func fixSplit(_ kind: Kind) async {
        guard let majority = kind.majorityApp else { return }
        await requestChange(majority, targets: kind.settableMembers.map(\.target), in: kind)
    }

    /// Plans from live reads, not the displayed Kind, so the confirmation describes what will
    /// actually run. Several prompts, or anything touching the browser role, is confirmed first.
    private func requestChange(_ app: AppRef, targets: [KindMember.Target], in kind: Kind) async {
        guard canWrite else {
            showMessage("Another change is still in progress.")
            return
        }
        activity = .planning(kind.id)
        let plan = await writer.plan(app: app, targets: targets)
        activity = .idle

        let change = PendingChange(kindID: kind.id, kindName: kind.name, appName: AppLabels(kind.candidates + kind.members.compactMap(\.defaultApp) + [app]).label(for: app), plan: plan)
        guard plan.promptCount > 0 else {
            await settleWithoutChanges(change)
            return
        }
        if plan.promptCount > 1 || plan.changesBrowser {
            pendingChange = change
        } else {
            await run(change)
        }
    }

    /// Takes the change the dialog showed rather than reading `pendingChange`: SwiftUI dismisses
    /// a confirmation dialog, which clears `pendingChange` through its binding, before the
    /// button's task gets to run.
    func confirm(_ change: PendingChange) async {
        if let pending = pendingChange, pending.id != change.id { return }
        pendingChange = nil
        await run(change)
    }

    func cancelPendingChange() {
        pendingChange = nil
    }

    private func run(_ change: PendingChange) async {
        guard activity == .idle, !isRefreshing else { return }
        activity = .applying(change.kindID)
        results[change.kindID] = nil
        defer { activity = .idle }

        switch await writer.execute(change.plan) {
        case .completed(let outcome):
            results[change.kindID] = outcome
            await reloadHandlers(for: change.plan.requested + change.plan.affectedTargets)
        case .needsApproval(let fresh):
            var revised = change
            revised.id = UUID()
            revised.plan = fresh
            revised.isRevised = true
            if fresh.promptCount == 0 {
                await settleWithoutChanges(revised)
            } else {
                pendingChange = revised
            }
        }
    }

    private func settleWithoutChanges(_ change: PendingChange) async {
        showMessage("\(change.kindName) already opens with \(change.appName).")
        await reloadHandlers(for: change.plan.requested)
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
