#if DEBUG
import AppKit
import SwiftUI

/// Walks the window through its main states and writes PNGs, because agents running without
/// Screen Recording permission can't use `screencapture`. Enabled by setting SC_SNAPSHOT_DIR.
enum DebugSnapshotter {
    static var directory: URL? {
        ProcessInfo.processInfo.environment["SC_SNAPSHOT_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    static func run(store: KindStore) async {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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

        if let phone = kind("phone-call") {
            store.selectedKindID = phone.id
            store.setDefault(.messages, for: phone)
            await snapshot("write-confirm-light", to: directory)
            let confirming = Task { await store.confirmPendingChange() }
            await snapshot("write-applying-light", to: directory)
            await confirming.value
            await snapshot("write-results-light", to: directory)
        }

        if let markdown = kind("markdown") {
            store.selectedKindID = markdown.id
            store.pendingChange = nil
            store.setDefault(.preview, for: markdown)
            await store.confirmPendingChange()
            await snapshot("write-partial-failure-light", to: directory)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            await snapshot("write-partial-failure-dark", to: directory)
            NSApp.appearance = NSAppearance(named: .aqua)
        }

        if let heic = kind("heic") {
            store.selectedKindID = heic.id
            store.fixSplit(heic)
            await waitUntilIdle(store)
            await snapshot("write-declined-light", to: directory)
        }

        if let web = kind("web-page") {
            store.selectedKindID = web.id
            store.setDefault(.textEdit, for: web)
            await waitUntilIdle(store)
            await snapshot("write-browser-role-light", to: directory)
        }
    }

    private static func waitUntilIdle(_ store: KindStore) async {
        try? await Task.sleep(for: .milliseconds(100))
        while !store.applyingKindIDs.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
    }

    private static func snapshot(_ name: String, to directory: URL) async {
        try? await Task.sleep(for: .milliseconds(700))
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
