import Foundation
@testable import Short_Circuit

// Resolved relative to this source file rather than the test bundle so fixtures load the same way
// whether or not the synchronized group copies them as resources.
nonisolated enum Fixture {
    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func snapshot(_ name: String) throws -> LSSnapshot {
        LSDumpParser.parse(try data(name))
    }

    /// No live UTType lookups, so results depend only on the fixture.
    static let offlineBuilder = KindBuilder(describe: { _ in nil }, liveSupertypes: { _ in [] })
}
