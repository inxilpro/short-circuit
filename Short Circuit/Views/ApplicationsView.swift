import SwiftUI

/// Pick an app, see everything it can open, and make it the default for a reviewed set of
/// types. The checklist is the review: macOS still asks before each individual change.
struct ApplicationsView: View {
    @Environment(KindStore.self) private var store

    var body: some View {
        HStack(spacing: 0) {
            AppListView()
                .frame(width: 280)
            Divider()
            if let app = store.selectedApp {
                // A new list per app, rather than diffing hundreds of rows into another app's
                // sections, which also starts each app scrolled to the top.
                AppDetailView(app: app)
                    .id(app.url)
            } else {
                ContentUnavailableView(
                    "Select an App",
                    systemImage: "app",
                    description: Text("See every type it can open, and make it the default for the ones you choose.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// A Table rather than a List: a self-sizing List of 200-odd apps made AppKit's row-height
/// cache re-enter itself while diffing ("reentrant operation in its NSTableView delegate").
private struct AppListView: View {
    @Environment(KindStore.self) private var store

    private var filtered: [AppSummary] {
        let query = store.searchText.trimmingCharacters(in: .whitespaces)
        let all = store.appIndex.summaries
        return query.isEmpty ? all : all.filter { $0.label.localizedStandardContains(query) }
    }

    private var selection: Binding<URL?> {
        Binding(get: { store.selectedAppURL }, set: { store.selectApp($0) })
    }

    var body: some View {
        @Bindable var store = store
        let summaries = filtered
        let declaring = summaries.filter { $0.explicitCount > 0 }
        let others = summaries.filter { $0.explicitCount == 0 }

        Table(of: AppSummary.self, selection: selection) {
            TableColumn("App") { summary in
                AppListRow(summary: summary)
            }
        } rows: {
            ForEach(declaring) { summary in
                TableRow(summary)
                    .contextMenu { AppActions(app: summary.app) }
            }
            if !others.isEmpty {
                // Apps macOS only offers through broad conformance would bury the real choices.
                Section {
                    if store.showsOtherApps {
                        ForEach(others) { summary in
                            TableRow(summary)
                                .contextMenu { AppActions(app: summary.app) }
                        }
                    }
                } header: {
                    DisclosureHeader(title: "Other apps (\(others.count))", isExpanded: $store.showsOtherApps)
                }
            }
        }
        .tableColumnHeaders(.hidden)
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .overlay {
            if summaries.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }
}

private struct DisclosureHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    var help: String?

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(title, systemImage: isExpanded ? "chevron.down" : "chevron.right")
                .labelStyle(DisclosureLabelStyle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help ?? (isExpanded ? "Hide" : "Show"))
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

private struct DisclosureLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
                .font(.caption.weight(.semibold))
                .frame(width: 10)
            configuration.title
        }
    }
}

private struct AppActions: View {
    let app: AppRef

    var body: some View {
        RevealAppButton(app: app)
        Button("Copy Name") { Pasteboard.copy(app.name) }
        if let bundleID = app.bundleID {
            Button("Copy Bundle Identifier") { Pasteboard.copy(bundleID) }
        }
    }
}

private struct AppListRow: View {
    let summary: AppSummary

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(app: summary.app, size: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.label)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        if summary.explicitCount == 0 {
            return String(localized: "offered for \(summary.offeredCount)")
        }
        return String(localized: "default for \(summary.defaultCount) · can open \(summary.explicitCount)")
    }
}

/// One row of the detail table: a type and which section it's in.
private struct AppKindItem: Identifiable {
    var kind: Kind
    var relation: AppKindRelation

    var id: Kind.ID { kind.id }
    var isCheckable: Bool { relation == .partlyDefault || relation == .canOpen }
}

private struct AppDetailView: View {
    @Environment(KindStore.self) private var store
    let app: AppRef
    @State private var rowSelection = Set<Kind.ID>()

    private func items(_ relation: AppKindRelation) -> [AppKindItem] {
        store.kinds(for: app.url, relation: relation).map { AppKindItem(kind: $0, relation: relation) }
    }

    var body: some View {
        @Bindable var store = store
        let sections = [AppKindRelation.defaultFor, .partlyDefault, .canOpen].map { ($0, items($0)) }.filter { !$0.1.isEmpty }
        let offered = items(.offered)

        VStack(spacing: 0) {
            AppHeader(app: app)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()

            Table(of: AppKindItem.self, selection: $rowSelection) {
                TableColumn("") { item in
                    if item.isCheckable {
                        Toggle("Include \(item.kind.name)", isOn: checked(item.kind.id))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(!store.canWrite)
                    }
                }
                .width(20)

                TableColumn("Type") { item in
                    HStack(spacing: 8) {
                        KindIconView(kind: item.kind, size: 24, showsBadge: false)
                        Text(item.kind.name)
                            .lineLimit(1)
                    }
                }
                .width(min: 150, ideal: 200)

                TableColumn("Opens With") { item in
                    // In "Default for" this would only repeat the app's own name.
                    if item.relation != .defaultFor {
                        HStack(spacing: 4) {
                            if let current = item.kind.defaultApp {
                                AppIconView(app: current, size: 16)
                            }
                            DefaultAppLabel(kind: item.kind)
                        }
                    }
                }
                .width(min: 100, ideal: 140)

                TableColumn("Extensions") { item in
                    Text(extensionsText(item))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(extensionsText(item))
                }
                .width(min: 80, ideal: 140)

                TableColumn("Status") { item in
                    AppKindStatus(store: store, app: app, item: item)
                }
                .width(min: 120, ideal: 220)
            } rows: {
                ForEach(sections, id: \.0) { relation, items in
                    Section {
                        rows(items)
                    } header: {
                        SectionHeader(store: store, title: relation.title, kinds: items.map(\.kind), isCheckable: items.first?.isCheckable == true)
                    }
                }
                if !offered.isEmpty {
                    Section {
                        if store.showsOfferedKinds {
                            rows(offered)
                        }
                    } header: {
                        DisclosureHeader(
                            title: "\(AppKindRelation.offered.title) (\(offered.count))",
                            isExpanded: $store.showsOfferedKinds,
                            help: "macOS lists \(app.name) for these only because it opens a broader type, such as any text file."
                        )
                    }
                }
            }
            .contextMenu(forSelectionType: Kind.ID.self) { ids in
                if ids.count == 1, let id = ids.first, let kind = store.kinds.first(where: { $0.id == id }) {
                    KindActions(kind: kind, store: store, showsInBrowser: true)
                } else if !ids.isEmpty {
                    includeButtons(ids)
                }
            } primaryAction: { ids in
                if let id = ids.first { store.showKind(id) }
            }
            .onKeyPress(.space) {
                toggleIncluded(rowSelection)
                return .handled
            }

            Divider()
            BatchFooter()
                .padding(12)
                .background(.bar)
        }
    }

    @TableRowBuilder<AppKindItem>
    private func rows(_ items: [AppKindItem]) -> some TableRowContent<AppKindItem> {
        ForEach(items) { item in
            TableRow(item)
        }
    }

    @ViewBuilder
    private func includeButtons(_ ids: Set<Kind.ID>) -> some View {
        let checkable = ids.filter { id in
            store.kindIDs(for: app.url, relation: .partlyDefault).contains(id) || store.kindIDs(for: app.url, relation: .canOpen).contains(id)
        }
        Button("Include \(checkable.count) Types") { store.batchSelection.formUnion(checkable) }
            .disabled(checkable.isEmpty || !store.canWrite)
        Button("Exclude \(checkable.count) Types") { store.batchSelection.subtract(checkable) }
            .disabled(checkable.isEmpty || !store.canWrite)
    }

    /// Space flips the checkboxes of the selected rows, like a checklist in Mail's rules.
    private func toggleIncluded(_ ids: Set<Kind.ID>) {
        guard store.canWrite else { return }
        let checkable = Set(store.kindIDs(for: app.url, relation: .partlyDefault) + store.kindIDs(for: app.url, relation: .canOpen))
        let targets = ids.intersection(checkable)
        guard !targets.isEmpty else { return }
        if targets.isSubset(of: store.batchSelection) {
            store.batchSelection.subtract(targets)
        } else {
            store.batchSelection.formUnion(targets)
        }
    }

    private func checked(_ id: Kind.ID) -> Binding<Bool> {
        Binding(
            get: { store.batchSelection.contains(id) },
            set: { isOn in
                if isOn { store.batchSelection.insert(id) } else { store.batchSelection.remove(id) }
            }
        )
    }

    /// For rows that can be checked, the extensions the change would actually move; elsewhere,
    /// the type's extensions or schemes.
    private func extensionsText(_ item: AppKindItem) -> String {
        if item.isCheckable, let planned = AppBatchPlan(app: app, kinds: [item.kind]).items.first, !planned.changingExtensions.isEmpty {
            return planned.changingExtensions.joined(separator: " ")
        }
        let all = item.kind.extensions.map { ".\($0)" } + item.kind.schemes.map { "\($0):" }
        return all.joined(separator: " ")
    }
}

/// Table cells and headers get the store passed in: AppKit can host them outside the
/// environment chain, and an @Environment lookup there crashes.
private struct AppKindStatus: View {
    let store: KindStore
    let app: AppRef
    let item: AppKindItem

    var body: some View {
        Group {
            if store.isApplying(item.kind), let progress = store.progress {
                Label("Waiting for macOS… \(progress.call.changesBrowser ? String(localized: "default browser") : progress.call.call.friendlyName)", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            } else if store.batchRun?.notStartedKindIDs.contains(item.kind.id) == true {
                Label("Not started — the batch was stopped", systemImage: "stop.circle")
                    .foregroundStyle(.secondary)
            } else if let results = store.results[item.kind.id], store.batchRun?.finishedKindIDs.contains(item.kind.id) == true {
                ResultSummary(results: results)
            } else if item.isCheckable, let planned = AppBatchPlan(app: app, kinds: [item.kind]).items.first, !planned.unsupported.isEmpty {
                Label("\(planned.unsupported.map(\.target.displayName).formatted(.list(type: .and))) will stay: \(app.name) can’t open \(planned.unsupported.count == 1 ? "that type" : "those types")", systemImage: "nosign")
                    .foregroundStyle(.secondary)
                    .help("\(planned.unsupported.map(\.target.displayName).formatted(.list(type: .and))) will stay as it is, because \(app.name) can’t open \(planned.unsupported.count == 1 ? "that type" : "those types").")
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

private struct AppHeader: View {
    let app: AppRef

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                Text([app.version, AppLabels.abbreviatedFolder(of: app.url)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .contextMenu { AppActions(app: app) }
    }
}

private struct SectionHeader: View {
    let store: KindStore
    let title: String
    let kinds: [Kind]
    let isCheckable: Bool

    var body: some View {
        HStack {
            Text("\(title) (\(kinds.count))")
            Spacer()
            if isCheckable {
                let ids = Set(kinds.map(\.id))
                let allChecked = ids.isSubset(of: store.batchSelection)
                Button(allChecked ? "Deselect All" : "Select All") {
                    if allChecked {
                        store.batchSelection.subtract(ids)
                    } else {
                        store.batchSelection.formUnion(ids)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!store.canWrite)
            }
        }
    }
}

private struct BatchFooter: View {
    @Environment(KindStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            if let run = store.batchRun, run.isRunning {
                ProgressView()
                    .controlSize(.small)
                Text(runningText(run))
                    .lineLimit(1)
                Spacer()
                Button(run.stopRequested ? "Stopping…" : "Stop") {
                    store.stopBatch()
                }
                .disabled(run.stopRequested)
                .help("Stop after the current macOS prompt")
            } else {
                Text(summaryText)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("Apply") {
                    Task { await store.applyBatch() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.canWrite || (store.batchPlan?.promptCount ?? 0) == 0)
            }
        }
    }

    private func runningText(_ run: KindStore.BatchRun) -> String {
        let total = max(run.plannedChanges, run.changesStarted)
        let name = run.currentKindName.map { " — \($0)" } ?? ""
        return run.changesStarted == 0
            ? "Checking current apps…\(name)"
            : "Waiting for macOS… change \(run.changesStarted) of \(total)\(name)"
    }

    private var summaryText: String {
        if let run = store.batchRun, !run.isRunning {
            let stopped = run.notStartedKindIDs.isEmpty ? "" : " · stopped, \(run.notStartedKindIDs.count) not started"
            return "Finished \(run.finishedKindIDs.count) of \(run.kindIDs.count) types\(stopped)"
        }
        guard let plan = store.batchPlan, !plan.items.isEmpty else {
            return "Check the types to make \(store.selectedApp?.name ?? "this app") their default."
        }
        let types = plan.items.count == 1 ? "1 type selected" : "\(plan.items.count) types selected"
        switch plan.promptCount {
        case 0: return "\(types) · nothing needs changing"
        case 1: return "\(types) · macOS will ask you to confirm 1 change"
        default: return "\(types) · macOS will ask you to confirm \(plan.promptCount) changes"
        }
    }
}
