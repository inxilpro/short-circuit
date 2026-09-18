import Foundation
import Testing
@testable import Short_Circuit

// Every test here drives SimulatedHandlerBackend; nothing may construct WorkspaceHandlerBackend.

private let preview = AppRef.preview.url
private let safari = AppRef.safari.url
private let textEdit = AppRef.textEdit.url

private func makeWriter(
    _ handlers: [KindMember.Target: URL],
    behaviors: [KindMember.Target: SimulatedHandlerBackend.Behavior] = [:],
    browserFollowers: Set<KindMember.Target> = WritePlan.browserRole
) -> (SimulatedHandlerWriter, SimulatedHandlerBackend) {
    let backend = SimulatedHandlerBackend(handlers: handlers, behaviors: behaviors, browserFollowers: browserFollowers)
    return (HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1), backend)
}

private func completedResults(_ execution: WriteExecution) -> [MemberResult] {
    if case .completed(let results) = execution { results } else { [] }
}

/// Serves the sample Kinds with handlers read from the simulated system, like LiveKindProvider
/// does from Launch Services.
private struct SimulatedKindProvider: KindProviding {
    let backend: SimulatedHandlerBackend
    var delay: Duration = .zero

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] {
        if delay > .zero { try await Task.sleep(for: delay) }
        var kinds = SampleKindProvider.kinds
        for kindIndex in kinds.indices {
            for memberIndex in kinds[kindIndex].members.indices {
                let target = kinds[kindIndex].members[memberIndex].target
                kinds[kindIndex].members[memberIndex].defaultApp = await backend.currentHandler(for: target).map(HandlerService.appRef(for:))
            }
        }
        return kinds
    }
}

struct WritePlanTests {
    @Test func anyBrowserTargetPlansTheWholeRole() {
        let plan = WritePlan(app: textEdit, targets: [.uti("public.xhtml")]) { _ in safari }

        #expect(plan.steps == [WritePlan.Step(call: .scheme("http"), covers: WritePlan.browserTargets)])
        #expect(plan.changesBrowser)
        #expect(plan.affectedTargets == WritePlan.browserTargets)
    }

    @Test func membersAlreadyOnTheAppAreSkipped() {
        let plan = WritePlan(app: preview, targets: [.uti("public.heic"), .uti("public.heif")]) {
            $0 == .uti("public.heic") ? preview : safari
        }

        #expect(plan.skipped == [.uti("public.heic")])
        #expect(plan.steps.map(\.call) == [.uti("public.heif")])
    }

    @Test func browserRoleIsSkippedOnlyWhenEveryBrowserTargetMatches() {
        let targets: [KindMember.Target] = [.scheme("http"), .uti("public.html")]
        let xhtmlElsewhere = WritePlan(app: safari, targets: targets) { $0 == .uti("public.xhtml") ? textEdit : safari }
        let allSafari = WritePlan(app: safari, targets: targets) { _ in safari }

        #expect(xhtmlElsewhere.promptCount == 1)
        #expect(allSafari.promptCount == 0)
        #expect(allSafari.skipped == targets)
    }

    @Test func narrowerPlansFitInsideTheApprovedOneButWiderOnesDoNot() {
        let targets: [KindMember.Target] = [.uti("public.heic"), .uti("public.heif")]
        let both = WritePlan(app: preview, targets: targets) { _ in safari }
        let one = WritePlan(app: preview, targets: targets) { $0 == .uti("public.heic") ? preview : safari }
        let otherApp = WritePlan(app: textEdit, targets: targets) { _ in safari }

        #expect(one.isWithin(both))
        #expect(!both.isWithin(one))
        #expect(!otherApp.isWithin(both))
    }
}

