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

        let unchanged: LaunchServicesIndex.SequenceSource = { 21148 }
        let first = LaunchServicesIndex(cacheURL: cacheURL, dumpSource: source, sequenceSource: unchanged)
        let fresh = try await first.snapshot()
        #expect(counter.count.withLock { $0 } == 1)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))

        _ = try await first.snapshot()
        #expect(counter.count.withLock { $0 } == 1, "The in-memory snapshot is reused")

        let second = LaunchServicesIndex(cacheURL: cacheURL, dumpSource: source, sequenceSource: unchanged)
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

struct CacheStalenessTests {
    private final class Counter: Sendable {
        let count = Mutex(0)
        var value: Int { count.withLock { $0 } }
    }

    private func makeIndex(sequence: @escaping LaunchServicesIndex.SequenceSource, counter: Counter, cacheURL: URL) throws -> LaunchServicesIndex {
        let fixture = try Fixture.data("markdown.lsdump")
        return LaunchServicesIndex(cacheURL: cacheURL, dumpSource: {
            counter.count.withLock { $0 += 1 }
            return fixture
        }, sequenceSource: sequence)
    }

    private func primedCache() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CacheStalenessTests-\(UUID().uuidString)").appending(path: "ls.json")
        let seed = try makeIndex(sequence: { nil }, counter: Counter(), cacheURL: url)
        _ = try await seed.refresh()
        return url
    }

    @Test func aChangedSequenceNumberRedumps() async throws {
        let url = try await primedCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let counter = Counter()
        let index = try makeIndex(sequence: { 99_999 }, counter: counter, cacheURL: url)
        _ = try await index.snapshot()
        #expect(counter.value == 1)
    }

    @Test func aMatchingSequenceNumberServesTheCache() async throws {
        let url = try await primedCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let counter = Counter()
        let index = try makeIndex(sequence: { 21148 }, counter: counter, cacheURL: url)
        _ = try await index.snapshot()
        _ = try await index.snapshot()
        #expect(counter.value == 0)
    }

    @Test(.timeLimit(.minutes(1))) func anUnreadableSequenceServesTheCacheThenRefreshesInTheBackground() async throws {
        let url = try await primedCache()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let counter = Counter()
        let index = try makeIndex(sequence: { nil }, counter: counter, cacheURL: url)
        let served = try await index.snapshot()
        #expect(served.cacheSequenceNumber == 21148)
        while counter.value == 0 { await Task.yield() }
        _ = try await index.snapshot()
        _ = try await index.snapshot()
        #expect(counter.value == 1, "One background refresh per session")
    }

    @Test func readsTheSequenceNumberFromTheHeader() throws {
        let header = try Fixture.data("markdown.lsdump").prefix(2000)
        #expect(LaunchServicesIndex.sequenceNumber(inHeader: Data(header)) == 21148)
        #expect(LaunchServicesIndex.sequenceNumber(inHeader: Data("CacheSequenceNum:           211".utf8)) == nil, "A cut-off line isn't trusted")
    }

    @Test(.timeLimit(.minutes(1))) func readsThisMacsSequenceNumberCheaply() async throws {
        let start = ContinuousClock.now
        let number = await LaunchServicesIndex.readSequenceNumber()
        #expect(number != nil)
        #expect(ContinuousClock.now - start < .seconds(2), "Only the header is read, not the whole dump")
    }
}
