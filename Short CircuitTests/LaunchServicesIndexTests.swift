import Foundation
import Synchronization
import Testing
@testable import Short_Circuit

struct LaunchServicesIndexTests {
    private final class DumpCounter: Sendable {
        let count = Mutex(0)
    }

    @Test func servesCacheFirstAndRefreshesOnDemand() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: "LaunchServicesIndexTests-\(UUID().uuidString)")
            .appending(path: "ls-snapshot.json")
        defer { try? FileManager.default.removeItem(at: cacheURL.deletingLastPathComponent()) }

        let fixture = try Fixture.data("markdown.lsdump")
        let counter = DumpCounter()
        let source: LaunchServicesIndex.DumpSource = {
            counter.count.withLock { $0 += 1 }
            return fixture
        }

        let first = LaunchServicesIndex(cacheURL: cacheURL, dumpSource: source)
        let fresh = try await first.snapshot()
        #expect(counter.count.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        _ = try await first.snapshot()
        #expect(counter.count.withLock { $0 } == 1, "The in-memory snapshot is reused")

        let second = LaunchServicesIndex(cacheURL: cacheURL, dumpSource: source)
        let cached = try await second.snapshot()
        #expect(counter.count.withLock { $0 } == 1, "A new index loads the disk cache instead of re-dumping")
        #expect(cached.types == fresh.types)
        #expect(cached.claims == fresh.claims)
        #expect(cached.handlerPrefs == fresh.handlerPrefs)

        _ = try await second.snapshot(forceRefresh: true)
        #expect(counter.count.withLock { $0 } == 2)
    }
}

struct ProcessRunnerTests {
    /// Writes past the pipe buffer on stderr before touching stdout; a runner that drains stdout first
    /// would block forever.
    @Test(.timeLimit(.minutes(1))) func drainsBothPipesConcurrently() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\\\0' e >&2; head -c 300000 /dev/zero | tr '\\\\0' o"
        let data = try await LaunchServicesIndex.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        #expect(data.count == 300_000)
    }

    @Test(.timeLimit(.minutes(1))) func reportsFailureWithStderr() async throws {
        let script = "head -c 300000 /dev/zero | tr '\\\\0' o; echo broken >&2; exit 3"
        await #expect(throws: LaunchServicesIndexError.self) {
            try await LaunchServicesIndex.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        }
        do {
            _ = try await LaunchServicesIndex.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
        } catch LaunchServicesIndexError.lsregisterFailed(let status, let message) {
            #expect(status == 3)
            #expect(message.contains("broken"))
        }
    }
}
