import Foundation
import Testing
@testable import Short_Circuit

// Every test here drives SimulatedHandlerBackend; nothing may construct WorkspaceHandlerBackend.

private let preview = AppRef.preview.url
private let safari = AppRef.safari.url
private let textEdit = AppRef.textEdit.url

private func writer(
    _ handlers: [KindMember.Target: URL],
    behaviors: [KindMember.Target: SimulatedHandlerBackend.Behavior] = [:],
    fileFallbackSucceeds: Bool = false
) -> (SimulatedHandlerWriter, SimulatedHandlerBackend) {
    let backend = SimulatedHandlerBackend(handlers: handlers, behaviors: behaviors, fileFallbackSucceeds: fileFallbackSucceeds)
    return (HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1), backend)
}

struct WritePlanTests {
    @Test func browserRoleCollapsesIntoOneHTTPCall() {
        let targets: [KindMember.Target] = [.scheme("https"), .uti("public.html"), .scheme("http"), .uti("public.xhtml")]
        let plan = WritePlan(app: textEdit, targets: targets) { _ in safari }

        #expect(plan.steps == [WritePlan.Step(call: .scheme("http"), covers: targets)])
        #expect(plan.promptCount == 1)
    }

    @Test func membersAlreadyOnTheAppAreSkipped() {
        let plan = WritePlan(app: preview, targets: [.uti("public.heic"), .uti("public.heif")]) {
            $0 == .uti("public.heic") ? preview : safari
        }

        #expect(plan.skipped == [.uti("public.heic")])
        #expect(plan.steps.map(\.call) == [.uti("public.heif")])
    }

    @Test func browserRoleIsSkippedOnlyWhenEveryMemberMatches() {
        let targets: [KindMember.Target] = [.scheme("http"), .uti("public.html")]
        let partial = WritePlan(app: safari, targets: targets) { $0 == .scheme("http") ? safari : textEdit }
        let complete = WritePlan(app: safari, targets: targets) { _ in safari }

        #expect(partial.promptCount == 1)
        #expect(complete.promptCount == 0)
        #expect(complete.skipped == targets)
    }
}

struct HandlerWriterTests {
    @Test func appliesSequentiallyAndReportsChanges() async {
        let (writer, backend) = writer([.uti("public.jpeg"): preview, .uti("public.png"): safari, .uti("public.heic"): safari])

        let results = await writer.apply(app: .preview, to: [.uti("public.jpeg"), .uti("public.png"), .uti("public.heic")])

        #expect(results.map(\.outcome) == [.skipped(.alreadyDefault), .changed, .changed])
        #expect(backend.calls.map(\.kind) == [.target(.uti("public.png")), .target(.uti("public.heic"))])
    }

    @Test func silentNoChangeIsReportedAsUnchangedAfterSuccess() async {
        let (writer, _) = writer([.scheme("sms"): preview], behaviors: [.scheme("sms"): .declineSilently])

        let results = await writer.apply(app: .messages, to: [.scheme("sms")])

        #expect(results.first?.outcome == .unchangedAfterSuccess)
        #expect(results.first?.handlerAfter?.url == preview)
    }

    @Test func userCancelledIsReportedAsDeclined() async {
        let (writer, _) = writer([.uti("public.heif"): safari], behaviors: [.uti("public.heif"): .declineWithError])

        let results = await writer.apply(app: .preview, to: [.uti("public.heif")])

        #expect(results.first?.outcome == .declined)
    }

    @Test func error256TriesTheFileFallbackAndKeepsTheOriginalErrorWhenItFails() async {
        let (writer, backend) = writer(
            [.uti("public.markdown"): safari, .uti("net.daringfireball.markdown"): safari],
            behaviors: [.uti("public.markdown"): .rejectBeforeConsent]
        )

        let results = await writer.apply(app: .textEdit, to: [.uti("net.daringfireball.markdown"), .uti("public.markdown")])

        #expect(results[0].outcome == .changed)
        #expect(results[0].usedFileFallback == false)
        guard case .failed(let domain, let code, _) = results[1].outcome else {
            Issue.record("Expected a failure, got \(results[1].outcome)")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == 256)
        #expect(results[1].usedFileFallback)
        #expect(backend.calls.last?.kind == .file(extension: "md"))
    }

    @Test func error256FallbackThatWorksCountsAsChanged() async {
        let (writer, _) = writer(
            [.uti("public.markdown"): safari],
            behaviors: [.uti("public.markdown"): .rejectBeforeConsent],
            fileFallbackSucceeds: true
        )

        let results = await writer.apply(app: .textEdit, to: [.uti("public.markdown")])

        #expect(results.first?.outcome == .changed)
        #expect(results.first?.usedFileFallback == true)
    }

