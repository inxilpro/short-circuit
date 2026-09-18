import SwiftUI

@main
struct Short_CircuitApp: App {
    // Swap in LiveKindProvider() here once the Launch Services pipeline lands.
    @State private var store = KindStore(provider: SampleKindProvider(delay: .milliseconds(400)), writer: Self.writer)

    /// Snapshot runs drive the write UI automatically, so they must never reach the real setter.
    private static var writer: any HandlerWriting {
        #if DEBUG
        if DebugSnapshotter.directory != nil {
            return SimulatedHandlerWriter.demo
        }
        #endif
        return LiveHandlerWriter.live
    }

    var body: some Scene {
        Window("Short Circuit", id: "browser") {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") {
                    IconCache.invalidate()
                    Task { await store.refresh(force: true) }
                }
                .keyboardShortcut("r")
            }
        }
    }
}
