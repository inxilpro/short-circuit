import Foundation
import Synchronization

/// An in-memory stand-in for Launch Services. It never touches system defaults, so previews,
/// snapshot runs, and tests can drive the real `HandlerWriter` logic safely.
nonisolated final class SimulatedHandlerBackend: HandlerBackend {
    enum Behavior: Sendable {
        /// Behaves like a user who clicks "Use" on the consent prompt.
        case accept
        /// The setter returns normally but nothing changes, like a declined prompt.
        case declineSilently
        /// Throws NSUserCancelledError.
        case declineWithError
        /// Throws Cocoa error 256 before any prompt, as macOS 26.6 does for types it won't assign.
        case rejectBeforeConsent
    }

    struct Call: Hashable, Sendable {
        var target: KindMember.Target
        var app: URL
    }

    private struct State {
        var handlers: [KindMember.Target: URL]
        var calls: [Call] = []
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state: Mutex<State>
    private let behaviors: [KindMember.Target: Behavior]
    private let browserFollowers: Set<KindMember.Target>
    private let latency: Duration

    /// `browserFollowers` are the targets an accepted `http` call also changes. The default is the
    /// measured browser role (http, https, public.html); tests can narrow it to check that results
    /// come from re-reads rather than assumptions.
    init(
        handlers: [KindMember.Target: URL],
        behaviors: [KindMember.Target: Behavior] = [:],
        browserFollowers: Set<KindMember.Target> = WritePlan.browserRole,
        latency: Duration = .zero
    ) {
        state = Mutex(State(handlers: handlers))
        self.behaviors = behaviors
        self.browserFollowers = browserFollowers
        self.latency = latency
    }

    convenience init(
        kinds: [Kind],
        behaviors: [KindMember.Target: Behavior] = [:],
        browserFollowers: Set<KindMember.Target> = WritePlan.browserRole,
        latency: Duration = .zero
    ) {
        var handlers: [KindMember.Target: URL] = [:]
        for member in kinds.flatMap(\.members) {
            handlers[member.target] = member.defaultApp?.url
        }
        self.init(handlers: handlers, behaviors: behaviors, browserFollowers: browserFollowers, latency: latency)
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    var maxConcurrentCalls: Int {
        state.withLock { $0.maxInFlight }
    }

    /// Changes a handler behind the app's back, like another app or System Settings would.
    func changeExternally(_ target: KindMember.Target, to app: URL?) {
        state.withLock { $0.handlers[target] = app }
    }

    func currentHandler(for target: KindMember.Target) async -> URL? {
        state.withLock { $0.handlers[target] }
    }

    func setHandler(_ app: URL, for target: KindMember.Target) async throws {
        state.withLock { state in
            state.calls.append(Call(target: target, app: app))
            state.inFlight += 1
            state.maxInFlight = max(state.maxInFlight, state.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }

        switch behaviors[target] ?? .accept {
        case .accept:
            state.withLock { state in
                state.handlers[target] = app
                if target == WritePlan.browserCall {
                    for follower in browserFollowers {
                        state.handlers[follower] = app
                    }
                }
            }
        case .declineSilently:
            break
        case .declineWithError:
            throw CocoaError(.userCancelled)
        case .rejectBeforeConsent:
            throw CocoaError(.fileReadUnknown)
        }
    }
}

typealias SimulatedHandlerWriter = HandlerWriter<SimulatedHandlerBackend>

nonisolated extension HandlerWriter where Backend == SimulatedHandlerBackend {
    /// Accepts every change against the sample data; used where nothing should look alarming.
    static var preview: Self {
        HandlerWriter(backend: SimulatedHandlerBackend(kinds: SampleKindProvider.kinds), rereadDelay: .zero, rereadAttempts: 0)
    }

    /// Shows every outcome the UI has to handle: `com.apple.rtfd` is rejected with error 256,
    /// `sms` is declined, `public.heif` is cancelled, and everything else is accepted after a
    /// prompt-like pause.
    static var demo: Self {
        HandlerWriter(
            backend: SimulatedHandlerBackend(
                kinds: SampleKindProvider.kinds,
                behaviors: [
                    .uti("com.apple.rtfd"): .rejectBeforeConsent,
                    .scheme("sms"): .declineSilently,
                    .uti("public.heif"): .declineWithError,
                ],
                latency: .milliseconds(1200)
            ),
            rereadDelay: .milliseconds(50),
            rereadAttempts: 2
        )
    }
}
