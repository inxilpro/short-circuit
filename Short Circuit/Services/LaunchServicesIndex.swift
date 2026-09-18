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
    private var snapshot: LSSnapshot?
    private var inFlight: Task<LSSnapshot, Error>?

    /// Pass a nil `cacheURL` to keep everything in memory (tests).
    init(cacheURL: URL? = LaunchServicesIndex.defaultCacheURL, dumpSource: @escaping DumpSource = LaunchServicesIndex.runDump) {
        self.cacheURL = cacheURL
        self.dumpSource = dumpSource
    }

    func snapshot(forceRefresh: Bool = false) async throws -> LSSnapshot {
        if !forceRefresh {
            if let snapshot { return snapshot }
            if let cached = loadCache() {
                snapshot = cached
                return cached
            }
        }
        return try await refresh()
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
