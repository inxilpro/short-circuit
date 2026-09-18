import AppKit
import Foundation
import UniformTypeIdentifiers

nonisolated struct MemberResult: Identifiable, Hashable, Sendable {
    enum SkipReason: Hashable, Sendable {
        case alreadyDefault
    }

    enum Outcome: Hashable, Sendable {
        case changed
        /// The setter reported success but the re-read still shows another app. On macOS 26 the
        /// setter waits for the consent prompt, so this almost always means the user declined.
        case unchangedAfterSuccess
        case declined
        case failed(domain: String, code: Int, message: String)
        case skipped(SkipReason)
    }

    var target: KindMember.Target
    var outcome: Outcome
    var handlerAfter: AppRef?
    /// Set when the change was made through the `http` scheme because macOS locks the browser
    /// types together.
    var viaBrowserRole = false
    var usedFileFallback = false

    var id: KindMember.Target { target }
}

nonisolated protocol HandlerWriting: Sendable {
    func apply(app: AppRef, to members: [KindMember.Target]) async -> [MemberResult]
    func currentHandler(for target: KindMember.Target) async -> AppRef?
}

/// The raw Launch Services operations, separated so the apply logic can run against a simulated
/// system in tests, previews, and snapshot runs.
nonisolated protocol HandlerBackend: Sendable {
    func currentHandler(for target: KindMember.Target) async -> URL?
    func setHandler(_ app: URL, for target: KindMember.Target) async throws
    func setHandler(_ app: URL, forFileAt file: URL) async throws
}

