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
        NSApp.terminate(nil)
    }

    private static func snapshot(_ name: String, to directory: URL) async {
        try? await Task.sleep(for: .milliseconds(700))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let image = captureWindow(CGWindowID(window.windowNumber))
        else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
    }

    private typealias WindowCapture = @convention(c) (CGRect, UInt32, CGWindowID, UInt32) -> Unmanaged<CGImage>?

    /// The SDK marks CGWindowListCreateImage unavailable, but it still captures the app's own
    /// windows without Screen Recording permission, which ScreenCaptureKit does not.
    private static func captureWindow(_ windowID: CGWindowID) -> CGImage? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: WindowCapture.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let imageOptionBoundsIgnoreFraming: UInt32 = 1 << 0
        return capture(.null, optionIncludingWindow, windowID, imageOptionBoundsIgnoreFraming)?.takeRetainedValue()
    }
}
#endif
