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

private func apply(_ writer: SimulatedHandlerWriter, _ app: AppRef, _ targets: [KindMember.Target]) async -> [MemberResult] {
    await writer.apply(app: app, targets: targets) { _ in true }
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
        let plan = WritePlan(app: textEdit, targets: [.uti("public.html")]) { _ in safari }

        #expect(WritePlan.browserTargets == [.scheme("http"), .scheme("https"), .uti("public.html")])
        #expect(plan.steps == [WritePlan.Step(call: .scheme("http"), covers: WritePlan.browserTargets)])
        #expect(plan.changesBrowser)
    }

    /// Measured on macOS 26.6.2: XHTML doesn't follow the default browser, so it is its own call.
    @Test func xhtmlIsAnOrdinaryTargetAlongsideTheBrowserRole() {
        let targets: [KindMember.Target] = [.scheme("http"), .scheme("https"), .uti("public.html"), .uti("public.xhtml")]
        let bothDiffer = WritePlan(app: safari, targets: targets) { _ in textEdit }
        let onlyXHTML = WritePlan(app: safari, targets: [.uti("public.xhtml")]) { _ in textEdit }

        #expect(bothDiffer.steps.map(\.call) == [.scheme("http"), .uti("public.xhtml")])
        #expect(bothDiffer.promptCount == 2)
        #expect(onlyXHTML.steps == [WritePlan.Step(call: .uti("public.xhtml"), covers: [.uti("public.xhtml")])])
        #expect(!onlyXHTML.changesBrowser)
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
        let httpsElsewhere = WritePlan(app: safari, targets: targets) { $0 == .scheme("https") ? textEdit : safari }
        let allSafari = WritePlan(app: safari, targets: targets) { _ in safari }

        #expect(httpsElsewhere.promptCount == 1)
        #expect(allSafari.promptCount == 0)
        #expect(allSafari.skipped == targets)
    }

}

struct HandlerWriterTests {
    @Test func executesSequentiallyAndReportsChanges() async {
        let targets: [KindMember.Target] = [.uti("public.jpeg"), .uti("public.png"), .uti("public.heic")]
        let (writer, backend) = makeWriter([.uti("public.jpeg"): preview, .uti("public.png"): safari, .uti("public.heic"): safari])

        let results = await apply(writer, .preview, targets)

        #expect(results.map(\.outcome) == [.skipped(.alreadyDefault), .changed, .changed])
        #expect(backend.calls.map(\.target) == [.uti("public.png"), .uti("public.heic")])
    }

    @Test func silentNoChangeIsReportedAsUnchangedAfterSuccess() async {
        let (writer, _) = makeWriter([.scheme("sms"): preview], behaviors: [.scheme("sms"): .declineSilently])

        let results = await apply(writer, .messages, [.scheme("sms")])

        #expect(results.first?.outcome == .unchangedAfterSuccess)
        #expect(results.first?.handlerAfter?.url == preview)
    }

    @Test func userCancelledIsReportedAsDeclined() async {
        let (writer, _) = makeWriter([.uti("public.heif"): safari], behaviors: [.uti("public.heif"): .declineWithError])

        let results = await apply(writer, .preview, [.uti("public.heif")])

        #expect(results.first?.outcome == .declined)
    }

    /// R1: a 256 rejection is a plain failure. Nothing else is attempted, so no type outside the
    /// approved plan (such as the one a sample `.md` file resolves to) can change.
    @Test func error256IsReportedAsARejectionAndTouchesNothingElse() async throws {
        let (writer, backend) = makeWriter(
            [.uti("public.markdown"): safari, .uti("net.daringfireball.markdown"): safari],
            behaviors: [.uti("public.markdown"): .rejectBeforeConsent]
        )

        let results = await apply(writer, .textEdit, [.uti("public.markdown")])

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
            browserFollowers: [.uti("public.html")]
        )

        let results = await apply(writer, .textEdit, [.uti("public.html")])

        #expect(backend.calls.map(\.target) == [.scheme("http")])
        #expect(results.map(\.target) == WritePlan.browserTargets)
        #expect(results.map(\.outcome) == [.changed, .unchangedAfterSuccess, .changed])
        #expect(results.map(\.viaBrowserRole) == [false, true, true])
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

