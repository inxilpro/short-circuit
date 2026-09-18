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
        /// Throws Cocoa error 256 before any prompt, as `public.markdown` does on macOS 26.6.
        case rejectBeforeConsent
    }

    struct Call: Hashable, Sendable {
        enum Kind: Hashable, Sendable {
            case target(KindMember.Target)
            case file(extension: String)
        }

        var kind: Kind
        var app: URL
    }

    private struct State {
        var handlers: [KindMember.Target: URL]
        var calls: [Call] = []
    }

    private let state: Mutex<State>
    private let behaviors: [KindMember.Target: Behavior]
    private let fileFallbackSucceeds: Bool
    private let latency: Duration

    init(
        handlers: [KindMember.Target: URL],
        behaviors: [KindMember.Target: Behavior] = [:],
        fileFallbackSucceeds: Bool = false,
        latency: Duration = .zero
    ) {
        state = Mutex(State(handlers: handlers))
        self.behaviors = behaviors
        self.fileFallbackSucceeds = fileFallbackSucceeds
        self.latency = latency
    }

    convenience init(kinds: [Kind], behaviors: [KindMember.Target: Behavior] = [:], fileFallbackSucceeds: Bool = false, latency: Duration = .zero) {
        var handlers: [KindMember.Target: URL] = [:]
        for member in kinds.flatMap(\.members) {
            handlers[member.target] = member.defaultApp?.url
        }
        self.init(handlers: handlers, behaviors: behaviors, fileFallbackSucceeds: fileFallbackSucceeds, latency: latency)
    }

    var calls: [Call] {
        state.withLock { $0.calls }
    }

    func currentHandler(for target: KindMember.Target) async -> URL? {
        state.withLock { $0.handlers[target] }
    }

    func setHandler(_ app: URL, for target: KindMember.Target) async throws {
        state.withLock { $0.calls.append(Call(kind: .target(target), app: app)) }
        if latency > .zero {
            try? await Task.sleep(for: latency)
        }

        switch behaviors[target] ?? .accept {
        case .accept:
            state.withLock { state in
                state.handlers[target] = app
                // Mirrors macOS locking the browser types together behind the http scheme.
                if WritePlan.browserRole.contains(target) {
                    for member in WritePlan.browserRole {
                        state.handlers[member] = app
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

    func setHandler(_ app: URL, forFileAt file: URL) async throws {
        state.withLock { $0.calls.append(Call(kind: .file(extension: file.pathExtension), app: app)) }
        guard fileFallbackSucceeds else { throw CocoaError(.fileReadUnknown) }
        state.withLock { state in
            for (target, behavior) in behaviors where behavior == .rejectBeforeConsent {
                state.handlers[target] = app
            }
        }
    }
}

typealias SimulatedHandlerWriter = HandlerWriter<SimulatedHandlerBackend>

nonisolated extension HandlerWriter where Backend == SimulatedHandlerBackend {
    /// Accepts every change against the sample data; used where nothing should look alarming.
    static var preview: Self {
        HandlerWriter(backend: SimulatedHandlerBackend(kinds: SampleKindProvider.kinds), rereadDelay: .zero, rereadAttempts: 0)
    }

    /// Shows every outcome the UI has to handle: Markdown's `public.markdown` is rejected like
    /// on macOS 26.6, `sms` is declined, and everything else is accepted after a prompt-like pause.
    static var demo: Self {
        HandlerWriter(
            backend: SimulatedHandlerBackend(
                kinds: SampleKindProvider.kinds,
                behaviors: [
                    .uti("public.markdown"): .rejectBeforeConsent,
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
