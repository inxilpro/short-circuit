import SwiftUI

/// The menu bar. Every action in the window is reachable here with the Mac's usual names and
/// shortcuts, and the Type menu carries the same actions as a type's context menu.
struct AppCommands: Commands {
    let store: KindStore

    private var isBrowsingTypes: Bool {
        store.sidebarSelection != .applications
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Show Type of File…") {
                store.isChoosingFileToIdentify = true
            }
            .keyboardShortcut("o")
            .disabled(store.kinds.isEmpty)
        }

        // SwiftUI's own Undo can't be disabled while a change runs, and popping an entry then
        // would lose it. The window's UndoManager also holds text edits, so these still undo
        // typing in the search field.
        CommandGroup(replacing: .undoRedo) {
            Button(store.undoMenuTitle) { store.undoManager?.undo() }
                .keyboardShortcut("z")
                .disabled(!store.canUndoNow)
            Button(store.redoMenuTitle) { store.undoManager?.redo() }
                .keyboardShortcut("z", modifiers: [.shift, .command])
                .disabled(!store.canRedoNow)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { store.focusSearch() }
                .keyboardShortcut("f")
        }

        SidebarCommands()

        CommandGroup(before: .toolbar) {
            Toggle("as Icons", isOn: layoutBinding(.grid))
                .keyboardShortcut("1")
                .disabled(!isBrowsingTypes)
            Toggle("as List", isOn: layoutBinding(.list))
                .keyboardShortcut("2")
                .disabled(!isBrowsingTypes)
            Divider()
            Menu("Go To") {
                sectionButton("Split", .split, key: "1")
                sectionButton("Common", .common, key: "2")
                sectionButton("All Types", .all, key: "3")
                sectionButton("Applications", .applications, key: "4")
            }
            Divider()
            Toggle("Show App-Specific Link Types", isOn: Binding(
                get: { store.showsAppPrivateKinds },
                set: { store.showsAppPrivateKinds = $0 }
            ))
            Divider()
        }

        CommandGroup(after: .toolbar) {
            Button(store.isInspectorPresented && isBrowsingTypes ? "Hide Inspector" : "Show Inspector") {
                store.isInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.control, .command])
            .disabled(!isBrowsingTypes)
            Divider()
            Button("Refresh") {
                IconCache.invalidate()
                Task { await store.refresh(force: true) }
            }
            .keyboardShortcut("r")
            .disabled(store.isRefreshing || store.isWriting)
        }

        CommandMenu("Type") {
            TypeMenu(store: store)
        }

        CommandGroup(replacing: .help) {
            Link("Short Circuit Help", destination: URL(string: "https://github.com/inxilpro/short-circuit#readme")!)
                .keyboardShortcut("?")
            Link("Report an Issue…", destination: URL(string: "https://github.com/inxilpro/short-circuit/issues")!)
        }

        #if DEBUG
        CommandMenu("Debug") {
            Button("Export Launch Services Snapshot…") {
                Task { await SnapshotExportCommand.run(kinds: store.kinds) }
            }
        }
        #endif
    }

    private func layoutBinding(_ layout: BrowserLayout) -> Binding<Bool> {
        Binding(get: { store.layout == layout && isBrowsingTypes }, set: { if $0 { store.layout = layout } })
    }

    private func sectionButton(_ title: LocalizedStringKey, _ item: SidebarItem, key: KeyEquivalent) -> some View {
        Button(title) { store.sidebarSelection = item }
            .keyboardShortcut(key, modifiers: [.option, .command])
    }
}

/// Menu-bar items keep their shortcuts; without a selected type they are shown disabled rather
/// than hidden, so the menu doesn't change shape under the pointer.
private struct TypeMenu: View {
    let store: KindStore

    var body: some View {
        if let kind = store.selectedKind {
            OpenWithMenu(kind: kind, store: store)
            Button(fixSplitTitle(kind)) {
                Task { await store.fixSplit(kind) }
            }
            .keyboardShortcut("f", modifiers: [.option, .command])
            .disabled(!kind.isSplit || kind.fixSplitApp == nil || !store.canWrite)
            Divider()
            Button("Copy Identifiers") {
                Pasteboard.copy(kind.identifierList.joined(separator: "\n"))
            }
            .keyboardShortcut("c", modifiers: [.option, .command])
            Button("Copy Extensions") {
                Pasteboard.copy(kind.extensions.map { ".\($0)" }.joined(separator: " "))
            }
            .disabled(kind.extensions.isEmpty)
            Divider()
            Button(kind.defaultApp.map { "Show \($0.name) in Finder" } ?? "Show Default App in Finder") {
                if let app = kind.defaultApp { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
            }
            .keyboardShortcut("r", modifiers: [.option, .command])
            .disabled(kind.defaultApp == nil)
        } else {
            Menu("Open With") {}.disabled(true)
            Button("Fix Split") {}.keyboardShortcut("f", modifiers: [.option, .command]).disabled(true)
            Divider()
            Button("Copy Identifiers") {}.keyboardShortcut("c", modifiers: [.option, .command]).disabled(true)
            Button("Copy Extensions") {}.disabled(true)
            Divider()
            Button("Show Default App in Finder") {}.keyboardShortcut("r", modifiers: [.option, .command]).disabled(true)
        }
    }

    private func fixSplitTitle(_ kind: Kind) -> String {
        guard kind.isSplit, let app = kind.fixSplitApp else { return "Fix Split" }
        return "Fix Split — Use \(kind.labelContext.label(for: app)) for All"
    }
}