    /// macOS confirms each change itself, so several prompts run straight away, one at a time.
    @Test func multiplePromptsApplyImmediately() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.messages, for: try kind("phone-call", in: store))

        #expect(backend.calls.map(\.target) == [.scheme("tel"), .scheme("facetime")])
        #expect(try kind("phone-call", in: store).defaultApp?.url == AppRef.messages.url)
        #expect(store.results(for: try kind("phone-call", in: store)).count == 3)
    }

    @Test func progressReportsEachCallAndClearsAfterward() async throws {
        let (store, backend) = await makeStore(latency: .milliseconds(150))
        let phone = try kind("phone-call", in: store)

        let write = Task { await store.setDefault(.messages, for: phone) }
        await waitFor { store.progress?.step == 1 }
        #expect(store.progress?.total == 2)
        #expect(store.progress?.call.call == .scheme("tel"))
        await waitFor { store.progress?.step == 2 }
        #expect(store.progress?.call.call == .scheme("facetime"))
        await write.value

        #expect(store.progress == nil)
        #expect(backend.calls.count == 2)
    }

    @Test func singlePromptApplies() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        #expect(backend.calls.count == 1)
        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
    }

    /// The displayed Kind says one change is needed but the system needs two, so two calls run.
    @Test func planIsBasedOnLiveReadsNotTheDisplayedKind() async throws {
        let (store, backend) = await makeStore()
        backend.changeExternally(.uti("public.heic"), to: AppRef.photos.url)

        await store.setDefault(.preview, for: try kind("heic", in: store))

        #expect(backend.calls.map(\.target) == [.uti("public.heic"), .uti("public.heif")])
    }

    /// R2: when the system already matches, nothing runs and the display is corrected.
    @Test func staleDisplayWithNothingToDoMakesNoCallsAndCorrectsTheDisplay() async throws {
        let (store, backend) = await makeStore()
        backend.changeExternally(.uti("public.jpeg"), to: AppRef.photos.url)

        await store.setDefault(.photos, for: try kind("jpeg", in: store))

        #expect(backend.calls.isEmpty)
        #expect(try kind("jpeg", in: store).defaultApp?.url == AppRef.photos.url)
    }

    /// A per-member request on a browser target is the browser-wide change it really is.
    @Test func perMemberBrowserChangeIsBrowserWide() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.textEdit, for: .uti("public.html"), in: try kind("web-page", in: store))

        #expect(backend.calls.map(\.target) == [.scheme("http")])
        #expect(Set(store.results(for: try kind("web-page", in: store)).map(\.target)) == WritePlan.browserRole)
        #expect(try member(.uti("public.xhtml"), of: "web-page", in: store) == textEdit)
    }

    /// Measured on macOS 26.6.2: XHTML doesn't follow the default browser, so setting the Web
    /// page Kind makes the browser call plus XHTML's own call.
    @Test func webPageChangeIncludesXHTMLAsItsOwnCall() async throws {
        let (store, backend) = await makeStore()
        #expect(try kind("web-page", in: store).isSplit)

        await store.setDefault(.notes, for: try kind("web-page", in: store))

        #expect(backend.calls.map(\.target) == [.scheme("http"), .uti("public.xhtml")])
        #expect(try kind("web-page", in: store).defaultApp?.url == AppRef.notes.url)
    }

    /// The per-member action on XHTML is a plain single-member change, not the browser.
    @Test func perMemberXHTMLIsAnOrdinaryChange() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.safari, for: .uti("public.xhtml"), in: try kind("web-page", in: store))
        #expect(backend.calls.map(\.target) == [.uti("public.xhtml")])
        #expect(try kind("web-page", in: store).isSplit == false)
    }

    @Test func partialApplyLeavesTheKindSplitFromLiveReads() async throws {
        let (store, _) = await makeStore(behaviors: [.uti("com.apple.rtfd"): .rejectBeforeConsent])

        await store.setDefault(.notes, for: try kind("rtf", in: store))

        let richText = try kind("rtf", in: store)
        #expect(richText.isSplit)
        #expect(try member(.uti("public.rtf"), of: "rtf", in: store) == AppRef.notes.url)
        #expect(try member(.uti("com.apple.rtfd"), of: "rtf", in: store) == textEdit)
        let failure = store.results(for: richText).first { $0.target == .uti("com.apple.rtfd") }
        guard case .failed(_, 256, let message) = failure?.outcome else {
            Issue.record("Expected a 256 failure, got \(String(describing: failure?.outcome))")
            return
        }
        #expect(message.contains("rejected"))
    }

    /// An unsettable member (public.markdown on the dev Mac) doesn't make the Kind split, isn't
    /// planned, and produces no result row.
    @Test func unsettableMembersAreNeitherSplitNorPlanned() async throws {
        let (store, backend) = await makeStore(behaviors: [.uti("public.markdown"): .rejectBeforeConsent])
        let markdown = try kind("markdown", in: store)
        #expect(markdown.isSplit == false)
        #expect(markdown.defaultApp?.url == textEdit)

        await store.setDefault(.preview, for: markdown)
        #expect(backend.calls.map(\.target) == [.uti("net.daringfireball.markdown")])
        #expect(store.results(for: try kind("markdown", in: store)).map(\.target) == [.uti("net.daringfireball.markdown")])
        #expect(store.results(for: try kind("markdown", in: store)).map(\.outcome) == [.changed])
        #expect(try kind("markdown", in: store).isSplit == false)
        #expect(try member(.uti("public.markdown"), of: "markdown", in: store) == safari)
    }

    @Test func unsettableMembersCannotBeSetOneByOne() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.preview, for: .uti("public.markdown"), in: try kind("markdown", in: store))

        #expect(backend.calls.isEmpty)
    }

    @Test func majorityIgnoresUnsettableMembers() {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [
                KindMember(target: .uti("a"), defaultApp: .textEdit),
                KindMember(target: .uti("b"), defaultApp: .safari, isSettable: false),
                KindMember(target: .uti("c"), defaultApp: .safari, isSettable: false),
            ],
            extensions: [], mimeTypes: [], candidates: [.textEdit, .safari]
        )

        #expect(kind.majorityApp == .textEdit)
    }

    /// The Split list is fixed at load: a resolved Kind stays listed (and counts as resolved)
    /// until an explicit refresh.
    @Test func resolvedSplitKindsStayListedUntilRefresh() async throws {
        let (store, _) = await makeStore()
        let initialUnresolved = store.unresolvedSplitCount
        let phone = try kind("phone-call", in: store)
        #expect(store.splitKinds.contains { $0.id == phone.id })

        await store.setDefault(.messages, for: phone)

        #expect(try kind("phone-call", in: store).isSplit == false)
        #expect(store.splitKinds.contains { $0.id == "phone-call" })
        #expect(store.resolvedSplitIDs == ["phone-call"])
        #expect(store.unresolvedSplitCount == initialUnresolved - 1)

        await store.refresh(force: true)

        #expect(!store.splitKinds.contains { $0.id == "phone-call" })
        #expect(store.resolvedSplitIDs.isEmpty)
    }

    @Test func kindsThatBecomeSplitJoinTheListAndStayWhenFixed() async throws {
        let (store, _) = await makeStore()
        #expect(!store.splitKinds.contains { $0.id == "rtf" })

        await store.setDefault(.notes, for: .uti("com.apple.rtfd"), in: try kind("rtf", in: store))
        #expect(store.splitKinds.contains { $0.id == "rtf" })
        #expect(!store.resolvedSplitIDs.contains("rtf"))

        await store.setDefault(.notes, for: .uti("public.rtf"), in: try kind("rtf", in: store))
        #expect(store.splitKinds.contains { $0.id == "rtf" })
        // Resolved is reserved for Kinds that were split when the session began.
        #expect(!store.resolvedSplitIDs.contains("rtf"))
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

struct AppLabelsTests {
    private func app(_ path: String, _ name: String, _ version: String?) -> AppRef {
        AppRef(url: URL(filePath: path), bundleID: "com.adobe.illustrator", name: name, version: version)
    }

    @Test func uniqueNamesStayPlain() {
        let labels = AppLabels([.preview, .safari])

        #expect(labels.label(for: .preview) == "Preview")
    }

    @Test func sameNameDifferentVersionsShowTheVersion() {
        let old = app("/Applications/Adobe Illustrator 2025/Adobe Illustrator.app", "Adobe Illustrator", "29.8.3")
        let new = app("/Applications/Adobe Illustrator 2026/Adobe Illustrator.app", "Adobe Illustrator", "30.0.0")
        let labels = AppLabels([old, new, .preview])

        #expect(labels.label(for: old) == "Adobe Illustrator (29.8.3)")
        #expect(labels.label(for: new) == "Adobe Illustrator (30.0.0)")
        #expect(labels.label(for: .preview) == "Preview")
    }

    @Test func sameNameAndVersionShowTheFolder() {
        let system = app("/Applications/Mud.app", "Mud", "1.2")
        let home = app(NSHomeDirectory() + "/Applications/Mud.app", "Mud", "1.2")
        let labels = AppLabels([system, home])

        #expect(labels.label(for: system) == "Mud (1.2, /Applications)")
        #expect(labels.label(for: home) == "Mud (1.2, ~/Applications)")
    }

    @Test func missingVersionsFallBackToTheFolder() {
        let first = app("/Applications/Tool.app", "Tool", nil)
        let second = app("/Volumes/External/Tool.app", "Tool", nil)
        let labels = AppLabels([first, second, first])

        #expect(labels.label(for: first) == "Tool (/Applications)")
        #expect(labels.label(for: second) == "Tool (/Volumes/External)")
    }

    @MainActor
    @Test func nothingToDoMessageNamesTheExactInstall() async throws {
        let old = app("/Applications/Adobe Illustrator 2025/Adobe Illustrator.app", "Adobe Illustrator", "29.8.3")
        let new = app("/Applications/Adobe Illustrator 2026/Adobe Illustrator.app", "Adobe Illustrator", "30.0.0")
        var kind = try #require(SampleKindProvider.kinds.first { $0.id == "jpeg" })
        kind.members[0].defaultApp = new
        kind.candidates += [old, new]
        let backend = SimulatedHandlerBackend(kinds: [kind])
        let store = KindStore(provider: StaticKindProvider(kinds: [kind]), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()

        await store.setDefault(new, for: kind)

        #expect(store.message?.text.contains("Adobe Illustrator (30.0.0)") == true)
        #expect(backend.calls.isEmpty)
    }
}

private struct StaticKindProvider: KindProviding {
    let kinds: [Kind]

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] { kinds }
}

/// macOS only accepts an app it lists for that exact type (found when MHTML → Chrome failed with
/// 256 on com.microsoft.word.mhtml). The sample Calendar event models this: only Calendar lists
/// webcal:, although Mail is a Kind-level candidate.
@MainActor
struct MemberCandidateWriteTests {
    private func makeStore() async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds)
        let store = KindStore(provider: SimulatedKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    private func member(_ target: KindMember.Target, withCandidates urls: Set<URL>?, on app: AppRef) -> KindMember {
        KindMember(target: target, defaultApp: app, candidateURLs: urls)
    }

    @Test func membersThatDontListTheAppAreSkippedNotFailed() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.mail, for: try kind("calendar-event", in: store))

        let calendarEvent = try kind("calendar-event", in: store)
        #expect(backend.calls.map(\.target) == [.uti("com.apple.ical.ics")])
        #expect(store.results(for: calendarEvent).map(\.outcome) == [.changed, .skipped(.notSupported(.mail))])
        #expect(calendarEvent.isSplit)
    }

    @Test func perMemberRequestForAnUnlistedAppMakesNoCall() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.mail, for: .scheme("webcal"), in: try kind("calendar-event", in: store))

        #expect(backend.calls.isEmpty)
        #expect(store.message?.text.contains("can’t open this type") == true)
    }

    @Test func memberMenusOfferOnlyThatMembersApps() async throws {
        let (store, _) = await makeStore()
        let calendarEvent = try kind("calendar-event", in: store)
        let webcal = try #require(calendarEvent.members.first { $0.target == .scheme("webcal") })
        let ics = try #require(calendarEvent.members.first { $0.target == .uti("com.apple.ical.ics") })

        #expect(calendarEvent.candidates(for: webcal).map(\.url) == [AppRef.calendar.url])
        #expect(calendarEvent.candidates(for: ics).map(\.url) == [AppRef.calendar.url, AppRef.mail.url])
    }

    @Test func pickerNotesPartialSupport() async throws {
        let (store, _) = await makeStore()
        let calendarEvent = try kind("calendar-event", in: store)

        #expect(calendarEvent.supportNote(for: .mail) == "1 of 2 types")
        #expect(calendarEvent.supportNote(for: .calendar) == nil)
    }

    @Test func fixSplitUsesAnAppEveryEffectiveMemberAccepts() {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [
                member(.uti("a"), withCandidates: [AppRef.textEdit.url, AppRef.safari.url], on: .textEdit),
                member(.uti("b"), withCandidates: [AppRef.textEdit.url, AppRef.safari.url], on: .textEdit),
                member(.uti("c"), withCandidates: [AppRef.safari.url], on: .safari),
            ],
            extensions: [], mimeTypes: [], candidates: [.textEdit, .safari]
        )

        #expect(kind.isSplit)
        #expect(kind.fixSplitApp == .safari)
    }

    @Test func fixSplitPrefersTheAppMostMembersAlreadyUse() {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [
                member(.uti("a"), withCandidates: nil, on: .textEdit),
                member(.uti("b"), withCandidates: nil, on: .safari),
                member(.uti("c"), withCandidates: nil, on: .safari),
            ],
            extensions: [], mimeTypes: [], candidates: [.textEdit, .safari]
        )

        #expect(kind.fixSplitApp == .safari)
    }

    @Test func noUnifyingAppMeansMixedButNotSplit() {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [
                member(.uti("a"), withCandidates: [AppRef.textEdit.url], on: .textEdit),
                member(.uti("c"), withCandidates: [AppRef.preview.url], on: .preview),
            ],
            extensions: [], mimeTypes: [], candidates: [.textEdit, .preview]
        )

        #expect(kind.hasMixedHandlers)
        #expect(!kind.isSplit)
        #expect(kind.fixSplitApp == nil)
    }

    @Test func unknownCandidatesPlaceNoRestriction() {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [member(.uti("a"), withCandidates: nil, on: .textEdit), member(.uti("b"), withCandidates: nil, on: .safari)],
            extensions: [], mimeTypes: [], candidates: [.textEdit, .safari, .preview]
        )

        #expect(kind.supportNote(for: .preview) == nil)
        #expect(kind.candidates(for: kind.members[0]) == [.textEdit, .safari, .preview])
    }

    /// An "Other…" app on a member with unknown candidates can still reach the setter and fail.
    @Test func setterRejectionOfAnUnlistedAppExplainsTheRule() async throws {
        let backend = SimulatedHandlerBackend(handlers: [.uti("x"): AppRef.textEdit.url], allowedApps: [.uti("x"): [AppRef.textEdit.url]])
        let writer = HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1)

        let results = await writer.apply(app: .preview, targets: [.uti("x")]) { _ in true }

        guard case .failed(_, 256, let message) = results.first?.outcome else {
            Issue.record("Expected a 256 failure, got \(String(describing: results.first?.outcome))")
            return
        }
        #expect(message.contains("only allows apps that declare support for the type"))
    }
}

