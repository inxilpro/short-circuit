import Foundation
import Synchronization
import Testing
@testable import Short_Circuit

/// macOS 26.6 answers a declined consent prompt with the same Cocoa 256 it uses to refuse a type
/// outright (hand test C2), so the writer tells them apart by how long the call took.
struct HandlerWriterOutcomeTests {
    private static let app = AppRef(url: URL(fileURLWithPath: "/Applications/Editor.app"), bundleID: "com.example.editor", name: "Editor", version: nil)
    private static let other = URL(fileURLWithPath: "/Applications/Other.app")
    private static let target = KindMember.Target.uti("com.example.type")

    /// Hands out scripted instants, so a call can look slow without anything sleeping.
    private final class FakeClock: Sendable {
        let steps = Mutex<[Duration]>([])
        let base = ContinuousClock.now

        init(_ offsets: [Duration]) { steps.withLock { $0 = offsets } }

        /// Each call returns the next scripted offset, so a call can look as slow as a prompt.
        var now: @Sendable () -> ContinuousClock.Instant {
            { [self] in
                let offset = steps.withLock { $0.isEmpty ? Duration.zero : $0.removeFirst() }
                return base.advanced(by: offset)
            }
        }
    }

    private func isFailure(_ outcome: MemberResult.Outcome?) -> Bool {
        if case .failed = outcome { true } else { false }
    }

    private func writer(_ behavior: SimulatedHandlerBackend.Behavior, elapsed: Duration) -> SimulatedHandlerWriter {
        let backend = SimulatedHandlerBackend(
            handlers: [Self.target: Self.other],
            behaviors: [Self.target: behavior],
            allowedApps: [Self.target: [Self.app.url]]
        )
        // Start of call, end of call.
        let clock = FakeClock([.zero, elapsed])
        return HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 0, now: clock.now)
    }

    private func outcome(_ behavior: SimulatedHandlerBackend.Behavior, elapsed: Duration) async -> MemberResult.Outcome? {
        await writer(behavior, elapsed: elapsed).apply(app: Self.app, targets: [Self.target], onProgress: { _ in true }).first?.outcome
    }

    @Test func aDeclinedPromptIsNotAFailure() async {
        let outcome = await outcome(.declineAfterPrompt, elapsed: .seconds(4))
        #expect(outcome == .declined)
    }

    @Test func anImmediateRejectionStillFails() async throws {
        let outcome = try #require(await outcome(.rejectBeforeConsent, elapsed: .milliseconds(3)))
        guard case .failed(let domain, let code, let message) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == NSFileReadUnknownError)
        #expect(message.contains("without asking"))
    }

    @Test func cancellationIsStillADecline() async {
        #expect(await outcome(.declineWithError, elapsed: .milliseconds(1)) == .declined)
        #expect(await outcome(.declineWithError, elapsed: .seconds(4)) == .declined)
    }

    @Test func theThresholdSitsBetweenARefusalAndAnAnsweredPrompt() {
        let rejection = NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
        let threshold = SimulatedHandlerWriter.promptThreshold
        #expect(isFailure(SimulatedHandlerWriter.outcome(for: rejection, elapsed: threshold - .milliseconds(1))))
        #expect(SimulatedHandlerWriter.outcome(for: rejection, elapsed: threshold) == .declined)
        #expect(threshold > .milliseconds(100), "Faster than any human answer")
        #expect(threshold < .seconds(3), "Slower than the measured refusals, well under a measured prompt")
    }

    @Test func otherErrorsKeepTheirOwnMessageHoweverLongTheyTake() {
        let error = NSError(domain: "ShortCircuit.ExtensionTarget", code: 2, userInfo: [NSLocalizedDescriptionKey: "Nothing was changed."])
        let outcome = SimulatedHandlerWriter.outcome(for: error, elapsed: .seconds(9))
        guard case .failed(_, _, let message) = outcome else {
            Issue.record("Expected a failure, got \(outcome)")
            return
        }
        #expect(message == "Nothing was changed.")
    }

    @Test func aDeclinedUndoIsClassifiedTheSameWay() async throws {
        // Undo runs the same writer the other way round, so a declined prompt reads the same.
        let backend = SimulatedHandlerBackend(
            handlers: [Self.target: Self.app.url],
            behaviors: [Self.target: .declineAfterPrompt],
            allowedApps: [Self.target: [Self.app.url, Self.other]]
        )
        let clock = FakeClock([.zero, .seconds(3)])
        let writer = HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 0, now: clock.now)
        let restore = AppRef(url: Self.other, bundleID: "com.example.other", name: "Other", version: nil)
        let results = await writer.apply(app: restore, targets: [Self.target], onProgress: { _ in true })
        #expect(results.map(\.outcome) == [.declined])
        #expect(results.first?.handlerAfter?.url == Self.app.url, "Still the app it was before the undo")
    }

    @Test func refusalsDoNotWaitForAPromptThatNeverAppears() async {
        let backend = SimulatedHandlerBackend(
            handlers: [Self.target: Self.other],
            behaviors: [Self.target: .rejectBeforeConsent],
            allowedApps: [Self.target: [Self.app.url]],
            latency: .seconds(30)
        )
        let writer = HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 0)
        let started = ContinuousClock.now
        let results = await writer.apply(app: Self.app, targets: [Self.target], onProgress: { _ in true })
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(isFailure(results.first?.outcome))
    }
}