struct HandlerWriterTests {
    @Test func executesSequentiallyAndReportsChanges() async {
        let targets: [KindMember.Target] = [.uti("public.jpeg"), .uti("public.png"), .uti("public.heic")]
        let (writer, backend) = makeWriter([.uti("public.jpeg"): preview, .uti("public.png"): safari, .uti("public.heic"): safari])

        let plan = await writer.plan(app: .preview, targets: targets)
        let results = completedResults(await writer.execute(plan))

        #expect(results.map(\.outcome) == [.skipped(.alreadyDefault), .changed, .changed])
        #expect(backend.calls.map(\.target) == [.uti("public.png"), .uti("public.heic")])
    }

    @Test func silentNoChangeIsReportedAsUnchangedAfterSuccess() async {
        let (writer, _) = makeWriter([.scheme("sms"): preview], behaviors: [.scheme("sms"): .declineSilently])

        let results = completedResults(await writer.execute(await writer.plan(app: .messages, targets: [.scheme("sms")])))

        #expect(results.first?.outcome == .unchangedAfterSuccess)
        #expect(results.first?.handlerAfter?.url == preview)
    }

    @Test func userCancelledIsReportedAsDeclined() async {
        let (writer, _) = makeWriter([.uti("public.heif"): safari], behaviors: [.uti("public.heif"): .declineWithError])

        let results = completedResults(await writer.execute(await writer.plan(app: .preview, targets: [.uti("public.heif")])))

        #expect(results.first?.outcome == .declined)
    }

    /// R1: a 256 rejection is a plain failure. Nothing else is attempted, so no type outside the
    /// approved plan (such as the one a sample `.md` file resolves to) can change.
    @Test func error256IsReportedAsARejectionAndTouchesNothingElse() async throws {
        let (writer, backend) = makeWriter(
            [.uti("public.markdown"): safari, .uti("net.daringfireball.markdown"): safari],
            behaviors: [.uti("public.markdown"): .rejectBeforeConsent]
        )

        let results = completedResults(await writer.execute(await writer.plan(app: .textEdit, targets: [.uti("public.markdown")])))

        let result = try #require(results.first)
        guard case .failed(let domain, let code, let message) = result.outcome else {
            Issue.record("Expected a failure, got \(result.outcome)")
            return
        }
        #expect(domain == NSCocoaErrorDomain)
        #expect(code == 256)
        #expect(message.contains("rejected"))
        #expect(backend.calls.map(\.target) == [.uti("public.markdown")])
        #expect(await backend.currentHandler(for: .uti("net.daringfireball.markdown")) == safari)
    }

    /// R3: the browser call is reported for every target it covers, and a target that doesn't
    /// follow it is reported honestly rather than assumed changed.
    @Test func browserChangeReportsEveryCoveredTargetFromLiveReads() async {
        let (writer, backend) = makeWriter(
            Dictionary(uniqueKeysWithValues: WritePlan.browserTargets.map { ($0, safari) }),
            browserFollowers: [.scheme("https"), .uti("public.html")]
        )

        let results = completedResults(await writer.execute(await writer.plan(app: .textEdit, targets: [.uti("public.xhtml")])))

        #expect(backend.calls.map(\.target) == [.scheme("http")])
        #expect(results.map(\.target) == WritePlan.browserTargets)
        #expect(results.map(\.outcome) == [.changed, .changed, .changed, .unchangedAfterSuccess])
        #expect(results.map(\.viaBrowserRole) == [false, true, true, true])
    }

    /// R2: if the system changed after approval so more calls are needed, nothing runs.
    @Test func widerLivePlanNeedsNewApprovalAndMakesNoCalls() async {
        let targets: [KindMember.Target] = [.uti("public.heic"), .uti("public.heif")]
        let (writer, backend) = makeWriter([.uti("public.heic"): preview, .uti("public.heif"): safari])
        let approved = await writer.plan(app: .preview, targets: targets)
        #expect(approved.promptCount == 1)

        backend.changeExternally(.uti("public.heic"), to: safari)
        let execution = await writer.execute(approved)

        guard case .needsApproval(let fresh) = execution else {
            Issue.record("Expected a request for new approval, got \(execution)")
            return
        }
        #expect(fresh.promptCount == 2)
        #expect(backend.calls.isEmpty)
    }