/// Members that no file resolves to don't decide anything: sample MPEG-4 audio has a shadowed
/// `public.mpeg-4-audio` (on Music) beside `com.apple.m4a-audio`, which wins `.m4a` and `.m4b`.
@MainActor
struct EffectiveMemberTests {
    private func makeStore() async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: SampleKindProvider.kinds)
        let store = KindStore(provider: SimulatedKindProvider(backend: backend), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    private func kind(_ id: Kind.ID, in store: KindStore) throws -> Kind {
        try #require(store.kinds.first { $0.id == id })
    }

    @Test func aShadowedMemberOnAnotherAppIsNotASplit() async throws {
        let (store, _) = await makeStore()
        let mpeg4Audio = try kind("mpeg4-audio", in: store)

        #expect(mpeg4Audio.shadowedMembers.map(\.target) == [.uti("public.mpeg-4-audio")])
        #expect(!mpeg4Audio.isSplit)
        #expect(mpeg4Audio.defaultApp?.url == AppRef.quickTime.url)
        #expect(!store.splitKinds.contains { $0.id == "mpeg4-audio" })
    }

    @Test func settingTheWholeKindTouchesEffectiveMembersOnly() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.books, for: try kind("mpeg4-audio", in: store))

        #expect(backend.calls.map(\.target) == [.uti("com.apple.m4a-audio")])
        #expect(store.results(for: try kind("mpeg4-audio", in: store)).map(\.target) == [.uti("com.apple.m4a-audio")])
        #expect(await backend.currentHandler(for: .uti("public.mpeg-4-audio")) == AppRef.music.url)
    }

    @Test func aShadowedMemberStillChangesThroughItsOwnMenu() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(.quickTime, for: .uti("public.mpeg-4-audio"), in: try kind("mpeg4-audio", in: store))

        #expect(backend.calls.map(\.target) == [.uti("public.mpeg-4-audio")])
    }

    @Test func supportNoteCountsEffectiveMembersOnly() {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [
                KindMember(target: .uti("a"), defaultApp: .textEdit, candidateURLs: [AppRef.textEdit.url], governedExtensions: ["a"]),
                KindMember(target: .uti("b"), defaultApp: .preview, candidateURLs: [AppRef.preview.url], governedExtensions: []),
            ],
            extensions: ["a"], mimeTypes: [], candidates: [.textEdit, .preview]
        )

        #expect(kind.supportNote(for: .textEdit) == nil)
    }

    @Test func schemesWithNoCommonAppAreMixedButNeverListedAsSplit() async throws {
        let (store, _) = await makeStore()
        let audioCall = try kind("audio-call", in: store)

        #expect(audioCall.hasMixedHandlers)
        #expect(!audioCall.isSplit)
        #expect(audioCall.fixSplitApp == nil)
        #expect(!store.splitKinds.contains { $0.id == "audio-call" })
    }

    @Test func extensionsNoMemberWinsAreReportedAsHandledElsewhere() async throws {
        let (store, _) = await makeStore()

        #expect(try kind("markdown", in: store).extensionsHandledElsewhere == ["mkd"])
        #expect(try kind("rtf", in: store).extensionsHandledElsewhere.isEmpty)
    }
}

