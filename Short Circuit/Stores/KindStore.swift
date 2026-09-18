import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case split
    case common
    case category(KindCategory)
    case all
    case applications

    /// How the last-used section is remembered between launches.
    var storageKey: String {
        switch self {
        case .split: "split"
        case .common: "common"
        case .category(let category): "category.\(category.rawValue)"
        case .all: "all"
        case .applications: "applications"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "split": self = .split
        case "common": self = .common
        case "all": self = .all
        case "applications": self = .applications
        default:
            guard storageKey.hasPrefix("category."),
                  let category = KindCategory(rawValue: String(storageKey.dropFirst("category.".count)))
            else { return nil }
            self = .category(category)
        }
    }
}

enum BrowserLayout: String, CaseIterable, Identifiable {
    case grid, list

    var id: Self { self }
}

/// What an "Other…" app choice will be applied to once the user picks an app.
enum AppChoiceTarget: Equatable {
    case kind(Kind.ID)
    case member(Kind.ID, KindMember.Target)

    var kindID: Kind.ID {
        switch self {
        case .kind(let id), .member(let id, _): id
        }
    }
}

/// A status line under the window. Failures stay until dismissed, so they can't be missed.
struct StatusMessage: Equatable {
    var text: String
    var isFailure = false
}

/// The view choices that are remembered between launches.
enum PreferenceKey {
    static let layout = "browserLayout"
    static let sidebar = "sidebarSelection"
    static let inspector = "inspectorPresented"
    static let shadowedMembers = "showsShadowedMembers"
    static let appFolder = "lastAppFolder"
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
        case applyingBatch
        /// Restoring previous apps for an Undo; the Kinds involved show progress like a change.
        case undoing([Kind.ID])
    }

    /// A "Make default for…" run from the Applications view.
    struct BatchRun {
        var app: AppRef
        var kindIDs: [Kind.ID]
        /// From the plan shown before Apply; live planning can make or skip a few more calls.
        var plannedChanges: Int
        var changesStarted = 0
        var currentKindID: Kind.ID?
        var stopRequested = false
        var isRunning = true
        var finishedKindIDs: [Kind.ID] = []
        var notStartedKindIDs: [Kind.ID] = []

        var currentKindName: String?
    }

    private let provider: any KindProviding
    let writer: any HandlerWriting
    private var loadGeneration = 0
    private var messageTask: Task<Void, Never>?

    private(set) var state: LoadState = .loading {
        didSet { appIndexCache = nil }
    }
    private(set) var isRefreshing = false
    var searchText = ""
    var sidebarSelection: SidebarItem? = .common {
        didSet { defaults?.set(sidebarSelection?.storageKey, forKey: PreferenceKey.sidebar) }
    }
    var selectedKindID: Kind.ID?
    var layout: BrowserLayout = .grid {
        didSet { defaults?.set(layout.rawValue, forKey: PreferenceKey.layout) }
    }
    var isInspectorPresented = true {
        didSet { defaults?.set(isInspectorPresented, forKey: PreferenceKey.inspector) }
    }
    var showsShadowedMembers = false {
        didSet { defaults?.set(showsShadowedMembers, forKey: PreferenceKey.shadowedMembers) }
    }
    private(set) var message: StatusMessage?
    /// Set while the "Other…" app sheet is up; cleared when it completes or is cancelled.
    private(set) var pendingAppChoice: AppChoiceTarget?
    /// Where "Other…" opened last: apps outside /Applications are the reason it exists.
    private(set) var lastAppFolder: URL? {
        didSet { defaults?.set(lastAppFolder?.path(percentEncoded: false), forKey: PreferenceKey.appFolder) }
    }
    var isChoosingFileToIdentify = false
    /// Bumped to ask the window to move focus to the search field.
    private(set) var searchFocusRequests = 0
    @ObservationIgnored private let defaults: UserDefaults?
    /// Where views keep their own remembered state (table columns), matching the store's.
    var preferences: UserDefaults? { defaults }
    /// The window's undo manager, set by the window. Changes register their reversal here.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The restore an Undo started, so tests (and nothing else) can wait for it.
    @ObservationIgnored private(set) var undoTask: Task<Void, Never>?
    /// One app-wide gate: consent prompts from two batches must never interleave, and a batch's
    /// live reads are only valid while nothing else is writing.
    private(set) var activity: WriteActivity = .idle
    private(set) var results: [Kind.ID: [MemberResult]] = [:]
    private var splitSnapshotIDs: Set<Kind.ID> = []
    /// Split at the last load or explicit refresh. Only these can be shown as Resolved: a Kind
    /// that split during the session and was put back is simply back where it started.
    private var sessionStartSplitIDs: Set<Kind.ID> = []
    private var writeGeneration = 0
    private var verifiedHandlers: [KindMember.Target: AppRef?] = [:]
    /// The setter call currently waiting on a macOS consent prompt, if any.
    private(set) var progress: WriteProgress?

    // Applications view
    private(set) var selectedAppURL: URL?
    var batchSelection: Set<Kind.ID> = []
    private(set) var batchRun: BatchRun?
    var showsOtherApps = false
    var showsOfferedKinds = false
    @ObservationIgnored private var appIndexCache: AppIndex?

    /// `defaults` remembers the view between launches; nil (tests, previews) remembers nothing.
    init(provider: any KindProviding, writer: any HandlerWriting, defaults: UserDefaults? = nil) {
        self.provider = provider
        self.writer = writer
        self.defaults = defaults
        guard let defaults else { return }
        if let raw = defaults.string(forKey: PreferenceKey.layout), let layout = BrowserLayout(rawValue: raw) {
            self.layout = layout
        }
        if let raw = defaults.string(forKey: PreferenceKey.sidebar), let item = SidebarItem(storageKey: raw) {
            sidebarSelection = item
        }
        if defaults.object(forKey: PreferenceKey.inspector) != nil {
            isInspectorPresented = defaults.bool(forKey: PreferenceKey.inspector)
        }
        showsShadowedMembers = defaults.bool(forKey: PreferenceKey.shadowedMembers)
        lastAppFolder = defaults.string(forKey: PreferenceKey.appFolder).map { URL(filePath: $0, directoryHint: .isDirectory) }
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
        kinds.filter { ($0.isSplit || splitSnapshotIDs.contains($0.id)) && !$0.isMixedWithoutFix }
    }

    /// Shown under the fixable splits: their members differ, but no single app takes them all.
    var mixedWithoutFixKinds: [Kind] {
        kinds.filter(\.isMixedWithoutFix)
    }

    var unresolvedSplitCount: Int {
        kinds.filter(\.isSplit).count
    }

    var resolvedSplitIDs: Set<Kind.ID> {
        Set(kinds.filter { sessionStartSplitIDs.contains($0.id) && !$0.hasMixedHandlers }.map(\.id))
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
        case .split: splitKinds + mixedWithoutFixKinds
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
            sessionStartSplitIDs = splitSnapshotIDs
            let ids = Set(loaded.map(\.id))
            results = results.filter { ids.contains($0.key) }
            if let selectedKindID, !ids.contains(selectedKindID) {
                self.selectedKindID = nil
            }
            // A remembered category can empty out when apps are removed, and its sidebar row
            // disappears with it.
            if case .category(let category) = sidebarSelection, !categoriesWithKinds.contains(category) {
                sidebarSelection = .common
            }
        } catch {
            guard generation == loadGeneration else { return }
            // Keep showing stale data on a failed refresh rather than blanking the window.
            if kinds.isEmpty {
                state = .failed(error.localizedDescription)
            } else {
                showMessage("Refresh failed: \(error.localizedDescription)", isFailure: true)
            }
        }
    }

    var appIndex: AppIndex {
        if let appIndexCache { return appIndexCache }
        let index = AppIndex(kinds: kinds)
        appIndexCache = index
        return index
    }

    var selectedApp: AppRef? {
        guard let selectedAppURL else { return nil }
        return appIndex.summaries.first { $0.app.url == selectedAppURL }?.app
    }

    /// Selecting an app pre-checks only its "Partly default" Kinds: finishing a half-made choice
    /// is the likely intent, while taking over formats is a decision to make row by row.
    func selectApp(_ url: URL?) {
        guard url != selectedAppURL else { return }
        selectedAppURL = url
        if batchRun?.isRunning != true { batchRun = nil }
        batchSelection = url.map { Set(kindIDs(for: $0, relation: .partlyDefault)) } ?? []
    }

    func kindIDs(for app: URL, relation: AppKindRelation) -> [Kind.ID] {
        appIndex.relations(for: app).filter { $0.relation == relation }.map(\.kindID)
    }

    func kinds(for app: URL, relation: AppKindRelation) -> [Kind] {
        let ids = Set(kindIDs(for: app, relation: relation))
        return kinds.filter { ids.contains($0.id) }.sorted(by: Self.catalogOrder)
    }

    var batchPlan: AppBatchPlan? {
        guard let app = selectedApp else { return nil }
        return AppBatchPlan(app: app, kinds: kinds.filter { batchSelection.contains($0.id) }.sorted(by: Self.catalogOrder))
    }

    /// Runs the checked Kinds one after another through the same one-at-a-time writer as the
    /// inspector. Stop takes effect before the next consent prompt, never mid-prompt.
    func applyBatch() async {
        guard canWrite, let plan = batchPlan, !plan.items.isEmpty else { return }
        let app = plan.app
        activity = .applyingBatch
        batchRun = BatchRun(app: app, kindIDs: plan.items.map(\.id), plannedChanges: plan.promptCount)
        defer {
            activity = .idle
            progress = nil
            batchRun?.isRunning = false
            batchRun?.currentKindID = nil
        }

        var restores: [UndoRecord.Restore] = []
        var touchedKindIDs: [Kind.ID] = []
        defer {
            let count = touchedKindIDs.count
            registerUndo(UndoRecord(
                actionName: count == 1
                    ? "Make \(app.name) the Default for 1 Type"
                    : "Make \(app.name) the Default for \(count) Types",
                restores: restores,
                kindIDs: touchedKindIDs
            ))
        }

        for item in plan.items {
            if batchRun?.stopRequested == true {
                batchRun?.notStartedKindIDs.append(item.id)
                continue
            }
            // Handlers may have moved since the checklist was drawn; plan from what's loaded now.
            let kind = kinds.first { $0.id == item.id } ?? item.kind
            batchRun?.currentKindID = kind.id
            batchRun?.currentKindName = kind.name
            results[kind.id] = nil

            let (supported, unsupported) = kind.eligibility(of: kind.effectiveMembers, for: app)
            let before = await currentHandlers(for: supported.map(\.target))
            let base = batchRun?.changesStarted ?? 0
            let applied = supported.isEmpty ? [] : await writer.apply(app: app, targets: supported.map(\.target)) { [weak self] step in
                guard let self, self.batchRun?.stopRequested != true else { return false }
                self.batchRun?.changesStarted = base + step.step
                self.progress = step
                return true
            }
            results[kind.id] = Self.finalResults(applied: applied, unsupported: unsupported, app: app)
            let kindRestores = Self.restores(for: applied, before: before, app: app)
            if !kindRestores.isEmpty {
                restores += kindRestores
                touchedKindIDs.append(kind.id)
            }
            await reloadHandlers(for: kind.members.map(\.target) + applied.map(\.target))
            batchRun?.finishedKindIDs.append(kind.id)
        }
    }

    func stopBatch() {
        batchRun?.stopRequested = true
    }

    /// Leaves whatever view is showing and selects the Kind in the browser.
    func showKind(_ id: Kind.ID) {
        guard let kind = kinds.first(where: { $0.id == id }) else { return }
        searchText = ""
        sidebarSelection = commonKinds.contains(where: { $0.id == id }) ? .common : .all
        selectedKindID = kind.id
        isInspectorPresented = true
    }

    /// A dropped app can't be a file to identify; it's someone reaching for "make this the
    /// default", so point them at where that works instead of saying no type matches.
    func handleDrop(of url: URL, ignoredCount: Int = 0) {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard type?.conforms(to: .application) == true else {
            revealKind(forFileAt: url, ignoredCount: ignoredCount)
            return
        }
        if sidebarSelection == .applications {
            let canonical = AppIdentity.canonical(url)
            if let summary = appIndex.summaries.first(where: { AppIdentity.canonical($0.app.url) == canonical }) {
                selectApp(summary.app.url)
                return
            }
            showMessage("\(url.deletingPathExtension().lastPathComponent) doesn’t open any of the listed types.")
            return
        }
        showMessage("To make an app the default, drop it on “Opens With” in the inspector, or on one identifier.")
    }

    /// `ignoredCount` is how many other files were dropped along with this one; only one type
    /// can be shown, so the rest are mentioned rather than silently dropped.
    func revealKind(forFileAt url: URL, ignoredCount: Int = 0) {
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
        if ignoredCount > 0 {
            showMessage("Showing the type of “\(url.lastPathComponent)”. Drop one file at a time to see each type.")
        }
    }

    func isApplying(_ kind: Kind) -> Bool {
        switch activity {
        case .idle: false
        case .applying(let id): id == kind.id
        case .applyingBatch: batchRun?.currentKindID == kind.id
        case .undoing(let ids): ids.contains(kind.id)
        }
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
        guard !members.isEmpty else {
            showMessage("Files with \(kind.name)’s extensions open according to other types, so there’s nothing to set for it as a whole. Set its identifiers one by one in the inspector.")
            return
        }
        activity = .applying(kind.id)
        results[kind.id] = nil
        defer {
            activity = .idle
            progress = nil
        }

        let (supported, unsupported) = kind.eligibility(of: members, for: app)
        let targets = supported.map(\.target)
        let appName = AppLabels(kind.candidates + kind.members.compactMap(\.defaultApp) + [app]).label(for: app)
        let before = await currentHandlers(for: targets)

        let applied = targets.isEmpty ? [] : await writer.apply(app: app, targets: targets) { [weak self] step in
            self?.progress = step
            return true
        }
        let outcome = Self.finalResults(applied: applied, unsupported: unsupported, app: app)

        if supported.isEmpty {
            showMessage("\(appName) can’t open \(members.count == 1 ? "this type" : "any of these types").", isFailure: true)
        } else if outcome.allSatisfy({ $0.outcome == .skipped(.alreadyDefault) }) {
            showMessage("\(kind.name) already opens with \(appName).")
        } else {
            results[kind.id] = outcome
        }
        await reloadHandlers(for: members.map(\.target) + applied.map(\.target))
        registerUndo(UndoRecord(
            actionName: members.count == 1 && kind.members.count > 1
                ? "Set Default App for \(members[0].target.displayName)"
                : "Set Default App for “\(kind.name)”",
            restores: Self.restores(for: applied, before: before, app: app),
            kindIDs: [kind.id]
        ))
    }

    // MARK: Undo

    /// How to put back what a change moved: each changed target and the app it had before.
    struct UndoRecord {
        struct Restore: Equatable {
            var target: KindMember.Target
            var app: AppRef
        }

        var actionName: String
        var restores: [Restore]
        var kindIDs: [Kind.ID]
    }

    /// Live reads, not the displayed Kind: the undo has to restore what macOS actually had. The
    /// browser role is read whole, since one `http` call moves all of it.
    private func currentHandlers(for targets: [KindMember.Target]) async -> [KindMember.Target: AppRef] {
        var read: [KindMember.Target: AppRef] = [:]
        let all = targets.contains(where: WritePlan.browserRole.contains) ? targets + WritePlan.browserTargets : targets
        for target in all where read[target] == nil {
            if let app = await writer.currentHandler(for: target) { read[target] = app }
        }
        return read
    }

    /// Targets that changed and had a different app before. A type that had no default can't be
    /// given "no default" back, so it's left out. The browser role goes back through one `http`
    /// restore, since https and HTML follow it; restoring them one by one would re-run the
    /// browser change with whichever app happened to be listed for them.
    static func restores(for applied: [MemberResult], before: [KindMember.Target: AppRef], app: AppRef) -> [UndoRecord.Restore] {
        var restores: [UndoRecord.Restore] = []
        var browserRestored = false
        for result in applied where result.outcome == .changed {
            if WritePlan.browserRole.contains(result.target) {
                guard !browserRestored else { continue }
                browserRestored = true
                let previous = before[WritePlan.browserCall] ?? before[result.target]
                if let previous, !AppIdentity.same(previous.url, app.url) {
                    restores.append(.init(target: WritePlan.browserCall, app: previous))
                }
            } else if let previous = before[result.target], !AppIdentity.same(previous.url, app.url) {
                restores.append(.init(target: result.target, app: previous))
            }
        }
        return restores
    }

    private func registerUndo(_ record: UndoRecord) {
        guard let undoManager, !record.restores.isEmpty else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { store in
            store.undoTask = Task { await store.performUndo(record) }
        }
        undoManager.setActionName(record.actionName)
        undoManager.endUndoGrouping()
    }

    /// Restores each changed target through the same writer, so macOS asks again for every
    /// change, exactly as it did the first time. A declined prompt stops the rest: the user just
    /// said no, and carrying on would ask again for the same intent.
    func performUndo(_ record: UndoRecord) async {
        guard canWrite else {
            showMessage("Undo didn’t run because another change was still in progress. Change the types back from the inspector.", isFailure: true)
            return
        }
        activity = .undoing(record.kindIDs)
        defer {
            activity = .idle
            progress = nil
        }
        let prompts = record.restores.count
        showMessage(prompts == 1
            ? "Restoring the previous app. macOS will ask you to confirm the change."
            : "Restoring the previous apps. macOS will ask you to confirm each of \(prompts) changes.")

        // One call per restore, so a decline stops before the very next prompt.
        var outcomes: [MemberResult] = []
        var notAttempted = 0
        for restore in record.restores {
            if outcomes.contains(where: \.outcome.stopsUndo) {
                notAttempted += 1
                continue
            }
            outcomes += await writer.apply(app: restore.app, targets: [restore.target]) { [weak self] step in
                self?.progress = step
                return true
            }
        }

        for id in record.kindIDs {
            guard let kind = kinds.first(where: { $0.id == id }) else { continue }
            let own = Set(kind.members.map(\.target))
            results[id] = outcomes.filter { own.contains($0.target) }
        }
        await reloadHandlers(for: record.restores.map(\.target) + outcomes.map(\.target))

        if outcomes.contains(where: \.outcome.stopsUndo) {
            let rest = notAttempted == 0 ? "" : notAttempted == 1 ? " One change wasn’t attempted." : " \(notAttempted) changes weren’t attempted."
            showMessage("Undo stopped: macOS didn’t make a change.\(rest)", isFailure: true)
        } else {
            showMessage(prompts == 1 ? "Restored the previous app." : "Restored the previous apps.")
        }
    }

    /// One result per target: what a performed step reports wins, so a browser member covered
    /// by the `http` call is never also listed as not supported.
    static func finalResults(applied: [MemberResult], unsupported: [KindMember], app: AppRef) -> [MemberResult] {
        let covered = Set(applied.map(\.target))
        return applied + unsupported.filter { !covered.contains($0.target) }.map {
            MemberResult(target: $0.target, outcome: .skipped(.notSupported(app)), handlerAfter: $0.defaultApp)
        }
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
                if let handler, !kind.candidates.contains(where: { AppIdentity.same($0.url, handler.url) }) {
                    kind.candidates.append(handler)
                }
            }
            return kind
        }
    }

    /// Information fades after a few seconds; failures stay until dismissed. Both are announced,
    /// since a line that appears at the bottom of the window is invisible to VoiceOver otherwise.
    func showMessage(_ text: String, isFailure: Bool = false) {
        message = StatusMessage(text: text, isFailure: isFailure)
        announce(text)
        messageTask?.cancel()
        guard !isFailure else { return }
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    private func announce(_ text: String) {
        guard let app = NSApp else { return }
        NSAccessibility.post(element: app, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func dismissMessage() {
        messageTask?.cancel()
        message = nil
    }

    func focusSearch() {
        searchFocusRequests += 1
    }

    // MARK: Choosing an app with a panel

    func requestOtherApp(for target: AppChoiceTarget) {
        guard canWrite else {
            showMessage("Another change is still in progress.")
            return
        }
        pendingAppChoice = target
    }

    func cancelAppChoice() {
        pendingAppChoice = nil
    }

    /// "Choose an app to open Markdown files." or, for one type, names it.
    var appChoicePrompt: String {
        guard let pendingAppChoice, let kind = kinds.first(where: { $0.id == pendingAppChoice.kindID }) else {
            return "Choose an app."
        }
        switch pendingAppChoice {
        case .kind:
            return "Choose an app to open \(kind.name) files."
        case .member(_, let target):
            if WritePlan.browserRole.contains(target) { return "Choose your default web browser." }
            return "Choose an app to open \(target.displayName) (\(kind.name))."
        }
    }

    func completeAppChoice(_ url: URL) async {
        guard let target = pendingAppChoice else { return }
        pendingAppChoice = nil
        lastAppFolder = url.deletingLastPathComponent()
        guard let kind = kinds.first(where: { $0.id == target.kindID }) else { return }
        let app = HandlerService.appRef(for: url)
        switch target {
        case .kind:
            await setDefault(app, for: kind)
        case .member(_, let member):
            await setDefault(app, for: member, in: kind)
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

private extension MemberResult.Outcome {
    /// Anything but a completed change: the user declined, or macOS refused.
    var stopsUndo: Bool {
        switch self {
        case .changed, .skipped: false
        case .unchangedAfterSuccess, .declined, .failed: true
        }
    }
}
