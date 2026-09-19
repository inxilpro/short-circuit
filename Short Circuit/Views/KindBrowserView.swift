import SwiftUI

struct KindBrowserView: View {
    @Environment(KindStore.self) private var store

    /// In Split, types whose members differ with no app to unify them follow the fixable ones
    /// under their own heading, so the mismatch stays visible without a Fix Split offer.
    private var splitSecondary: KindGridView.SecondarySection? {
        guard store.sidebarSelection == .split else { return nil }
        return KindGridView.SecondarySection(
            title: "Differ, no single app fits",
            ids: Set(store.mixedWithoutFixKinds.map(\.id)),
            emptyPrimaryNote: "No fixable splits"
        )
    }

    /// Resolution is progress within the Split list; elsewhere a fixed Kind just shows its app.
    private var resolvedIDs: Set<Kind.ID> {
        store.sidebarSelection == .split ? store.resolvedSplitIDs : []
    }

    var body: some View {
        @Bindable var store = store

        switch store.state {
        case .loading:
            ProgressView("Loading Types…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t Load Types", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await store.refresh(force: true) } }
            }
        case .loaded:
            if store.sidebarSelection == .applications {
                ApplicationsView()
            } else if store.visibleKinds.isEmpty {
                EmptyKindsView()
            } else {
                switch store.layout {
                case .grid:
                    KindGridView(
                        kinds: store.visibleKinds,
                        selection: $store.selectedKindID,
                        resolvedIDs: resolvedIDs,
                        secondary: splitSecondary,
                        onActivate: { store.isInspectorPresented = true },
                        onToggleDetails: { store.isInspectorPresented.toggle() }
                    )
                case .list:
                    KindTableView(
                        kinds: store.visibleKinds,
                        selection: $store.selectedKindID,
                        resolvedIDs: resolvedIDs,
                        onActivate: { store.isInspectorPresented = true }
                    )
                }
            }
        }
    }
}

private struct EmptyKindsView: View {
    @Environment(KindStore.self) private var store

    var body: some View {
        if KindSearch(store.searchText).isEmpty {
            if store.sidebarSelection == .split {
                ContentUnavailableView(
                    "No Fixable Splits",
                    systemImage: "checkmark.seal",
                    description: Text("No type has identifiers in different apps that one app could bring together.")
                )
            } else {
                ContentUnavailableView("No Types", systemImage: "doc.questionmark")
            }
        } else {
            ContentUnavailableView {
                Label("No Results for “\(store.searchText)”", systemImage: "magnifyingglass")
            } description: {
                Text("Search by name, extension (.md), MIME type, identifier, or link scheme (mailto:).")
            } actions: {
                if store.hiddenMatchesInAllTypes > 0 {
                    Button("Show \(store.hiddenMatchesInAllTypes) in All Types") {
                        store.sidebarSelection = .all
                    }
                }
                if store.hiddenAppPrivateMatches > 0 {
                    Button(store.hiddenAppPrivateMatches == 1
                           ? "Show 1 App-Specific Link Type"
                           : "Show \(store.hiddenAppPrivateMatches) App-Specific Link Types") {
                        store.showAppPrivateMatches()
                    }
                    .help("Link types only one app can open, such as sign-in callbacks. View ▸ Show App-Specific Link Types turns them on everywhere.")
                }
            }
        }
    }
}

#Preview("Loaded") {
    let store = KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview)
    KindBrowserView()
        .environment(store)
        .task { await store.refresh() }
        .frame(width: 640, height: 480)
}

#Preview("Failed") {
    let store = KindStore(provider: SampleKindProvider(failure: "lsregister exited with status 1."), writer: SimulatedHandlerWriter.preview)
    KindBrowserView()
        .environment(store)
        .task { await store.refresh() }
        .frame(width: 640, height: 480)
}
