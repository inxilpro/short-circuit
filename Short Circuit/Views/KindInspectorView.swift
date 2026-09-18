import SwiftUI

/// Everything the inspector needs to change handlers. Passing nil keeps the inspector read-only.
struct KindEditing {
    /// False while any change anywhere in the app is planning, applying, or awaiting confirmation.
    var isEnabled = true
    var isApplying = false
    var results: [MemberResult] = []
    var setDefault: (AppRef) -> Void
    var setMemberDefault: (AppRef, KindMember.Target) -> Void
    var fixSplit: () -> Void
}

struct KindInspectorView: View {
    let kind: Kind?
    var editing: KindEditing?

    var body: some View {
        if let kind {
            KindInspectorForm(kind: kind, editing: editing)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "sidebar.right",
                description: Text("Select a type, or drop a file on the window.")
            )
        }
    }
}

private struct KindInspectorForm: View {
    let kind: Kind
    let editing: KindEditing?

    private var canEdit: Bool { editing?.isEnabled == true }

    private var resultsByTarget: [KindMember.Target: MemberResult] {
        Dictionary((editing?.results ?? []).map { ($0.target, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// A member's handler can be an app that no longer claims the type, so it must still appear.
    private var choices: AppChoices {
        AppChoices(kind: kind)
    }

    var body: some View {
        Form {
            Section {
                header
            }

            Section("Opens With") {
                OpensWithPicker(kind: kind, choices: choices, isEnabled: canEdit) { app in
                    editing?.setDefault(app)
                }
                if kind.members.contains(where: { WritePlan.browserRole.contains($0.target) }) {
                    BrowserRoleNotice()
                }
                if editing?.isApplying == true {
                    ApplyingNotice()
                } else if let results = editing?.results, !results.isEmpty {
                    ResultSummary(results: results)
                }
                if kind.isSplit {
                    SplitNotice(kind: kind, isEnabled: canEdit) {
                        editing?.fixSplit()
                    }
                }
            }

            Section("Members") {
                ForEach(kind.members) { member in
                    MemberRow(
                        kindName: kind.name,
                        member: member,
                        isOddOneOut: kind.isSplit && member.defaultApp?.url != kind.majorityApp?.url,
                        result: resultsByTarget[member.target],
                        choices: choices,
                        isEnabled: canEdit
                    ) { app in
                        editing?.setMemberDefault(app, member.target)
                    }
                }
            }

            if !kind.extensions.isEmpty {
                Section("Extensions") {
                    ChipList(items: kind.extensions.map { ".\($0)" })
                }
            }

            if !kind.mimeTypes.isEmpty {
                Section("MIME Types") {
                    ChipList(items: kind.mimeTypes)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var header: some View {
        HStack(spacing: 12) {
            KindIconView(kind: kind, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind.name)
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Text(kind.category.title)
                    .foregroundStyle(.secondary)
                Text("^[\(kind.candidates.count) app](inflect: true) can open this")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Long candidate lists are alphabetical, so the apps members already use are pulled to the top
/// where they can be found without scanning twenty names.
private struct AppChoices {
    var current: [AppRef]
    var others: [AppRef]

    var all: [AppRef] { current + others }

    init(kind: Kind) {
        var seen = Set<URL>()
        current = kind.members.compactMap(\.defaultApp).filter { seen.insert($0.url).inserted }
        others = kind.candidates.filter { seen.insert($0.url).inserted }
    }
}

private enum AppChoice: Hashable {
    case none
    case app(URL)
    case other
}

private struct OpensWithPicker: View {
    let kind: Kind
    let choices: AppChoices
    let isEnabled: Bool
    let onChoose: (AppRef) -> Void

    var body: some View {
        Picker("Default app", selection: selection) {
            if kind.defaultApp == nil {
                Text(kind.isSplit ? "Mixed" : "None").tag(AppChoice.none)
                Divider()
            }
            Section("Current") {
                ForEach(choices.current) { app in
                    appLabel(app).tag(AppChoice.app(app.url))
                }
            }
            if !choices.others.isEmpty {
                Section("Other Apps") {
                    ForEach(choices.others) { app in
                        appLabel(app).tag(AppChoice.app(app.url))
                    }
                }
            }
            Divider()
            Text("Other…").tag(AppChoice.other)
        }
        .disabled(!isEnabled)
    }

    private func appLabel(_ app: AppRef) -> some View {
        Label {
            Text(app.name)
        } icon: {
            AppIconView(app: app, size: 16)
        }
    }

    private var selection: Binding<AppChoice> {
        Binding(
            get: { kind.defaultApp.map { .app($0.url) } ?? .none },
            set: { choice in
                switch choice {
                case .none:
                    break
                case .app(let url):
                    if let app = choices.all.first(where: { $0.url == url }) { onChoose(app) }
                case .other:
                    chooseOtherApp(forOpening: kind.name, then: onChoose)
                }
            }
        )
    }
}

/// Deferred so the modal panel doesn't run inside a SwiftUI binding update.
private func chooseOtherApp(forOpening kindName: String, then onChoose: @escaping (AppRef) -> Void) {
    Task { @MainActor in
        if let app = ApplicationChooser.chooseApplication(forOpening: kindName) {
            onChoose(app)
        }
    }
}

private struct ApplyingNotice: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Waiting for macOS — confirm each prompt to apply the change.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ResultSummary: View {
    let results: [MemberResult]

    var body: some View {
        let changed = results.filter { $0.outcome == .changed }.count
        let notChanged = results.filter(\.outcome.isNotChanged).count
        let failed = results.filter(\.outcome.isFailure).count

        HStack(spacing: 12) {
            if changed > 0 {
                Label("\(changed) changed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if notChanged > 0 {
                Label("\(notChanged) declined", systemImage: "hand.raised.fill")
                    .foregroundStyle(.secondary)
            }
            if failed > 0 {
                Label("\(failed) failed", systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
            }
            if changed + notChanged + failed == 0 {
                Label("Nothing needed changing", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

private struct SplitNotice: View {
    let kind: Kind
    let isEnabled: Bool
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("These members open in different apps, so files of this type may not open where you expect.", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let majority = kind.majorityApp {
                Button("Fix Split — Use \(majority.name) for All", action: onFix)
                    .disabled(!isEnabled)
            }
        }
    }
}

private struct MemberRow: View {
    let kindName: String
    let member: KindMember
    let isOddOneOut: Bool
    let result: MemberResult?
    let choices: AppChoices
    let isEnabled: Bool
    let onChoose: (AppRef) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: member.target.isScheme ? "link" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                // Identifiers have no natural break points, so shrink rather than hyphenate them.
                Text(member.target.displayName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(member.target.displayName)

                HStack(spacing: 4) {
                    if let app = member.defaultApp {
                        AppIconView(app: app, size: 14)
                        Text(app.name)
                    } else {
                        Text("No default")
                            .foregroundStyle(.tertiary)
                    }
                    if isOddOneOut {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .help("Opens in a different app than the rest of this type")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                if let result {
                    MemberResultLabel(result: result)
                }
            }

            Spacer(minLength: 0)

            memberMenu
        }
    }

    private var isBrowserMember: Bool {
        WritePlan.browserRole.contains(member.target)
    }

    /// Browser members can't be changed alone, so their menu offers the browser-wide action
    /// under its real name instead of pretending to set one member.
    private var memberMenu: some View {
        Menu {
            Section(isBrowserMember ? "Default Browser (http, https, HTML, XHTML)" : "Open \(member.target.displayName) With") {
                ForEach(choices.all) { app in
                    Button {
                        onChoose(app)
                    } label: {
                        Label {
                            Text(isBrowserMember ? "Make \(app.name) the Default Browser" : app.name)
                        } icon: {
                            AppIconView(app: app, size: 16)
                        }
                    }
                    .disabled(app.url == member.defaultApp?.url && !isBrowserMember)
                }
            }
            Divider()
            Button("Other…") {
                chooseOtherApp(forOpening: isBrowserMember ? "web pages and links" : "\(member.target.displayName) (\(kindName))", then: onChoose)
            }
        } label: {
            Image(systemName: isBrowserMember ? "globe" : "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .help(isBrowserMember
              ? "Change the default browser, which sets http, https, HTML, and XHTML together"
              : "Set just this member")
    }
}

private struct BrowserRoleNotice: View {
    var body: some View {
        Label("Changing this sets your default web browser, which covers http, https, HTML, and XHTML together.", systemImage: "globe")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct MemberResultLabel: View {
    let result: MemberResult

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            label
                .fixedSize(horizontal: false, vertical: true)
            if result.viaBrowserRole {
                Text("Part of the default-browser change, which is made through the http scheme.")
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var label: some View {
        switch result.outcome {
        case .changed:
            Label("Changed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .unchangedAfterSuccess:
            Label("Not changed — the prompt was probably declined", systemImage: "hand.raised.fill")
                .foregroundStyle(.secondary)
        case .declined:
            Label("Declined", systemImage: "hand.raised.fill")
                .foregroundStyle(.secondary)
        case .failed(let domain, let code, let message):
            Label("Failed: \(message) (\(Self.shortDomain(domain)) \(code))", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        case .skipped(.alreadyDefault):
            Label("Already set", systemImage: "checkmark.circle")
                .foregroundStyle(.tertiary)
        }
    }

    private static func shortDomain(_ domain: String) -> String {
        domain == NSCocoaErrorDomain ? "Cocoa" : domain
    }
}

private struct ChipList: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .textSelection(.enabled)
            }
        }
    }
}

private extension KindMember.Target {
    var isScheme: Bool {
        if case .scheme = self { true } else { false }
    }
}

private extension MemberResult.Outcome {
    var isNotChanged: Bool {
        self == .unchangedAfterSuccess || self == .declined
    }

    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }
}

private func previewEditing(results: [MemberResult] = [], isEnabled: Bool = true, isApplying: Bool = false) -> KindEditing {
    KindEditing(isEnabled: isEnabled, isApplying: isApplying, results: results, setDefault: { _ in }, setMemberDefault: { _, _ in }, fixSplit: {})
}

#Preview("Split") {
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "markdown" }, editing: previewEditing())
        .frame(width: 320, height: 640)
}

#Preview("Partially applied") {
    KindInspectorView(
        kind: SampleKindProvider.kinds.first { $0.id == "markdown" },
        editing: previewEditing(results: [
            MemberResult(target: .uti("net.daringfireball.markdown"), outcome: .changed, handlerAfter: .safari),
            MemberResult(target: .uti("public.markdown"), outcome: .failed(domain: NSCocoaErrorDomain, code: 256, message: "macOS rejected changing the default app for this type without asking. Nothing was changed."), handlerAfter: .safari),
        ])
    )
    .frame(width: 320, height: 640)
}

#Preview("Applying") {
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "web-page" }, editing: previewEditing(isEnabled: false, isApplying: true))
        .frame(width: 320, height: 640)
}

#Preview("Read-only") {
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "web-page" })
        .frame(width: 320, height: 600)
}