    @Test func narrowerLivePlanRunsWithoutAskingAgain() async {
        let targets: [KindMember.Target] = [.uti("public.heic"), .uti("public.heif")]
        let (writer, backend) = makeWriter([.uti("public.heic"): safari, .uti("public.heif"): safari])
        let approved = await writer.plan(app: .preview, targets: targets)

        backend.changeExternally(.uti("public.heic"), to: preview)
        let results = completedResults(await writer.execute(approved))

        #expect(backend.calls.map(\.target) == [.uti("public.heif")])
        #expect(results.map(\.outcome) == [.skipped(.alreadyDefault), .changed])
    }
}

@MainActor
struct KindStoreWriteTests {
    private func makeStore(
        behaviors: [KindMember.Target: SimulatedHandlerBackend.Behavior] = [:],
        latency: Duration = .zero,
        providerDelay: Duration = .zero
    ) async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds, behaviors: behaviors, latency: latency)
        let provider = SimulatedKindProvider(backend: backend, delay: providerDelay)
        let store = KindStore(provider: provider, writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    private func member(_ target: KindMember.Target, of id: Kind.ID, in store: KindStore) throws -> URL? {
        try kind(id, in: store).members.first { $0.target == target }?.defaultApp?.url
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func multiplePromptsNeedConfirmationFirst() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.messages, for: try kind("phone-call", in: store))

        let pending = try #require(store.pendingChange)
        #expect(pending.plan.promptCount == 2)
        #expect(backend.calls.isEmpty)

        await store.confirmPendingChange()

        #expect(store.pendingChange == nil)
        #expect(try kind("phone-call", in: store).defaultApp?.url == AppRef.messages.url)
    }

    @Test func singlePromptAppliesWithoutConfirmation() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        #expect(store.pendingChange == nil)
        #expect(backend.calls.count == 1)
        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
    }

    /// R2: the displayed Kind says one change is needed but the system needs two, so the user
    /// is asked about two.
    @Test func confirmationIsBasedOnLiveReadsNotTheDisplayedKind() async throws {
        let (store, backend) = await makeStore()
        backend.changeExternally(.uti("public.heic"), to: AppRef.photos.url)

        await store.setDefault(.preview, for: try kind("heic", in: store))

        #expect(store.pendingChange?.plan.promptCount == 2)
        #expect(backend.calls.isEmpty)
    }

    /// R2: a change made while the dialog was open widens the plan, so the user is asked again
    /// and nothing runs on the stale approval.
    @Test func widenedPlanAfterConfirmationAsksAgain() async throws {
        let (store, backend) = await makeStore()
        backend.changeExternally(.uti("com.apple.mail.email"), to: textEdit)
        backend.changeExternally(.uti("public.email-message"), to: textEdit)

        await store.setDefault(.mail, for: try kind("email", in: store))
        #expect(store.pendingChange?.plan.promptCount == 2)

        backend.changeExternally(.scheme("mailto"), to: textEdit)
        await store.confirmPendingChange()

        let revised = try #require(store.pendingChange)
        #expect(revised.isRevised)
        #expect(revised.plan.promptCount == 3)
        #expect(backend.calls.isEmpty)
    }

    /// R2: when the system already matches, nothing runs and the display is corrected.
    @Test func staleDisplayWithNothingToDoMakesNoCallsAndCorrectsTheDisplay() async throws {
        let (store, backend) = await makeStore()
        backend.changeExternally(.uti("public.jpeg"), to: AppRef.photos.url)

        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        #expect(backend.calls.isEmpty)
        #expect(store.pendingChange == nil)
        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
    }

    /// R3: a per-member request on a browser target is shown as the browser-wide change it is.
    @Test func perMemberBrowserChangeIsConfirmedAsBrowserWide() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.textEdit, for: .uti("public.xhtml"), in: try kind("web-page", in: store))

        let pending = try #require(store.pendingChange)
        #expect(pending.plan.promptCount == 1)
        #expect(pending.plan.changesBrowser)
        #expect(pending.plan.affectedTargets == WritePlan.browserTargets)
        #expect(ChangeConfirmation.message(for: pending).contains("Default browser"))
        #expect(backend.calls.isEmpty)

        await store.confirmPendingChange()

        #expect(backend.calls.map(\.target) == [.scheme("http")])
        #expect(Set(store.results(for: try kind("web-page", in: store)).map(\.target)) == WritePlan.browserRole)
    }

    @Test func partialApplyLeavesTheKindSplitFromLiveReads() async throws {
        let (store, _) = await makeStore(behaviors: [.uti("public.markdown"): .rejectBeforeConsent])

        await store.setDefault(.preview, for: try kind("markdown", in: store))
        await store.confirmPendingChange()

        let markdown = try kind("markdown", in: store)
        #expect(markdown.isSplit)
        #expect(try member(.uti("net.daringfireball.markdown"), of: "markdown", in: store) == preview)
        #expect(try member(.uti("public.markdown"), of: "markdown", in: store) == safari)
        #expect(markdown.candidates.contains { $0.url == preview })
    }

    @Test func fixSplitOnlyTouchesMembersOffTheMajorityApp() async throws {
        let (store, backend) = await makeStore()
        let heic = try kind("heic", in: store)
        let majority = try #require(heic.majorityApp)

        await store.fixSplit(heic)

        #expect(backend.calls.map(\.target) == heic.members.filter { $0.defaultApp?.url != majority.url }.map(\.target))
        #expect(try kind("heic", in: store).isSplit == false)
    }

    @Test func perMemberChangeOnlyCallsThatMember() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.notes, for: .uti("com.apple.rtfd"), in: try kind("rtf", in: store))

        #expect(store.pendingChange == nil)
        #expect(backend.calls.map(\.target) == [.uti("com.apple.rtfd")])
        #expect(try kind("rtf", in: store).isSplit)
    }

    /// R7: while one change waits on its prompt, no other change can start anywhere.
    @Test func writesAreSerializedAcrossKinds() async throws {
        let (store, backend) = await makeStore(latency: .milliseconds(200))
        let jpeg = try kind("jpeg", in: store)
        let png = try kind("png", in: store)

        let first = Task { await store.setDefault(.photos, for: jpeg) }
        await waitFor { !backend.calls.isEmpty }
        #expect(!store.canWrite)

        await store.setDefault(.photos, for: png)
        await first.value

        #expect(backend.calls.map(\.target) == [.uti("public.jpeg")])
        #expect(backend.maxConcurrentCalls == 1)
        #expect(try kind("png", in: store).defaultApp?.url == preview)
        #expect(store.canWrite)
    }

    /// R8: a refresh can't start mid-write, and one after the write keeps the verified handler
    /// and the per-member results.
    @Test func refreshDuringWriteIsRefusedAndLaterRefreshKeepsResults() async throws {
        let (store, backend) = await makeStore(latency: .milliseconds(200))
        let jpeg = try kind("jpeg", in: store)

        let write = Task { await store.setDefault(.photos, for: jpeg) }
        await waitFor { !backend.calls.isEmpty }
        await store.refresh()
        #expect(!store.isRefreshing)
        await write.value

        await store.refresh()

        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
        #expect(store.results(for: try kind("jpeg", in: store)).map(\.outcome) == [.changed])
    }

    /// R8, other ordering: a write can't start while a refresh is reading handlers.
    @Test func writeDuringRefreshIsRefused() async throws {
        let (store, backend) = await makeStore(providerDelay: .milliseconds(200))
        let jpeg = try kind("jpeg", in: store)

        let refresh = Task { await store.refresh() }
        await waitFor { store.isRefreshing }
        await store.setDefault(.photos, for: jpeg)
        await refresh.value

        #expect(backend.calls.isEmpty)
        #expect(try kind("jpeg", in: store).defaultApp?.url == preview)
    }
}