/// Codex review 2, R1: the browser role changes through one `http` call, so eligibility is that
/// call's. Two asymmetric matrices from the dev Mac, with sample apps standing in:
/// "ChatGPT" (Notes here) is listed for http and https only; "Sublime Text" (TextEdit here)
/// only for public.html and public.xhtml.
@MainActor
struct BrowserRoleEligibilityTests {
    private let chatGPT = AppRef.notes
    private let sublime = AppRef.textEdit

    private var webPage: Kind {
        let schemes: Set<URL> = [AppRef.safari.url, AppRef.notes.url]
        let files: Set<URL> = [AppRef.safari.url, AppRef.textEdit.url]
        return Kind(
            id: "web-page", name: "Web page", category: .web,
            members: [
                KindMember(target: .scheme("http"), defaultApp: .safari, candidateURLs: schemes),
                KindMember(target: .scheme("https"), defaultApp: .safari, candidateURLs: schemes),
                KindMember(target: .uti("public.html"), defaultApp: .safari, candidateURLs: files, governedExtensions: ["html"]),
                KindMember(target: .uti("public.xhtml"), defaultApp: .safari, candidateURLs: files, governedExtensions: ["xhtml"]),
            ],
            extensions: ["html", "xhtml"], mimeTypes: [], candidates: [.safari, .notes, .textEdit]
        )
    }

