import SwiftUI

@main
struct Short_CircuitApp: App {
    @State private var store = Self.makeStore()

    /// Snapshot runs drive the write UI automatically, so they must never reach the real setter,
    /// and they pair the simulated writer with the sample data it was built from.
    private static func makeStore() -> KindStore {
        #if DEBUG
        if DebugSnapshotter.directory != nil {
            return KindStore(provider: SampleKindProvider(delay: .milliseconds(400)), writer: SimulatedHandlerWriter.demo)
        }
        #endif
        return KindStore(provider: LiveKindProvider(), writer: LiveHandlerWriter.live)
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
