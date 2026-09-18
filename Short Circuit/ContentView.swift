import SwiftUI

struct ContentView: View {
    @Environment(KindStore.self) private var store
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
        } detail: {
            KindBrowserView()
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .searchable(text: $store.searchText, placement: .toolbar, prompt: "Name, .ext, MIME, UTI, or scheme:")
                .toolbar { toolbar }
                .inspector(isPresented: $store.isInspectorPresented) {
                    KindInspectorView(kind: store.selectedKind, editing: store.selectedKind.map(editing(for:)))
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
                .confirmationDialog(
                    store.pendingChange.map(ChangeConfirmation.title(for:)) ?? "",
                    isPresented: isConfirmingChange,
                    presenting: store.pendingChange
                ) { _ in
                    Button("Continue") {
                        Task { await store.confirmPendingChange() }
                    }
                    Button("Cancel", role: .cancel) {
                        store.cancelPendingChange()
                    }
                } message: { change in
                    Text(ChangeConfirmation.message(for: change))
                }
        }
        .frame(minWidth: 820, minHeight: 480)
        .overlay(alignment: .bottom) { messageBanner }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            store.revealKind(forFileAt: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .animation(.default, value: store.transientMessage)
        .task {
            #if DEBUG
            // Started alongside the load so the snapshot run can capture the loading state.
            Task { await DebugSnapshotter.run(store: store) }
            #endif
            await store.refresh()
        }
    }

    private var isConfirmingChange: Binding<Bool> {
        Binding(
            get: { store.pendingChange != nil },
            set: { if !$0 { store.cancelPendingChange() } }
        )
    }

    private func editing(for kind: Kind) -> KindEditing {
        KindEditing(
            isEnabled: store.canWrite,
            isApplying: store.isApplying(kind),
            results: store.results(for: kind),
            setDefault: { app in Task { await store.setDefault(app, for: kind) } },
            setMemberDefault: { app, target in Task { await store.setDefault(app, for: target, in: kind) } },
            fixSplit: { Task { await store.fixSplit(kind) } }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: Bindable(store).layout) {
                Label("Icons", systemImage: "square.grid.2x2").tag(BrowserLayout.grid)
                Label("List", systemImage: "list.bullet").tag(BrowserLayout.list)
            }
            .pickerStyle(.segmented)
            .help("Show as icons or list")
        }

        if store.isRefreshing, case .loaded = store.state {
            ToolbarItem(placement: .primaryAction) {
                ProgressView()
                    .controlSize(.small)
                    .help("Reading Launch Services…")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                IconCache.invalidate()
                Task { await store.refresh(force: true) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(store.isRefreshing || store.isWriting)
            .help("Re-read Launch Services (⌘R)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.right")
            }
            .help("Show or hide the inspector")
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = store.transientMessage {
            Label(message, systemImage: "questionmark.folder")
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect()
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var title: String {
        switch store.sidebarSelection {
        case .split: "Split"
        case .common, nil: "Common"
        case .category(let category): category.title
        case .all: "All Types"
        case .applications: "Applications"
        }
    }

    private var subtitle: String {
        guard case .loaded = store.state, store.sidebarSelection != .applications else { return "" }
        let count = store.visibleKinds.count
        return count == 1 ? "1 type" : "\(count) types"
    }
}

#Preview {
    ContentView()
        .environment(KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview))
        .frame(width: 1100, height: 640)
}
