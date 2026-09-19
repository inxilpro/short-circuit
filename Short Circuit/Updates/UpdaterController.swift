import Combine
import Foundation
import Sparkle

/// Owns the one Sparkle updater for the app's lifetime. It is a singleton rather than App state
/// because the menu command is the only thing that needs it, and Commands values are rebuilt often.
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.shouldStart,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Only Release builds check the feed: a Debug build would offer to replace itself with the
    /// published release, and unit tests (hosted in the app) must never touch the network.
    private static var shouldStart: Bool {
        #if DEBUG
        false
        #else
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
        #endif
    }
}
