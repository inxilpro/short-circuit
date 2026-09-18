import SwiftUI

@main
struct Short_CircuitApp: App {
    @State private var store = Self.makeStore()

    /// Snapshot runs drive the write UI automatically, so they must never reach the real setter,
    /// and they pair the simulated writer with the sample data it was built from.
    private static func makeStore() -> KindStore {
        #if DEBUG
        if DebugSnapshotter.directory != nil {
            // A throwaway defaults domain, so snapshot runs neither inherit nor overwrite the
            // view state a person left behind.
            let suite = "com.inxilpro.short-circuit.snapshots"
            UserDefaults.standard.removePersistentDomain(forName: suite)
            let defaults = UserDefaults(suiteName: suite)
            if DebugSnapshotter.isLive {
                return KindStore(provider: LiveKindProvider(), writer: RefusingHandlerWriter(), defaults: defaults)
            }
            return KindStore(provider: SampleKindProvider(delay: .milliseconds(400)), writer: SimulatedHandlerWriter.demo, defaults: defaults)
        }
        #endif
        return KindStore(provider: LiveKindProvider(), writer: LiveHandlerWriter.live, defaults: .standard)
    }

    var body: some Scene {
        Window("Short Circuit", id: "browser") {
            ContentView()
                .environment(store)
        }
        .defaultSize(width: 1100, height: 680)
        .commands {
            AppCommands(store: store)
        }
    }
}
