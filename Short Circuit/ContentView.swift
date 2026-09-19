import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(KindStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    @State private var isDropTargeted = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
        } detail: {
            KindBrowserView()
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .searchable(text: $store.searchText, placement: .toolbar, prompt: searchPrompt)
                .searchFocused($isSearchFocused)
                .toolbar { toolbar }
                .inspector(isPresented: inspectorPresented) {
                    KindInspectorView(kind: store.selectedKind, editing: store.selectedKind.map(editing(for:)))
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
                .fileImporter(isPresented: identifyingFile, allowedContentTypes: [.item]) { result in
                    if case .success(let url) = result { store.revealKind(forFileAt: url) }
                }
                .fileDialogMessage("Choose a file to see which type it is and what opens it.")
                .fileDialogConfirmationLabel("Show Type")
        }
        .frame(minWidth: 820, minHeight: 480)
        .fileImporter(isPresented: choosingApp, allowedContentTypes: [.application], allowsMultipleSelection: false) { result in
            // Read the target now, synchronously: SwiftUI has already dismissed the sheet.
            if case .success(let urls) = result, let url = urls.first, let target = store.pendingAppChoice {
                Task { await store.completeAppChoice(url, for: target) }
            } else {
                store.cancelAppChoice()
            }
        } onCancellation: {
            store.cancelAppChoice()
        }
        .fileDialogDefaultDirectory(store.lastAppFolder ?? URL(filePath: "/Applications", directoryHint: .isDirectory))
        .fileDialogMessage(Text(store.appChoicePrompt))
        .fileDialogConfirmationLabel("Choose")
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
            let files = urls.filter(\.isFileURL)
            guard let url = files.first else { return false }
            store.handleDrop(of: url, ignoredCount: files.count - 1)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .animation(reduceMotion ? nil : .default, value: store.message)
        .onChange(of: store.searchFocusRequests) { isSearchFocused = true }
        .onChange(of: undoManager, initial: true) { store.undoManager = undoManager }
        .defaultAppStorage(store.preferences ?? .standard)
        .task {
            #if DEBUG
            // Started alongside the load so the snapshot run can capture the loading state.
            Task { await DebugSnapshotter.run(store: store) }
            #endif
            await store.refresh()
        }
    }

    private var searchPrompt: Text {
        store.sidebarSelection == .applications ? Text("Search Apps") : Text("Search Types")
    }

    /// Presentation only. Clearing it must not touch the pending target (see `cancelAppChoice`).
    private var choosingApp: Binding<Bool> {
        Binding(get: { store.isPresentingAppChoice }, set: { store.isPresentingAppChoice = $0 })
    }

    private var identifyingFile: Binding<Bool> {
        Binding(get: { store.isChoosingFileToIdentify }, set: { store.isChoosingFileToIdentify = $0 })
    }

    /// The Applications view has its own detail pane, so the Kind inspector steps aside there.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { store.isInspectorPresented && store.sidebarSelection != .applications },
            set: { store.isInspectorPresented = $0 }
        )
    }

    private func editing(for kind: Kind) -> KindEditing {
        KindEditing(
            isEnabled: store.canWrite,
            isApplying: store.isApplying(kind),
            progress: store.isApplying(kind) ? store.progress : nil,
            showsShadowedMembers: store.showsShadowedMembers,
            setShowsShadowedMembers: { store.showsShadowedMembers = $0 },
            results: store.results(for: kind),
            setDefault: { app in Task { await store.setDefault(app, for: kind) } },
            setMemberDefault: { app, target in Task { await store.setDefault(app, for: target, in: kind) } },
            fixSplit: { Task { await store.fixSplit(kind) } },
            chooseOtherApp: { target in
                store.requestOtherApp(for: target.map { .member(kind.id, $0) } ?? .kind(kind.id))
            }
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
            .help("Show types as icons or as a list")
            .disabled(store.sidebarSelection == .applications)
        }

        if store.isRefreshing, case .loaded = store.state {
            ToolbarItem(placement: .primaryAction) {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading types…")
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
            .help("Read the list of apps and types again")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.isInspectorPresented.toggle()
            } label: {
                Label(inspectorPresented.wrappedValue ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(inspectorPresented.wrappedValue ? "Hide Inspector" : "Show Inspector")
            .disabled(store.sidebarSelection == .applications)
        }
    }

    @ViewBuilder
    private var messageBanner: some View {
        if let message = store.message {
            HStack(spacing: 10) {
                Label(message.text, systemImage: message.isFailure ? "exclamationmark.triangle.fill" : "info.circle")
                    .symbolRenderingMode(message.isFailure ? .multicolor : .monochrome)
                    .fixedSize(horizontal: false, vertical: true)
                if message.isFailure {
                    Button {
                        store.dismissMessage()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Dismiss")
                    .help("Dismiss")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: 560)
            .glassEffect()
            // Applications has its own footer with the batch's progress; stay above it.
            .padding(.bottom, store.sidebarSelection == .applications ? 70 : 20)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var title: String {
        switch store.sidebarSelection {
        case .split: String(localized: "Split")
        case .common, nil: String(localized: "Common")
        case .category(let category): category.title
        case .all: String(localized: "All Types")
        case .applications: String(localized: "Applications")
        }
    }

    private var subtitle: Text {
        guard case .loaded = store.state else { return Text(verbatim: "") }
        if store.sidebarSelection == .applications {
            return Text("^[\(store.appIndex.summaries.count) app](inflect: true)")
        }
        return Text("^[\(store.visibleKinds.count) type](inflect: true)")
    }
}

#Preview {
    ContentView()
        .environment(KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview))
        .frame(width: 1100, height: 640)
}