    private func makeStore() async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: [webPage])
        let store = KindStore(provider: FixedKinds(kinds: [webPage]), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    private func member(_ target: KindMember.Target) -> KindMember {
        webPage.members.first { $0.target == target }!
    }

    @Test func schemesOnlyAppTakesTheWholeRoleButNotXHTML() async throws {
        let (store, backend) = await makeStore()

        #expect(webPage.supportNote(for: chatGPT) == "3 of 4 types")
        #expect(webPage.candidates(for: member(.uti("public.html"))).contains(chatGPT))
        #expect(AppBatchPlan(app: chatGPT, kinds: [webPage]).promptCount == 1)

        await store.setDefault(chatGPT, for: try #require(store.kinds.first))

        let results = store.results["web-page"] ?? []
        #expect(backend.calls.map(\.target) == [.scheme("http")])
        #expect(results.map(\.target).count == Set(results.map(\.target)).count)
        #expect(Set(results.map(\.target)) == [.scheme("http"), .scheme("https"), .uti("public.html"), .uti("public.xhtml")])
        #expect(results.first { $0.target == .uti("public.html") }?.outcome == .changed)
        #expect(results.first { $0.target == .uti("public.xhtml") }?.outcome == .skipped(.notSupported(chatGPT)))
    }

    @Test func fileOnlyAppIsNeverOfferedAsTheDefaultBrowser() async throws {
        let (store, backend) = await makeStore()

        #expect(webPage.supportNote(for: sublime) == "1 of 4 types")
        #expect(!webPage.candidates(for: member(.uti("public.html"))).contains(sublime))
        #expect(webPage.candidates(for: member(.uti("public.xhtml"))).contains(sublime))
        #expect(AppBatchPlan(app: sublime, kinds: [webPage]).promptCount == 1)

        await store.setDefault(sublime, for: try #require(store.kinds.first))

        let results = store.results["web-page"] ?? []
        #expect(backend.calls.map(\.target) == [.uti("public.xhtml")])
        #expect(results.map(\.target).count == Set(results.map(\.target)).count)
        #expect(results.filter { $0.outcome == .skipped(.notSupported(sublime)) }.map(\.target).sorted { "\($0)" < "\($1)" }
                == [KindMember.Target.scheme("http"), .scheme("https"), .uti("public.html")].sorted { "\($0)" < "\($1)" })
    }

    @Test func perMemberHTMLRequestForAFileOnlyAppMakesNoCall() async throws {
        let (store, backend) = await makeStore()

        await store.setDefault(sublime, for: .uti("public.html"), in: try #require(store.kinds.first))

        #expect(backend.calls.isEmpty)
    }

    @Test func finalResultsNeverListACoveredTargetTwice() {
        let applied = [MemberResult(target: .uti("public.html"), outcome: .changed)]
        let results = KindStore.finalResults(applied: applied, unsupported: [member(.uti("public.html")), member(.uti("public.xhtml"))], app: chatGPT)

        #expect(results.map(\.target) == [.uti("public.html"), .uti("public.xhtml")])
    }
}

/// Codex review 2, R4: differences that aren't fixable splits stay visible.
@MainActor
struct DifferenceVisibilityTests {
    private func makeStore(_ kinds: [Kind] = SampleKindProvider.kinds) async -> (KindStore, SimulatedHandlerBackend) {
        let backend = SimulatedHandlerBackend(kinds: kinds)
        let store = KindStore(provider: FixedKinds(kinds: kinds), writer: HandlerWriter(backend: backend, rereadDelay: .zero, rereadAttempts: 1))
        await store.refresh()
        return (store, backend)
    }

    @Test func shadowedMembersOnAnotherAppAreFlaggedAsDiffering() async throws {
        let (store, _) = await makeStore()
        let mpeg4Audio = try #require(store.kinds.first { $0.id == "mpeg4-audio" })

        #expect(!mpeg4Audio.hasMixedHandlers)
        #expect(mpeg4Audio.shadowedMembersDiffer)
        #expect(try #require(store.kinds.first { $0.id == "heic" }).shadowedMembersDiffer == false)
    }

    @Test func mixedKindsWithNoCommonAppAreListedUnderSplitWithoutCountingOrFix() async throws {
        let (store, _) = await makeStore()
        store.sidebarSelection = .split

        #expect(store.mixedWithoutFixKinds.map(\.id) == ["audio-call"])
        #expect(store.visibleKinds.contains { $0.id == "audio-call" })
        #expect(!store.splitKinds.contains { $0.id == "audio-call" })
        #expect(store.unresolvedSplitCount == store.kinds.count(where: \.isSplit))
        #expect(try #require(store.kinds.first { $0.id == "audio-call" }).fixSplitApp == nil)
    }

    @Test func resolvedMeansSplitAtStartAndNowUnified() async throws {
        let (store, _) = await makeStore()
        #expect(try #require(store.kinds.first { $0.id == "heic" }).isSplit)

        await store.setDefault(.preview, for: .uti("public.heif"), in: try #require(store.kinds.first { $0.id == "heic" }))

        #expect(store.resolvedSplitIDs.contains("heic"))
    }

    @Test func aSplitWhoseMembersStillDifferIsNotResolved() async throws {
        let kind = Kind(
            id: "k", name: "K", category: .documents,
            members: [
                KindMember(target: .uti("a"), defaultApp: .textEdit),
                KindMember(target: .uti("b"), defaultApp: .preview),
            ],
            extensions: [], mimeTypes: [], candidates: [.textEdit, .preview, .safari]
        )
        let (store, _) = await makeStore([kind])
        #expect(store.splitKinds.map(\.id) == ["k"])

        await store.setDefault(.safari, for: .uti("a"), in: try #require(store.kinds.first))

        #expect(try #require(store.kinds.first).hasMixedHandlers)
        #expect(!store.resolvedSplitIDs.contains("k"))
        #expect(store.splitKinds.map(\.id) == ["k"])
    }
}

private struct FixedKinds: KindProviding {
    let kinds: [Kind]

    func loadKinds(forceRefresh: Bool) async throws -> [Kind] { kinds }
}
