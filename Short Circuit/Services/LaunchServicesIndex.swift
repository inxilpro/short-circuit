import Foundation
import Synchronization

nonisolated enum LaunchServicesIndexError: Error, LocalizedError {
    case lsregisterFailed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .lsregisterFailed(let status, let message):
            "lsregister exited with status \(status). \(message)"
        }
    }
}

/// Owns the parsed Launch Services snapshot: serves the on-disk cache first and re-runs
/// `lsregister -dump` (about 4 seconds, 32 MB of output) only when asked or when no cache exists.
actor LaunchServicesIndex {
    typealias DumpSource = @Sendable () async throws -> Data
    /// Launch Services' current database sequence number, or nil when it can't be read cheaply.
    typealias SequenceSource = @Sendable () async -> Int?

    static let lsregisterURL = URL(fileURLWithPath:
        "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister")

    static var defaultCacheURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = Bundle.main.bundleIdentifier ?? "com.cmorrell.Short-Circuit"
        return caches.appending(path: folder).appending(path: "ls-snapshot.json")
    }

    private let cacheURL: URL?
    private let dumpSource: DumpSource
    private let sequenceSource: SequenceSource
    private var snapshot: LSSnapshot?
    private var inFlight: Task<LSSnapshot, Error>?
    /// Set once a dump has run in this session, so an unreadable sequence number triggers at most one
    /// background refresh.
    private var hasDumped = false

    /// Pass a nil `cacheURL` to keep everything in memory (tests).
    init(
        cacheURL: URL? = LaunchServicesIndex.defaultCacheURL,
        dumpSource: @escaping DumpSource = LaunchServicesIndex.runDump,
        sequenceSource: @escaping SequenceSource = LaunchServicesIndex.readSequenceNumber
    ) {
        self.cacheURL = cacheURL
        self.dumpSource = dumpSource
        self.sequenceSource = sequenceSource
    }

    /// Serves the in-memory or disk snapshot while Launch Services' sequence number still matches it;
    /// a changed number (an app was installed, removed or re-registered) re-dumps first. When the number
    /// can't be read, the cached snapshot is served and a refresh runs in the background, so the next
    /// call returns the fresh one.
    func snapshot(forceRefresh: Bool = false) async throws -> LSSnapshot {
        if !forceRefresh, let current = snapshot ?? loadCache() {
            snapshot = current
            switch await isCurrent(current) {
            case true?:
                return current
            case false?:
                return try await refresh()
            case nil:
                if !hasDumped { Task { _ = try? await self.refresh() } }
                return current
            }
        }
        return try await refresh()
    }

    private func isCurrent(_ snapshot: LSSnapshot) async -> Bool? {
        guard let stored = snapshot.cacheSequenceNumber, let live = await sequenceSource() else { return nil }
        return stored == live
    }

    func refresh() async throws -> LSSnapshot {
        if let inFlight { return try await inFlight.value }
        let source = dumpSource
        let task = Task.detached(priority: .userInitiated) {
            LSDumpParser.parse(try await source())
        }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        hasDumped = true
        snapshot = fresh
        saveCache(fresh)
        return fresh
    }

    private func loadCache() -> LSSnapshot? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        guard let cached = try? JSONDecoder().decode(LSSnapshot.self, from: data),
              cached.formatVersion == LSSnapshot.currentFormatVersion
        else { return nil }
        return cached
    }

    private func saveCache(_ snapshot: LSSnapshot) {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: cacheURL, options: .atomic)
        } catch {
            // The cache only saves a re-dump on next launch; failing to write it isn't worth surfacing.
        }
    }

    /// Reads only the dump's header, which carries `CacheSequenceNum`, then stops lsregister; about 30 ms
    /// instead of the full 4-second dump.
    @Sendable static func readSequenceNumber() async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = lsregisterURL
                process.arguments = ["-dump"]
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else {
                    continuation.resume(returning: nil)
                    return
                }
                var header = Data()
                var number: Int?
                // The header is a few KB; giving up after 256 KB bounds the read if the format changes.
                while number == nil, header.count < 256 * 1024 {
                    let chunk = output.fileHandleForReading.availableData
                    guard !chunk.isEmpty else { break }
                    header.append(chunk)
                    number = sequenceNumber(inHeader: header)
                }
                if process.isRunning { process.terminate() }
                try? output.fileHandleForReading.close()
                process.waitUntilExit()
                continuation.resume(returning: number)
            }
        }
    }

    static func sequenceNumber(inHeader data: Data) -> Int? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") where line.hasPrefix("CacheSequenceNum:") {
            // A line cut off mid-read has no newline after it yet, so only accept one followed by more text.
            guard text.contains(line + "\n") else { return nil }
            return Int(line.dropFirst("CacheSequenceNum:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    @Sendable static func runDump() async throws -> Data {
        try await run(lsregisterURL, arguments: ["-dump"])
    }

    /// Runs a process on background threads and returns its stdout. Both pipes are drained at the same
    /// time: reading one to EOF first would let a child that fills the other pipe block forever.
    static func run(_ executable: URL, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                let errorData = ErrorBuffer()
                let drained = DispatchGroup()
                drained.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    errorData.data.withLock { $0 = data }
                    drained.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                drained.wait()
                process.waitUntilExit()

                if process.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = errorData.data.withLock { String(decoding: $0, as: UTF8.self) }
                    continuation.resume(throwing: LaunchServicesIndexError.lsregisterFailed(status: process.terminationStatus, message: message))
                }
            }
        }
    }

    private final class ErrorBuffer: Sendable {
        let data = Mutex(Data())
    }
}
