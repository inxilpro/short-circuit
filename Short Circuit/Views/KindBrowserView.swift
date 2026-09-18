import SwiftUI

struct KindBrowserView: View {
    @Environment(KindStore.self) private var store

    var body: some View {
        @Bindable var store = store

        switch store.state {
        case .loading:
            ProgressView("Reading Launch Services…")
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
                ApplicationsPlaceholderView()
            } else if store.visibleKinds.isEmpty {
                EmptyKindsView()
            } else {
                switch store.layout {
                case .grid: KindGridView(kinds: store.visibleKinds, selection: $store.selectedKindID)
                case .list: KindTableView(kinds: store.visibleKinds, selection: $store.selectedKindID)
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
                    "Nothing Is Split",
                    systemImage: "checkmark.seal",
                    description: Text("Every type opens in a single app.")
                )
            } else {
                ContentUnavailableView("No Types", systemImage: "doc.questionmark")
            }
        } else {
            ContentUnavailableView {
                Label("No Results for “\(store.searchText)”", systemImage: "magnifyingglass")
            } description: {
                Text("Search by name, .ext, MIME type, UTI, or scheme:")
            } actions: {
                if store.hiddenMatchesInAllTypes > 0 {
                    Button("Show \(store.hiddenMatchesInAllTypes) in All Types") {
                        store.sidebarSelection = .all
                    }
                }
            }
        }
    }
}

#Preview("Loaded") {
    let store = KindStore(provider: SampleKindProvider())
    KindBrowserView()
        .environment(store)
        .task { await store.refresh() }
        .frame(width: 640, height: 480)
}

#Preview("Failed") {
    let store = KindStore(provider: SampleKindProvider(failure: "lsregister exited with status 1."))
    KindBrowserView()
        .environment(store)
        .task { await store.refresh() }
        .frame(width: 640, height: 480)
}