/// Groups targets into the setter calls that will actually be made. Each step costs at most one
/// consent prompt.
nonisolated struct WritePlan: Sendable {
    struct Step: Hashable, Sendable {
        var call: KindMember.Target
        var covers: [KindMember.Target]
    }

    static let browserCall = KindMember.Target.scheme("http")
    static let browserRole: Set<KindMember.Target> = [
        .scheme("http"), .scheme("https"), .uti("public.html"), .uti("public.xhtml"),
    ]

    var steps: [Step]
    var skipped: [KindMember.Target]

    init(app: URL, targets: [KindMember.Target], currentHandler: (KindMember.Target) -> URL?) {
        var steps: [Step] = []
        var skipped: [KindMember.Target] = []
        var seen = Set<KindMember.Target>()
        let unique = targets.filter { seen.insert($0).inserted }

        let browserTargets = unique.filter(Self.browserRole.contains)
        let browserStepIndex = browserTargets.isEmpty ? nil : unique.firstIndex(where: Self.browserRole.contains)

        for (index, target) in unique.enumerated() {
            if Self.browserRole.contains(target) {
                guard index == browserStepIndex else { continue }
                if browserTargets.allSatisfy({ Self.sameApp(currentHandler($0), app) }) {
                    skipped.append(contentsOf: browserTargets)
                } else {
                    steps.append(Step(call: Self.browserCall, covers: browserTargets))
                }
            } else if Self.sameApp(currentHandler(target), app) {
                skipped.append(target)
            } else {
                steps.append(Step(call: target, covers: [target]))
            }
        }
        self.steps = steps
        self.skipped = skipped
    }

    var promptCount: Int { steps.count }

    static func sameApp(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

nonisolated struct HandlerWriter<Backend: HandlerBackend>: HandlerWriting {
    var backend: Backend
    var rereadDelay: Duration = .milliseconds(250)
    var rereadAttempts = 6

    func currentHandler(for target: KindMember.Target) async -> AppRef? {
        await backend.currentHandler(for: target).map(HandlerService.appRef(for:))
    }

    /// Runs one call at a time so macOS shows its consent prompts one after another.
    func apply(app: AppRef, to members: [KindMember.Target]) async -> [MemberResult] {
        var before: [KindMember.Target: URL?] = [:]
        for target in members where before[target] == nil {
            before[target] = await backend.currentHandler(for: target)
        }
        let plan = WritePlan(app: app.url, targets: members) { before[$0] ?? nil }

        var results: [KindMember.Target: MemberResult] = [:]
        for target in plan.skipped {
            results[target] = MemberResult(target: target, outcome: .skipped(.alreadyDefault), handlerAfter: before[target].flatMap { $0.map(HandlerService.appRef(for:)) })
        }
        for step in plan.steps {
            for result in await perform(step, app: app.url) {
                results[result.target] = result
            }
        }
        var seen = Set<KindMember.Target>()
        return members.filter { seen.insert($0).inserted }.compactMap { results[$0] }
    }

    private func perform(_ step: WritePlan.Step, app: URL) async -> [MemberResult] {
        var callError: NSError?
        var usedFileFallback = false

        do {
            try await backend.setHandler(app, for: step.call)
        } catch let error as NSError {
            callError = error
            if Self.isRejectedBeforeConsent(error), case .uti(let identifier) = step.call,
               let fallback = await setThroughFile(app, typeIdentifier: identifier) {
                usedFileFallback = true
                // Keep the original 256 error if the fallback fails too; it's the one that explains why.
                if case .success = fallback { callError = nil }
            }
        }

        var results: [MemberResult] = []
        for target in step.covers {
            let after = callError == nil
                ? await reread(target, expecting: app)
                : await backend.currentHandler(for: target)

            let outcome: MemberResult.Outcome
            if WritePlan.sameApp(after, app) {
                outcome = .changed
            } else if let callError {
                outcome = Self.outcome(for: callError)
            } else {
                outcome = .unchangedAfterSuccess
            }
            results.append(MemberResult(
                target: target,
                outcome: outcome,
                handlerAfter: after.map(HandlerService.appRef(for:)),
                viaBrowserRole: target != step.call,
                usedFileFallback: usedFileFallback
            ))
        }
        return results
    }

    private func reread(_ target: KindMember.Target, expecting app: URL) async -> URL? {
        var current = await backend.currentHandler(for: target)
        var attempt = 0
        while !WritePlan.sameApp(current, app), attempt < rereadAttempts {
            attempt += 1
            try? await Task.sleep(for: rereadDelay)
            current = await backend.currentHandler(for: target)
        }
        return current
    }

    /// Fallback for types whose content-type setter fails with Cocoa error 256 (seen for
    /// `public.markdown`): set the handler for a sample file of that type instead. UNTESTED on a
    /// real system — see Documentation/write-path.md. Nil when the type has no extension to build
    /// a sample file from.
    private func setThroughFile(_ app: URL, typeIdentifier: String) async -> Result<Void, NSError>? {
        guard let ext = UTType(typeIdentifier)?.preferredFilenameExtension else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ShortCircuit-\(UUID().uuidString)", directoryHint: .isDirectory)
        let file = directory.appending(path: "sample.\(ext)")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: file)
            try await backend.setHandler(app, forFileAt: file)
            return .success(())
        } catch let error as NSError {
            return .failure(error)
        }
    }

    static func isRejectedBeforeConsent(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSFileReadUnknownError
    }

    private static func outcome(for error: NSError) -> MemberResult.Outcome {
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
            return .declined
        }
        return .failed(domain: error.domain, code: error.code, message: error.localizedDescription)
    }
}

/// The only type in the app that changes system defaults.
nonisolated struct WorkspaceHandlerBackend: HandlerBackend {
    private let reader = HandlerService()

    func currentHandler(for target: KindMember.Target) async -> URL? {
        switch target {
        case .uti(let identifier): reader.defaultApplicationURL(forContentType: identifier)
        case .scheme(let scheme): reader.defaultApplicationURL(forScheme: scheme)
        }
    }

    func setHandler(_ app: URL, for target: KindMember.Target) async throws {
        switch target {
        case .uti(let identifier):
            guard let type = UTType(identifier) else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Unknown type \(identifier)"])
            }
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
        case .scheme(let scheme):
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
        }
    }

    func setHandler(_ app: URL, forFileAt file: URL) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenFileAt: file)
    }
}

typealias LiveHandlerWriter = HandlerWriter<WorkspaceHandlerBackend>

nonisolated extension HandlerWriter where Backend == WorkspaceHandlerBackend {
    static var live: Self { HandlerWriter(backend: WorkspaceHandlerBackend()) }
}