    @Test func browserMembersFollowTheHTTPCall() async {
        let targets: [KindMember.Target] = [.scheme("http"), .scheme("https"), .uti("public.html")]
        let (writer, backend) = writer(Dictionary(uniqueKeysWithValues: targets.map { ($0, safari) }))

        let results = await writer.apply(app: .textEdit, to: targets)

        #expect(backend.calls.map(\.kind) == [.target(.scheme("http"))])
        #expect(results.map(\.outcome) == [.changed, .changed, .changed])
        #expect(results.map(\.viaBrowserRole) == [false, true, true])
    }
}

@MainActor
struct KindStoreWriteTests {
    private func loadedStore(
        behaviors: [KindMember.Target: SimulatedHandlerBackend.Behavior] = [:]
    ) async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, behaviors: behaviors)
        let store = KindStore(provider: SampleKindProvider(), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    /// Single-prompt changes run in an unstructured Task, so poll until the results land.
    private func waitUntilIdle(_ store: KindStore, kindID: Kind.ID) async {
        for _ in 0..<200 {
            let hasResults = store.kinds.first { $0.id == kindID }.map { !store.results(for: $0).isEmpty } ?? false
            if hasResults && store.applyingKindIDs.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func multiplePromptsNeedConfirmationFirst() async throws {
        let (store, backend) = await loadedStore()

        store.setDefault(.messages, for: try kind("phone-call", in: store))

        let pending = try #require(store.pendingChange)
        #expect(pending.promptCount == 2)
        #expect(backend.calls.isEmpty)

        await store.confirmPendingChange()

        #expect(store.pendingChange == nil)
        #expect(try kind("phone-call", in: store).defaultApp?.url == AppRef.messages.url)
        #expect(try kind("phone-call", in: store).isSplit == false)
    }

    @Test func singlePromptAppliesWithoutConfirmation() async throws {
        let (store, backend) = await loadedStore()

        store.setDefault(.photos, for: try kind("jpeg", in: store))
        await waitUntilIdle(store, kindID: "jpeg")

        #expect(store.pendingChange == nil)
        #expect(backend.calls.count == 1)
        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
    }

    @Test func partialApplyLeavesTheKindSplitFromLiveReads() async throws {
        let (store, _) = await loadedStore(behaviors: [.uti("public.markdown"): .rejectBeforeConsent])

        store.setDefault(.preview, for: try kind("markdown", in: store))
        await store.confirmPendingChange()

        let markdown = try kind("markdown", in: store)
        #expect(markdown.isSplit)
        #expect(markdown.members.first { $0.target == .uti("net.daringfireball.markdown") }?.defaultApp?.url == AppRef.preview.url)
        #expect(markdown.members.first { $0.target == .uti("public.markdown") }?.defaultApp?.url == AppRef.safari.url)
        #expect(markdown.candidates.contains { $0.url == AppRef.preview.url })
        #expect(store.results(for: markdown).map(\.outcome.isChanged) == [true, false])
    }

    @Test func fixSplitOnlyTouchesMembersOffTheMajorityApp() async throws {
        let (store, backend) = await loadedStore()
        let heic = try kind("heic", in: store)
        let majority = try #require(heic.majorityApp)

        store.fixSplit(heic)
        await waitUntilIdle(store, kindID: "heic")

        let changed = heic.members.filter { $0.defaultApp?.url != majority.url }.map { SimulatedHandlerBackend.Call.Kind.target($0.target) }
        #expect(backend.calls.map(\.kind) == changed)
        #expect(try kind("heic", in: store).isSplit == false)
    }

    @Test func perMemberChangeOnlyCallsThatMember() async throws {
        let (store, backend) = await loadedStore()

        store.setDefault(.notes, for: .uti("com.apple.rtfd"), in: try kind("rtf", in: store))
        await waitUntilIdle(store, kindID: "rtf")

        let rtf = try kind("rtf", in: store)
        #expect(store.pendingChange == nil)
        #expect(backend.calls.map(\.kind) == [.target(.uti("com.apple.rtfd"))])
        #expect(rtf.isSplit)
        #expect(store.results(for: rtf).map(\.target) == [.uti("com.apple.rtfd")])
    }
}

private extension MemberResult.Outcome {
    var isChanged: Bool { self == .changed }
}
