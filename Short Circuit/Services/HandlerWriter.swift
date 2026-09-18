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
    /// Set when the member was changed as part of the browser-wide `http` call rather than on its own.
    var viaBrowserRole = false

    var id: KindMember.Target { target }
}

/// The calls a change will make, built from live reads. The store shows this to the user and
/// hands the same value back for execution, so what runs is what was reviewed.
nonisolated struct WritePlan: Hashable, Sendable {
    struct Step: Hashable, Sendable {
        var call: KindMember.Target
        var covers: [KindMember.Target]

        var changesBrowser: Bool { call == WritePlan.browserCall }
    }

    static let browserCall = KindMember.Target.scheme("http")
    /// macOS treats these as one "default browser" role. Whether `public.xhtml` really follows
    /// the `http` call is unverified: live data on the dev Mac has it on a different app.
    static let browserTargets: [KindMember.Target] = [
        .scheme("http"), .scheme("https"), .uti("public.html"), .uti("public.xhtml"),
    ]
    static let browserRole = Set(browserTargets)

    var app: URL
    var requested: [KindMember.Target]
    var steps: [Step]
    var skipped: [KindMember.Target]

    init(app: URL, targets: [KindMember.Target], currentHandler: (KindMember.Target) -> URL?) {
        var seen = Set<KindMember.Target>()
        let unique = targets.filter { seen.insert($0).inserted }
        var steps: [Step] = []
        var skipped: [KindMember.Target] = []
        var browserHandled = false

        for target in unique {
            if Self.browserRole.contains(target) {
                guard !browserHandled else { continue }
                browserHandled = true
                // The call changes every browser target, so the plan has to show all of them even
                // when only one was asked for.
                if Self.browserTargets.allSatisfy({ Self.sameApp(currentHandler($0), app) }) {
                    skipped.append(contentsOf: unique.filter(Self.browserRole.contains))
                } else {
                    steps.append(Step(call: Self.browserCall, covers: Self.browserTargets))
                }
            } else if Self.sameApp(currentHandler(target), app) {
                skipped.append(target)
            } else {
                steps.append(Step(call: target, covers: [target]))
            }
        }

        self.app = app
        self.requested = unique
        self.steps = steps
        self.skipped = skipped
    }

    var promptCount: Int { steps.count }

    var changesBrowser: Bool { steps.contains(where: \.changesBrowser) }

    var affectedTargets: [KindMember.Target] { steps.flatMap(\.covers) }

    /// True when running `self` would make no call that `approved` didn't already include.
    func isWithin(_ approved: WritePlan) -> Bool {
        guard Self.sameApp(app, approved.app) else { return false }
        return steps.allSatisfy { step in
            approved.steps.contains { $0.call == step.call && Set(step.covers).isSubset(of: $0.covers) }
        }
    }

    static func sameApp(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.standardizedFileURL.resolvingSymlinksInPath().path == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

nonisolated enum WriteExecution: Hashable, Sendable {
    case completed([MemberResult])
    /// The system changed since the plan was approved and running it now would make calls the
    /// user never saw. Nothing was changed; the fresh plan needs its own approval.
    case needsApproval(WritePlan)
}

nonisolated protocol HandlerWriting: Sendable {
    func plan(app: AppRef, targets: [KindMember.Target]) async -> WritePlan
    func execute(_ approved: WritePlan) async -> WriteExecution
    func currentHandler(for target: KindMember.Target) async -> AppRef?
}

/// The raw Launch Services operations, separated so the apply logic can run against a simulated
/// system in tests, previews, and snapshot runs.
nonisolated protocol HandlerBackend: Sendable {
    func currentHandler(for target: KindMember.Target) async -> URL?
    func setHandler(_ app: URL, for target: KindMember.Target) async throws
}

nonisolated struct HandlerWriter<Backend: HandlerBackend>: HandlerWriting {
    var backend: Backend
    var rereadDelay: Duration = .milliseconds(250)
    var rereadAttempts = 6

    func currentHandler(for target: KindMember.Target) async -> AppRef? {
        await backend.currentHandler(for: target).map(HandlerService.appRef(for:))
    }

    func plan(app: AppRef, targets: [KindMember.Target]) async -> WritePlan {
        var current: [KindMember.Target: URL?] = [:]
        for target in targets + WritePlan.browserTargets where current[target] == nil {
            current[target] = await backend.currentHandler(for: target)
        }
        return WritePlan(app: app.url, targets: targets) { current[$0] ?? nil }
    }

    /// Re-plans from live reads first and refuses to run anything wider than what was approved.
    /// Calls run one at a time so macOS shows its consent prompts one after another.
    func execute(_ approved: WritePlan) async -> WriteExecution {
        let fresh = await plan(app: HandlerService.appRef(for: approved.app), targets: approved.requested)
        guard fresh.isWithin(approved) else { return .needsApproval(fresh) }

        var results: [MemberResult] = []
        for target in fresh.skipped {
            results.append(MemberResult(target: target, outcome: .skipped(.alreadyDefault), handlerAfter: await currentHandler(for: target)))
        }
        for step in fresh.steps {
            results.append(contentsOf: await perform(step, app: fresh.app))
        }
        return .completed(results)
    }

    private func perform(_ step: WritePlan.Step, app: URL) async -> [MemberResult] {
        var callError: NSError?
        do {
            try await backend.setHandler(app, for: step.call)
        } catch let error as NSError {
            callError = error
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
                viaBrowserRole: target != step.call
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

    static func isRejectedBeforeConsent(_ error: NSError) -> Bool {
        error.domain == NSCocoaErrorDomain && error.code == NSFileReadUnknownError
    }

    private static func outcome(for error: NSError) -> MemberResult.Outcome {
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
            return .declined
        }
        // Cocoa's own text for 256 ("The file couldn't be opened") reads as a bug in this app.
        // On macOS 26.6 it means Launch Services refused the type outright, before any prompt.
        let message = isRejectedBeforeConsent(error)
            ? "macOS rejected changing the default app for this type without asking. Nothing was changed."
            : error.localizedDescription
        return .failed(domain: error.domain, code: error.code, message: message)
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
}

typealias LiveHandlerWriter = HandlerWriter<WorkspaceHandlerBackend>

nonisolated extension HandlerWriter where Backend == WorkspaceHandlerBackend {
    static var live: Self { HandlerWriter(backend: WorkspaceHandlerBackend()) }
}
