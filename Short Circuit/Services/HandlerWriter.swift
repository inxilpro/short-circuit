import AppKit
import Foundation
import UniformTypeIdentifiers

nonisolated struct MemberResult: Identifiable, Hashable, Sendable {
    enum SkipReason: Hashable, Sendable {
        case alreadyDefault
        /// macOS doesn't list the app for this member, so the setter would reject it; no call is made.
        case notSupported(AppRef)
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

/// The calls a change will make, built from live reads immediately before they run.
nonisolated struct WritePlan: Hashable, Sendable {
    struct Step: Hashable, Sendable {
        var call: KindMember.Target
        var covers: [KindMember.Target]

        var changesBrowser: Bool { call == WritePlan.browserCall }
    }

    static let browserCall = KindMember.Target.scheme("http")
    /// macOS changes these together as the "default browser". Measured by hand on macOS 26.6.2:
    /// one `http` call moved all three, while `public.xhtml` stayed put, so XHTML is set on its own.
    static let browserTargets: [KindMember.Target] = [
        .scheme("http"), .scheme("https"), .uti("public.html"),
    ]
    static let browserRole = Set(browserTargets)

    var app: URL
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
        self.steps = steps
        self.skipped = skipped
    }

    /// macOS confirms every call, extensions included: they're set through their generated type,
    /// which prompts like any other type (extension spike 2, macOS 26.6.2).
    var promptCount: Int { steps.count }

    var changeCount: Int { steps.count }

    var changesBrowser: Bool { steps.contains(where: \.changesBrowser) }

    var affectedTargets: [KindMember.Target] { steps.flatMap(\.covers) }

    /// Safari alone has three spellings (`/Applications`, the Cryptex and Preboot paths), and
    /// a re-read can return any of them.
    static func sameApp(_ lhs: URL?, _ rhs: URL?) -> Bool {
        AppIdentity.same(lhs, rhs)
    }
}

extension KindMember.Target {
    nonisolated var isFileExtension: Bool {
        if case .fileExtension = self { true } else { false }
    }
}

/// An extension is set by assigning its generated `dyn.` type, which only makes sense while no
/// declared type claims the extension. Were a declared type to claim it, `UTType(filenameExtension:)`
/// would return that type and the call would change its handler for every extension it covers, which
/// is how the removed error-256 fallback could touch a type nobody approved. Both the live and the
/// simulated backend run this immediately before setting.
nonisolated enum ExtensionTargetGuard {
    static let errorDomain = "ShortCircuit.ExtensionTarget"

    /// `declaredType` returns the declared (non-`dyn.`) type the extension resolves to as a flat
    /// file or a package, or nil when only a `dyn.` type claims it.
    static func check(_ ext: String, declaredType: (String) -> String?) throws {
        guard isPlainExtension(ext) else {
            throw NSError(domain: errorDomain, code: 1, userInfo: [
                NSLocalizedDescriptionKey: "“\(ext)” isn’t a plain file extension. Nothing was changed.",
            ])
        }
        if let identifier = declaredType(ext) {
            throw NSError(domain: errorDomain, code: 2, userInfo: [
                NSLocalizedDescriptionKey: "macOS now resolves .\(ext) files to \(identifier), a declared type. Setting it through a file would change that type too, so nothing was changed.",
            ])
        }
    }

    /// Only a bare extension can be looked up; a path or a dotted name means something has gone wrong.
    static func isPlainExtension(_ ext: String) -> Bool {
        !ext.isEmpty && !ext.hasPrefix(".") && !ext.contains("/") && !ext.contains(":") && ext != ".."
    }

    /// The generated type to assign, once `check` has confirmed no declared type claims the extension.
    static func dynamicType(for ext: String) throws -> UTType {
        guard let type = UTType(filenameExtension: ext), type.isDynamic else {
            throw NSError(domain: errorDomain, code: 3, userInfo: [
                NSLocalizedDescriptionKey: "macOS has no type for .\(ext) files, so its default app can't be changed.",
            ])
        }
        return type
    }

    /// The live lookup: the declared type for a flat file or a package with this extension.
    static func liveDeclaredType(_ ext: String) -> String? {
        [UTType.data, .package]
            .compactMap { UTType(filenameExtension: ext, conformingTo: $0) }
            .first { !$0.isDynamic }?
            .identifier
    }
}

/// Reported before each setter call so the UI can explain the system prompt that follows.
nonisolated struct WriteProgress: Hashable, Sendable {
    /// 1-based position of the call about to be made.
    var step: Int
    var total: Int
    var call: WritePlan.Step
}

nonisolated protocol HandlerWriting: Sendable {
    /// Plans from live reads and runs that plan straight away. Each setter call is gated by its own
    /// macOS consent prompt, so the app asks nothing further. `onProgress` runs before each call;
    /// returning false stops there, leaving that call and the rest unmade and unreported.
    func apply(
        app: AppRef,
        targets: [KindMember.Target],
        onProgress: @escaping @MainActor @Sendable (WriteProgress) -> Bool
    ) async -> [MemberResult]
    func currentHandler(for target: KindMember.Target) async -> AppRef?
}

/// The raw Launch Services operations, separated so the apply logic can run against a simulated
/// system in tests, previews, and snapshot runs.
nonisolated protocol HandlerBackend: Sendable {
    func currentHandler(for target: KindMember.Target) async -> URL?
    func setHandler(_ app: URL, for target: KindMember.Target) async throws
}

nonisolated struct HandlerWriter<Backend: HandlerBackend>: HandlerWriting {
    /// macOS 26.6 reports a declined consent prompt with the same Cocoa 256 it uses to refuse a type
    /// outright, so only the clock tells them apart. A refusal comes back immediately (measured at
    /// 0.0 s in the spikes), while a prompted call can't return before someone has seen the prompt and
    /// clicked: the answered prompts we measured took 3–4 s, and even the quickest human answer is a
    /// few hundred milliseconds. Half a second sits well clear of both, so a slow machine won't turn a
    /// refusal into a decline, and nobody can answer a prompt faster than this.
    static var promptThreshold: Duration { .milliseconds(500) }

    var backend: Backend
    var rereadDelay: Duration = .milliseconds(250)
    var rereadAttempts = 6
    /// Injected so tests can make a call look slow without sleeping.
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }

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

    /// Calls run one at a time so macOS shows its consent prompts one after another.
    func apply(
        app: AppRef,
        targets: [KindMember.Target],
        onProgress: @escaping @MainActor @Sendable (WriteProgress) -> Bool
    ) async -> [MemberResult] {
        let plan = await plan(app: app, targets: targets)

        var results: [MemberResult] = []
        for target in plan.skipped {
            results.append(MemberResult(target: target, outcome: .skipped(.alreadyDefault), handlerAfter: await currentHandler(for: target)))
        }
        for (index, step) in plan.steps.enumerated() {
            guard await onProgress(WriteProgress(step: index + 1, total: plan.steps.count, call: step)) else { break }
            results.append(contentsOf: await perform(step, app: plan.app))
        }
        return results
    }

    private func perform(_ step: WritePlan.Step, app: URL) async -> [MemberResult] {
        var callError: NSError?
        let started = now()
        do {
            try await backend.setHandler(app, for: step.call)
        } catch let error as NSError {
            callError = error
        }
        let elapsed = now() - started

        var results: [MemberResult] = []
        for target in step.covers {
            let after = callError == nil
                ? await reread(target, expecting: app)
                : await backend.currentHandler(for: target)

            let outcome: MemberResult.Outcome
            if WritePlan.sameApp(after, app) {
                outcome = .changed
            } else if let callError {
                outcome = Self.outcome(for: callError, elapsed: elapsed)
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

    static func outcome(for error: NSError, elapsed: Duration) -> MemberResult.Outcome {
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
            return .declined
        }
        // A 256 that took long enough for the prompt to be answered is a decline, not a refusal.
        if isRejectedBeforeConsent(error), elapsed >= promptThreshold {
            return .declined
        }
        // Cocoa's own text for 256 ("The file couldn't be opened") reads as a bug in this app.
        // On macOS 26.6 an immediate one means Launch Services refused the type before any prompt.
        let message = isRejectedBeforeConsent(error)
            ? "macOS rejected this app for this type without asking. It only allows apps that declare support for the type. Nothing was changed."
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
        case .fileExtension(let ext):
            reader.defaultApplicationURL(forFilenameExtension: ext)
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
        case .fileExtension(let ext):
            // Setting the file itself only pins that one file, via an xattr (extension spike 2); the
            // generated type is what moves every file with the extension.
            try ExtensionTargetGuard.check(ext, declaredType: ExtensionTargetGuard.liveDeclaredType)
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: ExtensionTargetGuard.dynamicType(for: ext))
        }
    }

    /// What a target is set through, so tests can check the mapping without calling a setter.
    enum ResolvedCall: Hashable, Sendable {
        case contentType(String)
        case urlScheme(String)
    }

    static func resolvedCall(for target: KindMember.Target) throws -> ResolvedCall {
        switch target {
        case .uti(let identifier):
            guard UTType(identifier) != nil else {
                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Unknown type \(identifier)"])
            }
            return .contentType(identifier)
        case .scheme(let scheme):
            return .urlScheme(scheme)
        case .fileExtension(let ext):
            try ExtensionTargetGuard.check(ext, declaredType: ExtensionTargetGuard.liveDeclaredType)
            return .contentType(try ExtensionTargetGuard.dynamicType(for: ext).identifier)
        }
    }
}

typealias LiveHandlerWriter = HandlerWriter<WorkspaceHandlerBackend>

nonisolated extension HandlerWriter where Backend == WorkspaceHandlerBackend {
    static var live: Self { HandlerWriter(backend: WorkspaceHandlerBackend()) }
}
