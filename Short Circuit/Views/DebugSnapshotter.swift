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

    static func run(store: KindStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
        NSApp.terminate(nil)
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

        // public.markdown is unsettable in the sample data, so this is one call and a clean result.
        if let markdown = kind("markdown") {
            store.selectedKindID = markdown.id
            await snapshot("inert-member-light", to: directory)
            await store.setDefault(.preview, for: markdown)
            await snapshot("inert-member-after-set-light", to: directory)
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
