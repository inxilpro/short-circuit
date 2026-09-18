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
                    systemImage: "app.dashed",
                    description: Text("See every type it can open, and make it the default for the ones you choose.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

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

        List(selection: selection) {
            ForEach(declaring) { summary in
                AppListRow(summary: summary)
                    .tag(summary.app.url)
            }
            if !others.isEmpty {
                // Apps macOS only offers through broad conformance would bury the real choices.
                DisclosureGroup(isExpanded: $store.showsOtherApps) {
                    ForEach(others) { summary in
                        AppListRow(summary: summary)
                            .tag(summary.app.url)
                    }
                } label: {
                    Text("Other apps (\(others.count))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if summaries.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            }
        }
    }
}

private struct AppListRow: View {
    let summary: AppSummary

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(app: summary.app, size: 24)
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
    }

    private var detail: String {
        if summary.explicitCount == 0 {
            return "offered for \(summary.offeredCount)"
        }
        return "default for \(summary.defaultCount) · can open \(summary.explicitCount)"
    }
}

private struct AppDetailView: View {
    @Environment(KindStore.self) private var store
    let app: AppRef

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 0) {
            List {
                AppHeader(app: app)

                ForEach([AppKindRelation.defaultFor, .partlyDefault, .canOpen], id: \.self) { relation in
                    let kinds = store.kinds(for: app.url, relation: relation)
                    if !kinds.isEmpty {
                        Section {
                            ForEach(kinds) { kind in
                                AppKindRow(app: app, kind: kind, isCheckable: relation != .defaultFor)
                            }
                        } header: {
                            SectionHeader(title: relation.title, kinds: kinds, isCheckable: relation != .defaultFor)
                        }
                    }
                }

                let offered = store.kinds(for: app.url, relation: .offered)
                if !offered.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $store.showsOfferedKinds) {
                            ForEach(offered) { kind in
                                AppKindRow(app: app, kind: kind, isCheckable: false)
                            }
                        } label: {
                            Text("\(AppKindRelation.offered.title) (\(offered.count))")
                                .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text("macOS lists \(app.name) for these only because it opens a broader type, such as any text file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            BatchFooter()
                .padding(12)
                .background(.bar)
        }
    }
}

private struct AppHeader: View {
    let app: AppRef

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.title3.weight(.semibold))
                Text([app.version, AppLabels.abbreviatedFolder(of: app.url)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct SectionHeader: View {
    @Environment(KindStore.self) private var store
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

private struct AppKindRow: View {
    @Environment(KindStore.self) private var store
    let app: AppRef
    let kind: Kind
    let isCheckable: Bool

    private var isChecked: Binding<Bool> {
        Binding(
            get: { store.batchSelection.contains(kind.id) },
            set: { checked in
                if checked { store.batchSelection.insert(kind.id) } else { store.batchSelection.remove(kind.id) }
            }
        )
    }

    var body: some View {
        let item = isCheckable ? AppBatchPlan(app: app, kinds: [kind]).items.first : nil

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isCheckable {
                Toggle("Include \(kind.name)", isOn: isChecked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!store.canWrite)
            }
            KindIconView(kind: kind, size: 20, showsBadge: false)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button(kind.name) { store.showKind(kind.id) }
                        .buttonStyle(.link)
                        .help("Show \(kind.name) in the browser")
                    DefaultAppLabel(kind: kind)
                        .font(.caption)
                }
                if let item {
                    if !item.changingExtensions.isEmpty {
                        Text("Changes \(item.changingExtensions.prefix(8).joined(separator: " "))\(item.changingExtensions.count > 8 ? " …" : "")")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if !item.unsupported.isEmpty {
                        Label("\(item.unsupported.map(\.target.displayName).joined(separator: ", ")) will stay: \(app.name) can’t open \(item.unsupported.count == 1 ? "that type" : "those types")", systemImage: "nosign")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                if store.isApplying(kind), let progress = store.progress {
                    Label("Waiting for macOS… \(progress.call.changesBrowser ? "default browser" : progress.call.call.friendlyName)", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if store.batchRun?.notStartedKindIDs.contains(kind.id) == true {
                    Label("Not started — the batch was stopped", systemImage: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let results = store.results[kind.id], store.batchRun?.finishedKindIDs.contains(kind.id) == true {
                    ResultSummary(results: results)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
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
