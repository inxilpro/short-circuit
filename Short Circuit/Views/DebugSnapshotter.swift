#if DEBUG
import AppKit
import SwiftUI

/// Walks the window through its main states and writes PNGs, because agents running without
/// Screen Recording permission can't use `screencapture`. Enabled by setting SC_SNAPSHOT_DIR.
enum DebugSnapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["SC_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// SC_SNAPSHOT_LIVE=1 reads this Mac's real Launch Services data and captures read-only states.
    static var isLive: Bool {
        ProcessInfo.processInfo.environment["SC_SNAPSHOT_LIVE"] == "1"
    }

    /// SC_SNAPSHOT_ONLY=menus,keyboard runs just those groups, for a quick check of one area.
    static var only: Set<String>? {
        ProcessInfo.processInfo.environment["SC_SNAPSHOT_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
    }

    static func run(store: KindStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let only {
            while case .loading = store.state { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(500))
            if only.contains("menus") {
                await dumpMenus(store: store, to: directory)
                store.sidebarSelection = .all
                store.selectedKindID = "rtf"
                try? await Task.sleep(for: .milliseconds(500))
                await dumpMenus(store: store, to: directory, name: "menus-selected")
            }
            if only.contains("keyboard") { await runKeyboardStates(store: store, directory: directory) }
            if only.contains("batch") { await runApplicationsStates(store: store, directory: directory) }
            if only.contains("undo") { await runUndoStates(store: store, directory: directory) }
            if only.contains("apps") {
                store.sidebarSelection = .applications
                try? await Task.sleep(for: .milliseconds(1500))
                if let first = store.appIndex.summaries.max(by: { $0.explicitCount < $1.explicitCount }) {
                    store.selectApp(first.app.url)
                    try? await Task.sleep(for: .milliseconds(1500))
                }
            }
            NSApp.terminate(nil)
            return
        }

        if isLive {
            await runLive(store: store, directory: directory)
            NSApp.terminate(nil)
            return
        }

        while case .loading = store.state { try? await Task.sleep(for: .milliseconds(100)) }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            NSApp.appearance = NSAppearance(named: appearance)
            let suffix = appearance == .aqua ? "light" : "dark"

            store.sidebarSelection = .common
            store.searchText = ""
            store.layout = .grid
            store.selectedKindID = nil
            await snapshot("grid-\(suffix)", to: directory)

            store.layout = .list
            store.selectedKindID = store.visibleKinds.first?.id
            await snapshot("list-\(suffix)", to: directory)

            store.layout = .grid
            store.sidebarSelection = .split
            store.selectedKindID = store.splitKinds.first?.id
            await snapshot("inspector-split-\(suffix)", to: directory)

            store.sidebarSelection = .all
            store.searchText = "http:"
            store.selectedKindID = store.visibleKinds.first?.id
            await snapshot("search-scheme-\(suffix)", to: directory)

            store.searchText = ".m"
            await snapshot("search-extension-\(suffix)", to: directory)

            store.sidebarSelection = .common
            store.searchText = "epub"
            await snapshot("search-empty-\(suffix)", to: directory)

            store.sidebarSelection = .all
            store.searchText = "applenotes"
            await snapshot("search-hidden-app-specific-\(suffix)", to: directory)
            store.searchText = ""
            store.showsAppPrivateKinds = true
            await snapshot("all-types-app-specific-shown-\(suffix)", to: directory)
            store.showsAppPrivateKinds = false

            store.sidebarSelection = .applications
            store.searchText = ""
            await snapshot("applications-\(suffix)", to: directory)

            let dropped = FileManager.default.temporaryDirectory.appending(path: "notes.md")
            try? Data("# hi".utf8).write(to: dropped)
            store.searchText = "pdf"
            store.revealKind(forFileAt: dropped)
            await snapshot("drop-md-\(suffix)", to: directory)

            let unknown = FileManager.default.temporaryDirectory.appending(path: "mystery.qqqzz")
            try? Data().write(to: unknown)
            store.revealKind(forFileAt: unknown)
            await snapshot("drop-unknown-\(suffix)", to: directory)
        }
        await runWriteStates(store: store, directory: directory)
        await runUndoStates(store: store, directory: directory)
        await runApplicationsStates(store: store, directory: directory)
        await runKeyboardStates(store: store, directory: directory)
        await runMessageStates(store: store, directory: directory)
        await dumpMenus(store: store, to: directory)
        NSApp.terminate(nil)
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }
    }

    /// Drives the grid with real key events and logs what each one selected, since focus and
    /// key handling can't be seen in a still image. Restores the pasteboard it borrows for ⌘C.
    private static func runKeyboardStates(store: KindStore, directory: URL) async {
        guard let window = mainWindow, let content = window.contentView else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        NSApp.appearance = NSAppearance(named: .aqua)
        store.searchText = ""
        store.layout = .grid
        store.sidebarSelection = .all
        store.isInspectorPresented = true
        store.selectedKindID = nil
        try? await Task.sleep(for: .milliseconds(700))

        var log: [String] = []
        func record(_ step: String) {
            log.append("\(step): selection=\(store.selectedKindID ?? "nil") inspector=\(store.isInspectorPresented)")
        }

        // The first tile sits just right of the sidebar, below the toolbar.
        let point = NSPoint(x: 290, y: content.frame.height - 130)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        record("click first tile")

        let steps: [(String, UInt16, String, NSEvent.ModifierFlags)] = [
            ("right", 124, String(UnicodeScalar(NSRightArrowFunctionKey)!), [.function, .numericPad]),
            ("right", 124, String(UnicodeScalar(NSRightArrowFunctionKey)!), [.function, .numericPad]),
            ("down", 125, String(UnicodeScalar(NSDownArrowFunctionKey)!), [.function, .numericPad]),
            ("left", 123, String(UnicodeScalar(NSLeftArrowFunctionKey)!), [.function, .numericPad]),
            ("up", 126, String(UnicodeScalar(NSUpArrowFunctionKey)!), [.function, .numericPad]),
            ("end", 119, String(UnicodeScalar(NSEndFunctionKey)!), [.function]),
            ("home", 115, String(UnicodeScalar(NSHomeFunctionKey)!), [.function]),
            ("type p", 35, "p", []),
            ("type l", 37, "l", []),
            ("space", 49, " ", []),
            ("space", 49, " ", []),
        ]
        for (name, code, characters, flags) in steps {
            send(key: code, characters: characters, flags: flags, to: window)
            // The inspector animates in and out; a key during that is a different test.
            try? await Task.sleep(for: .milliseconds(name == "space" ? 900 : 250))
            record(name)
        }
        await snapshot("keyboard-focused-light", to: directory, settle: .milliseconds(300))

        let saved = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        let copyItem = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu?.item(withTitle: "Copy")
        copyItem?.menu?.update()
        log.append("Edit ▸ Copy enabled: \(copyItem?.isEnabled == true), first responder: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        if let copy = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8) {
            log.append("⌘C handled by menu: \(NSApp.mainMenu?.performKeyEquivalent(with: copy) == true)")
        }
        try? await Task.sleep(for: .milliseconds(300))
        if NSPasteboard.general.string(forType: .string) == nil {
            log.append("window is key: \(window.isKeyWindow), app active: \(NSApp.isActive)")
            log.append("copy: via the window's responder chain handled: \(window.firstResponder?.tryToPerform(#selector(NSText.copy(_:)), with: nil) == true)")
        }
        try? await Task.sleep(for: .milliseconds(300))
        log.append("⌘C pasteboard: \(NSPasteboard.general.string(forType: .string) ?? "nil")")
        log.append("⌘C types: \(NSPasteboard.general.types?.map(\.rawValue).joined(separator: ", ") ?? "none")")
        NSPasteboard.general.clearContents()
        if let saved { NSPasteboard.general.setString(saved, forType: .string) }

        send(key: 53, characters: "\u{1b}", flags: [], to: window)
        try? await Task.sleep(for: .milliseconds(250))
        record("escape")

        if let find = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) {
            log.append("⌘F handled by menu: \(NSApp.mainMenu?.performKeyEquivalent(with: find) == true)")
        }
        try? await Task.sleep(for: .milliseconds(400))
        let responder = window.firstResponder
        let inSearch = (responder as? NSTextView)?.delegate is NSSearchField || responder is NSSearchField
        log.append("after ⌘F first responder: \(responder.map { String(describing: type(of: $0)) } ?? "nil"), in search field: \(inSearch)")
        window.makeFirstResponder(nil)

        log.append("store's undo manager is the window's: \(store.undoManager != nil && store.undoManager === window.undoManager)")

        store.selectedKindID = "markdown"
        window.makeFirstResponder(nil)
        await snapshot("keyboard-unfocused-light", to: directory)

        try? log.joined(separator: "\n").write(to: directory.appending(path: "keyboard.txt"), atomically: true, encoding: .utf8)
    }

    private static func send(key code: UInt16, characters: String, flags: NSEvent.ModifierFlags, to window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                window.sendEvent(event)
            }
        }
    }

    /// Undo runs the restore through the simulated writer, exactly as a person's ⌘Z would.
    private static func runUndoStates(store: KindStore, directory: URL) async {
        guard store.writer is SimulatedHandlerWriter, let undoManager = store.undoManager else { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        store.searchText = ""
        store.sidebarSelection = .all
        store.layout = .grid
        guard let png = store.kinds.first(where: { $0.id == "png" }) else { return }
        store.selectedKindID = png.id
        await store.setDefault(.photos, for: png)
        await snapshot("undo-before-light", to: directory)
        let name = undoManager.undoMenuItemTitle
        undoManager.undo()
        await snapshot("undo-applying-light", to: directory, settle: .milliseconds(500))
        await store.undoTask?.value
        await snapshot("undo-done-light", to: directory)
        try? "menu item: \(name)\nafter: \(store.kinds.first { $0.id == "png" }?.defaultApp?.name ?? "nil")\n".write(to: directory.appending(path: "undo.txt"), atomically: true, encoding: .utf8)
    }

    private static func runMessageStates(store: KindStore, directory: URL) async {
        NSApp.appearance = NSAppearance(named: .aqua)
        store.showMessage("Refresh failed: lsregister exited with status 1.", isFailure: true)
        await snapshot("message-failure-light", to: directory)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await snapshot("message-failure-dark", to: directory)
        store.dismissMessage()
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    private static func runWriteStates(store: KindStore, directory: URL) async {
        // Refuse outright rather than risk driving the real setter from an unattended run.
        guard store.writer is SimulatedHandlerWriter else {
            print("DebugSnapshotter: skipping write states; the store does not use the simulated writer.")
            return
        }
        func kind(_ id: Kind.ID) -> Kind? { store.kinds.first { $0.id == id } }

        NSApp.appearance = NSAppearance(named: .aqua)
        store.searchText = ""
        store.layout = .grid
        store.sidebarSelection = .all
        store.isInspectorPresented = true

        // The demo backend pauses 1.2 s per call, standing in for the user answering each prompt,
        // so a capture taken mid-run shows the inline progress.
        if let phone = kind("phone-call") {
            store.selectedKindID = phone.id
            let applying = Task { await store.setDefault(.messages, for: phone) }
            await snapshot("write-applying-light", to: directory, settle: .milliseconds(500))
            await applying.value
            await snapshot("write-results-light", to: directory)
        }

        store.sidebarSelection = .split
        store.selectedKindID = kind("phone-call")?.id
        await snapshot("write-split-resolved-light", to: directory)
        store.layout = .list
        await snapshot("write-split-resolved-list-light", to: directory)
        store.layout = .grid
        store.sidebarSelection = .all

        if let richText = kind("rtf") {
            store.selectedKindID = richText.id
            await store.setDefault(.notes, for: richText)
            await snapshot("write-partial-failure-light", to: directory)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await snapshot("write-partial-failure-dark", to: directory)
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        // public.markdown is unsettable in the sample data, so it's left out: the calls are the
        // declared type plus the three extension rows, and only the declared type prompts.
        if let markdown = kind("markdown") {
            store.selectedKindID = markdown.id
            await snapshot("inert-member-light", to: directory)
            await store.setDefault(.preview, for: markdown)
            await snapshot("inert-member-after-set-light", to: directory)
        }

        // Effective vs shadowed members, and a mix no single app can fix.
        if let mpeg4Audio = kind("mpeg4-audio") {
            store.selectedKindID = mpeg4Audio.id
            await snapshot("members-shadowed-collapsed-light", to: directory)
            store.showsShadowedMembers = true
            await snapshot("members-shadowed-expanded-light", to: directory)
            store.showsShadowedMembers = false
        }
        if let markdown = kind("markdown") {
            store.selectedKindID = markdown.id
            await snapshot("members-governed-light", to: directory)
        }
        if let audioCall = kind("audio-call") {
            store.selectedKindID = audioCall.id
            await snapshot("members-mixed-not-split-light", to: directory)
        }

        // Mail is a candidate for the Kind, but only Calendar lists webcal:.
        if let calendarEvent = kind("calendar-event") {
            store.selectedKindID = calendarEvent.id
            await store.setDefault(.mail, for: calendarEvent)
            await snapshot("write-not-supported-light", to: directory)
        }

        if let heic = kind("heic") {
            store.selectedKindID = heic.id
            await store.fixSplit(heic)
            await snapshot("write-declined-light", to: directory)
        }

        // Web page: the browser role is one call, and XHTML is its own second call.
        if let web = kind("web-page") {
            store.selectedKindID = web.id
            await snapshot("write-browser-before-light", to: directory)
            let applying = Task { await store.setDefault(.textEdit, for: .uti("public.html"), in: web) }
            await snapshot("write-browser-applying-light", to: directory, settle: .milliseconds(500))
            await applying.value
            await snapshot("write-browser-role-light", to: directory)
        }
        if let web = kind("web-page") {
            let applying = Task { await store.setDefault(.safari, for: web) }
            await waitForStep(2, in: store)
            await snapshot("write-browser-xhtml-step2-light", to: directory, settle: .milliseconds(300))
            await applying.value
            await snapshot("write-browser-xhtml-results-light", to: directory)
        }
    }

    private static func runApplicationsStates(store: KindStore, directory: URL) async {
        guard store.writer is SimulatedHandlerWriter else { return }
        NSApp.appearance = NSAppearance(named: .aqua)
        store.searchText = ""
        store.sidebarSelection = .applications
        try? await Task.sleep(for: .milliseconds(500))
        store.selectApp(AppRef.photos.url)
        store.batchSelection.formUnion(store.kindIDs(for: AppRef.photos.url, relation: .canOpen).prefix(3))
        await snapshot("apps-photos-light", to: directory)

        let run = Task { await store.applyBatch() }
        for _ in 0..<100 where (store.batchRun?.changesStarted ?? 0) < 2 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await snapshot("apps-applying-light", to: directory, settle: .milliseconds(300))
        store.stopBatch()
        await run.value
        await snapshot("apps-results-light", to: directory)

        NSApp.appearance = NSAppearance(named: .darkAqua)
        store.selectApp(AppRef.preview.url)
        await snapshot("apps-preview-dark", to: directory)
        NSApp.appearance = NSAppearance(named: .aqua)
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    private static func waitForStep(_ step: Int, in store: KindStore) async {
        for _ in 0..<100 where (store.progress?.step ?? 0) < step {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private static func runLive(store: KindStore, directory: URL) async {
        // This mode must only ever look. Bail out before touching anything if the real writer
        // somehow got wired in.
        guard !(store.writer is LiveHandlerWriter), !(store.writer is SimulatedHandlerWriter) else {
            print("DebugSnapshotter: refusing live run; the store's writer is \(type(of: store.writer)).")
            return
        }

        let started = ContinuousClock.now
        await snapshot("live-loading", to: directory, settle: .milliseconds(300))
        while case .loading = store.state { try? await Task.sleep(for: .milliseconds(50)) }
        let loadTime = ContinuousClock.now - started

        NSApp.appearance = NSAppearance(named: .aqua)
        store.isInspectorPresented = true
        store.layout = .grid

        store.sidebarSelection = .common
        await snapshot("live-common-grid", to: directory)

        store.sidebarSelection = .split
        store.selectedKindID = store.splitKinds.first?.id
        await snapshot("live-split", to: directory)

        store.sidebarSelection = .all
        store.layout = .list
        store.selectedKindID = nil
        await snapshot("live-all-list", to: directory)
        store.layout = .grid

        let markdown = store.kinds.first { $0.utis.contains("net.daringfireball.markdown") || $0.utis.contains("public.markdown") }
        store.selectedKindID = markdown?.id
        await snapshot("live-markdown-inspector", to: directory)

        if let noWholeType = store.kinds.first(where: { !$0.hasWholeTypeTargets && $0.settableMembers.count > 0 }) {
            store.selectedKindID = noWholeType.id
            await snapshot("live-no-whole-type-inspector", to: directory)
        }

        let web = store.kinds.first { $0.schemes.contains("http") }
        store.selectedKindID = web?.id
        await snapshot("live-webpage-inspector", to: directory)

        store.selectedKindID = nil
        store.searchText = ".md"
        await snapshot("live-search-md", to: directory)

        let scheme = store.kinds.flatMap(\.schemes).contains("slack") ? "slack" : store.kinds.flatMap(\.schemes).first { !["http", "https", "mailto"].contains($0) } ?? "mailto"
        store.searchText = "\(scheme):"
        store.selectedKindID = store.visibleKinds.first?.id
        await snapshot("live-search-scheme", to: directory)
        store.searchText = ""

        for category in [KindCategory.documents, .other] {
            store.sidebarSelection = .category(category)
            store.selectedKindID = nil
            await snapshot("live-category-\(category.rawValue)", to: directory)
        }

        NSApp.appearance = NSAppearance(named: .darkAqua)
        store.sidebarSelection = .common
        store.selectedKindID = markdown?.id
        await snapshot("live-markdown-inspector-dark", to: directory)

        // The first load usually hits the on-disk cache, so force a dump to see a real refresh.
        NSApp.appearance = NSAppearance(named: .aqua)
        let refreshStarted = ContinuousClock.now
        let refreshing = Task { await store.refresh(force: true) }
        await snapshot("live-refreshing", to: directory, settle: .milliseconds(800))
        await refreshing.value
        let forcedRefreshTime = ContinuousClock.now - refreshStarted

        // Applications view, read-only: selecting apps never writes; Apply is never pressed here.
        try? await Task.sleep(for: .milliseconds(500))
        store.searchText = ""
        store.sidebarSelection = .applications
        try? await Task.sleep(for: .milliseconds(500))
        if let preview = store.appIndex.summaries.first(where: { $0.app.bundleID == "com.apple.Preview" }) {
            store.selectApp(preview.app.url)
            await snapshot("live-apps-preview", to: directory)
        }
        if let busiest = store.appIndex.summaries.max(by: { $0.explicitCount + $0.offeredCount < $1.explicitCount + $1.offeredCount }) {
            store.selectApp(busiest.app.url)
            await snapshot("live-apps-busiest", to: directory)
            store.showsOfferedKinds = true
            await snapshot("live-apps-busiest-offered", to: directory)
            store.showsOfferedKinds = false
        }
        store.selectApp(nil)
        try? await Task.sleep(for: .milliseconds(300))
        store.sidebarSelection = .common

        writeLiveStats(store: store, loadTime: loadTime, forcedRefreshTime: forcedRefreshTime, to: directory.appending(path: "live-stats.md"))
    }

    private static func writeLiveStats(store: KindStore, loadTime: Duration, forcedRefreshTime: Duration, to url: URL) {
        let kinds = store.kinds
        var lines = ["# Live data stats", "", "- First load: \(loadTime.formatted(.units(allowed: [.seconds, .milliseconds])))",
                     "- Forced refresh: \(forcedRefreshTime.formatted(.units(allowed: [.seconds, .milliseconds])))",
                     "- Kinds: \(kinds.count), common (catalog): \(store.commonKinds.count), choosable (≥2 candidates): \(store.choosableKinds.count), split: \(store.splitKinds.count)", ""]

        lines.append("## Common, in order")
        lines += store.commonKinds.enumerated().map { "\($0.offset + 1). \($0.element.name) (rank \($0.element.commonRank ?? 0))" }
        lines.append("")

        lines.append("## Categories (all / choosable)")
        for category in KindCategory.allCases {
            lines.append("- \(category.rawValue): \(kinds.filter { $0.category == category }.count) / \(store.choosableKinds.filter { $0.category == category }.count)")
        }

        lines += ["", "## Split Kinds"]
        for kind in store.splitKinds {
            let members = kind.members.map { "\($0.target.displayName) → \($0.defaultApp?.name ?? "none")" }.joined(separator: ", ")
            lines.append("- \(kind.name) [\(kind.id)]: \(members)")
        }

        let suspicious = kinds.filter { $0.name.isEmpty || $0.name.contains(".") && !$0.name.contains(" ") || $0.name == $0.name.lowercased() }
        lines += ["", "## Suspicious names (\(suspicious.count))"]
        lines += suspicious.prefix(60).map { "- \"\($0.name)\" [\($0.id)] utis: \($0.utis.prefix(3).joined(separator: ", "))" }

        let schemeOnly = kinds.filter { $0.utis.isEmpty }
        lines += ["", "## Scheme-only Kinds (\(schemeOnly.count), first 40)"]
        lines += schemeOnly.prefix(40).map { "- \($0.name): \($0.schemes.joined(separator: ", ")) — \($0.category.rawValue), \($0.candidates.count) apps" }

        let noDefault = kinds.filter { $0.members.allSatisfy { $0.defaultApp == nil } }
        lines += ["", "## Kinds with no default app at all: \(noDefault.count)"]
        lines += noDefault.prefix(20).map { "- \($0.name) [\($0.id)]" }

        lines += ["", "## Most candidates"]
        for kind in kinds.sorted(by: { $0.candidates.count > $1.candidates.count }).prefix(15) {
            lines.append("- \(kind.name): \(kind.candidates.count) — \(kind.candidates.map(\.name).joined(separator: ", "))")
        }

        lines += ["", "## Choosable Kinds in Other (first 60)"]
        lines += store.choosableKinds.filter { $0.category == .other }.prefix(60).map { "- \($0.name) [\($0.id)] \($0.utis.first ?? $0.schemes.first ?? "")" }

        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }


    /// Writes the menu bar as text, with shortcuts and enabled state after validation, because
    /// menus can't be captured as images and many items come from SwiftUI rather than our code.
    static func dumpMenus(store: KindStore, to directory: URL, name: String = "menus") async {
        func describe(_ menu: NSMenu, depth: Int) -> [String] {
            // What AppKit does as a menu opens; SwiftUI rebuilds its items here.
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            return menu.items.flatMap { item -> [String] in
                if item.isSeparatorItem { return [String(repeating: "  ", count: depth) + "—"] }
                var line = String(repeating: "  ", count: depth) + item.title
                if !item.keyEquivalent.isEmpty {
                    line += "  [\(modifierText(item.keyEquivalentModifierMask))\(item.keyEquivalent == " " ? "Space" : item.keyEquivalent.uppercased())]"
                }
                if !item.isEnabled { line += "  (disabled)" }
                if item.isHidden { line += "  (hidden)" }
                return [line] + (item.submenu.map { describe($0, depth: depth + 1) } ?? [])
            }
        }
        guard let main = NSApp.mainMenu else { return }
        let text = describe(main, depth: 0).joined(separator: "\n")
        try? text.write(to: directory.appending(path: "\(name).txt"), atomically: true, encoding: .utf8)
    }

    private static func modifierText(_ flags: NSEvent.ModifierFlags) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text
    }

    private static func snapshot(_ name: String, to directory: URL, settle: Duration = .milliseconds(700)) async {
        try? await Task.sleep(for: settle)
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.sheetParent == nil }),
              let image = capture(window)
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    private typealias WindowCapture = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// The SDK marks CGWindowListCreateImage unavailable, but it still captures the app's own
    /// windows without Screen Recording permission, which ScreenCaptureKit does not.
    private static func capture(_ window: NSWindow) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: WindowCapture.self)
        let optionOnScreenBelowWindow: UInt32 = 1 << 2
        let optionIncludingWindow: UInt32 = 1 << 3
        let imageOptionBoundsIgnoreFraming: UInt32 = 1 << 0

        // A sheet is its own window, so capture the parent's area from the sheet downward.
        if let sheet = window.attachedSheet, let screen = NSScreen.screens.first {
            let frame = window.frame
            let rect = CGRect(x: frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)
            return capture(rect, optionOnScreenBelowWindow | optionIncludingWindow, CGWindowID(sheet.windowNumber), imageOptionBoundsIgnoreFraming)?.takeRetainedValue()
        }
        return capture(.null, optionIncludingWindow, CGWindowID(window.windowNumber), imageOptionBoundsIgnoreFraming)?.takeRetainedValue()
    }
}
#endif
