import SwiftUI

/// Everything the inspector needs to change handlers. Passing nil keeps the inspector read-only.
struct KindEditing {
    /// False while any change is applying anywhere in the app, or a refresh is running.
    var isEnabled = true
    var isApplying = false
    var progress: WriteProgress?
    var showsShadowedMembers = false
    var setShowsShadowedMembers: (Bool) -> Void = { _ in }
    var results: [MemberResult] = []
    var setDefault: (AppRef) -> Void
    var setMemberDefault: (AppRef, KindMember.Target) -> Void
    var fixSplit: () -> Void
    /// Opens the app panel as a sheet on the window; nil target means the whole type.
    var chooseOtherApp: (KindMember.Target?) -> Void = { _ in }
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
                if kind.hasWholeTypeTargets {
                    OpensWithPicker(kind: kind, choices: choices, isEnabled: canEdit) { app in
                        editing?.setDefault(app)
                    } onChooseOther: {
                        editing?.chooseOtherApp(nil)
                    }
                    .appDropTarget(isEnabled: canEdit) { app in
                        editing?.setDefault(app)
                    }
                } else {
                    // Every declared type here loses its extensions to another type, so changing
                    // "the whole type" would change nothing a file ever uses.
                    Label("None of these types is the preferred type for any extension on this Mac, so there’s no whole-type default to set. You can still set each identifier below.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if kind.members.contains(where: { WritePlan.browserRole.contains($0.target) }) {
                    BrowserRoleNotice()
                }
                if editing?.isApplying == true {
                    ApplyingNotice(progress: editing?.progress)
                } else if let results = editing?.results, !results.isEmpty {
                    ResultSummary(results: results)
                }
                if kind.isSplit {
                    SplitNotice(kind: kind, isEnabled: canEdit) {
                        editing?.fixSplit()
                    }
                } else if kind.hasMixedHandlers {
                    Label("These open in different apps, and no single app handles all of them.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Identifiers") {
                // Declared types and schemes first; extension rows follow them.
                ForEach(kind.effectiveMembers.filter { !$0.target.isFileExtension } + kind.effectiveMembers.filter(\.target.isFileExtension)) { member in
                    memberRow(member, isOddOneOut: kind.isSplit && member.defaultApp?.url != kind.majorityApp?.url)
                }
                if !kind.shadowedMembers.isEmpty {
                    DisclosureGroup(isExpanded: showsShadowed) {
                        ForEach(kind.shadowedMembers) { member in
                            memberRow(member, caption: shadowedCaption)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Not the preferred type for any extension (\(kind.shadowedMembers.count))")
                                .foregroundStyle(.secondary)
                            if kind.shadowedMembersDiffer {
                                Text("· differs")
                                    .foregroundStyle(.tertiary)
                                    .help("At least one of these points to a different app than the types above")
                            }
                        }
                    }
                }
                ForEach(kind.members.filter { !$0.isSettable }) { member in
                    memberRow(member, caption: "Not declared as a file type (public.item), so macOS won’t accept a default app for it.")
                }
            }

            if !kind.extensions.isEmpty {
                Section("Extensions") {
                    ChipList(items: kind.extensions.map { ".\($0)" })
                    if !kind.extensionsHandledElsewhere.isEmpty {
                        Text(Self.handledElsewhereText(kind.extensionsHandledElsewhere))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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

    private func memberRow(_ member: KindMember, isOddOneOut: Bool = false, caption: String? = nil) -> some View {
        MemberRow(
            kind: kind,
            member: member,
            isOddOneOut: isOddOneOut,
            caption: caption,
            result: resultsByTarget[member.target],
            choices: choices,
            isEnabled: canEdit
        ) { app in
            editing?.setMemberDefault(app, member.target)
        } onChooseOther: {
            editing?.chooseOtherApp(member.target)
        }
    }

    private var showsShadowed: Binding<Bool> {
        Binding(get: { editing?.showsShadowedMembers ?? false }, set: { editing?.setShowsShadowedMembers($0) })
    }

    /// Names the extensions the effective members do govern, so it's clear why this type is inert.
    private var shadowedCaption: String {
        let governed = kind.effectiveMembers.flatMap { $0.governedExtensions ?? [] }
        guard !governed.isEmpty else { return "Not the preferred type for any extension on this Mac." }
        let handlers = kind.effectiveMembers.count == 1 ? "the type above" : "the types above"
        return "Not the preferred type for any extension on this Mac. \(Self.formatted(governed)) prefer \(handlers)."
    }

    /// ".md, .markdown, and .mkd", or the first three and "others" for longer lists.
    static func formatted(_ extensions: [String]) -> String {
        var items = extensions.prefix(3).map { ".\($0)" }
        if extensions.count > 3 { items.append(String(localized: "others")) }
        return items.formatted(.list(type: .and))
    }

    static func handledElsewhereText(_ extensions: [String]) -> String {
        extensions.count == 1
            ? String(localized: "On this Mac, \(formatted(extensions)) resolves to a different type.")
            : String(localized: "On this Mac, \(formatted(extensions)) resolve to different types.")
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
    let onChooseOther: () -> Void

    var body: some View {
        Picker("Default app", selection: selection) {
            if kind.defaultApp == nil {
                Text(kind.hasMixedHandlers ? "Mixed" : "None").tag(AppChoice.none)
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

    /// Apps that can't take every member carry a quiet note, so choosing one isn't a surprise
    /// when some members stay put.
    private func appLabel(_ app: AppRef) -> some View {
        Label {
            if let note = kind.supportNote(for: app) {
                Text("\(choices.labels.label(for: app))  \(Text(note).foregroundStyle(.secondary))")
            } else {
                Text(choices.labels.label(for: app))
            }
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
                    onChooseOther()
                }
            }
        )
    }
}

/// Explains each macOS consent prompt as it appears, since the app no longer warns up front.
private struct ApplyingNotice: View {
    let progress: WriteProgress?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout)
                if let progress {
                    Text(progress.call.changesBrowser ? "Default browser (http, https, and HTML files)" : progress.call.call.friendlyName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        guard let progress else { return "Checking current apps…" }
        return ChangeWording.progressTitle(progress)
    }
}

struct ResultSummary: View {
    let results: [MemberResult]

    var body: some View {
        let changed = results.filter { $0.outcome == .changed }.count
        let notChanged = results.filter(\.outcome.isNotChanged).count
        let failed = results.filter(\.outcome.isFailure).count
        let unsupported = results.filter(\.outcome.isNotSupported).count

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
            if unsupported > 0 {
                Label("\(unsupported) not supported", systemImage: "nosign")
                    .foregroundStyle(.secondary)
            }
            if changed + notChanged + failed + unsupported == 0 {
                Label("Nothing needed changing", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private struct SplitNotice: View {
    let kind: Kind
    let isEnabled: Bool
    let onFix: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("These identifiers open in different apps, so files of this type may not open where you expect.", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let app = kind.fixSplitApp {
                Button("Fix Split — Use \(kind.labelContext.label(for: app)) for All", action: onFix)
                    .disabled(!isEnabled)
            }
        }
    }
}

private struct MemberRow: View {
    let kind: Kind
    let member: KindMember
    let isOddOneOut: Bool
    /// Set for members that don't decide what opens (shadowed or unsettable); they're dimmed.
    let caption: String?
    let result: MemberResult?
    let choices: AppChoices
    let isEnabled: Bool
    let onChoose: (AppRef) -> Void
    let onChooseOther: () -> Void

    /// Members that don't decide what opens are dimmed, but their caption, which explains why,
    /// stays at full secondary contrast.
    private var dimming: Double { caption == nil ? 1 : 0.6 }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: member.target.isScheme ? "link" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .opacity(dimming)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                // Identifiers have no natural break points, so truncate in the middle, where two
                // similar ones are least likely to differ, and show the whole thing on hover.
                identifierTitle
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(member.target.displayName)
                    .opacity(dimming)

                HStack(spacing: 4) {
                    if let app = member.defaultApp {
                        AppIconView(app: app, size: 14)
                            .accessibilityHidden(true)
                        Text(choices.labels.label(for: app))
                    } else {
                        Text("No default")
                            .foregroundStyle(.tertiary)
                    }
                    if isOddOneOut {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .help("Opens in a different app than the rest of this type")
                            .accessibilityLabel("Opens in a different app than the rest of this type")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .opacity(dimming)

                if caption == nil, let governed = member.governedExtensions, !governed.isEmpty {
                    ChipList(items: governed.map { ".\($0)" }, size: .small)
                }

                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if member.isSettable, let result {
                    MemberResultLabel(result: result)
                }
            }

            Spacer(minLength: 0)

            if member.isSettable {
                memberMenu
            }
        }
        .appDropTarget(isEnabled: isEnabled && member.isSettable) { app in
            onChoose(app)
        }
        .contextMenu {
            if member.isSettable {
                memberMenuItems
                Divider()
            }
            Button("Copy Identifier") { Pasteboard.copy(member.target.displayName) }
            if let app = member.defaultApp {
                Divider()
                RevealAppButton(app: app)
            }
        }
    }

    private var isBrowserMember: Bool {
        WritePlan.browserRole.contains(member.target)
    }

    /// ".markdown files" for an extension row, so it reads as files rather than as a type.
    private var identifierTitle: Text {
        if case .fileExtension(let ext) = member.target {
            return Text("\(Text(verbatim: ".\(ext)").font(.callout.monospaced())) files").font(.callout)
        }
        return Text(verbatim: member.target.displayName).font(.callout.monospaced())
    }

    private var menuName: String {
        member.target.isFileExtension ? member.target.friendlyName : member.target.displayName
    }

    /// Browser members can't be changed alone, so their menu offers the browser-wide action
    /// under its real name instead of pretending to set one member.
    @ViewBuilder
    private var memberMenuItems: some View {
        Section(isBrowserMember ? "Default Browser (http, https, HTML files)" : "Open \(menuName) With") {
            ForEach(kind.candidates(for: member)) { app in
                Button {
                    onChoose(app)
                } label: {
                    Label {
                        Text(isBrowserMember ? "Make \(choices.labels.label(for: app)) the Default Browser" : choices.labels.label(for: app))
                    } icon: {
                        AppIconView(app: app, size: 16)
                    }
                }
                .disabled(AppIdentity.same(app.url, member.defaultApp?.url) && !isBrowserMember)
            }
        }
        Divider()
        Button("Other…", action: onChooseOther)
    }

    private var memberMenu: some View {
        Menu {
            memberMenuItems
        } label: {
            Image(systemName: isBrowserMember ? "globe" : "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityLabel(isBrowserMember ? "Change Default Browser" : "Choose App for \(menuName)")
        .help(isBrowserMember
              ? "Change the default browser, which macOS uses for http, https, and HTML files"
              : member.target.isFileExtension ? "Choose an app for \(menuName)" : "Choose an app for just this identifier")
    }
}

private struct BrowserRoleNotice: View {
    var body: some View {
        Label("macOS treats http, https, and HTML files as your default browser, so changing any of them changes all three.", systemImage: "globe")
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
        case .skipped(.notSupported(let app)):
            Label("\(app.name) can’t open this type", systemImage: "nosign")
                .foregroundStyle(.secondary)
        }
    }

    private static func shortDomain(_ domain: String) -> String {
        domain == NSCocoaErrorDomain ? "Cocoa" : domain
    }
}

private struct ChipList: View {
    enum Size {
        case regular, small
    }

    let items: [String]
    var size: Size = .regular

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(size == .small ? .caption.monospaced() : .callout.monospaced())
                    .padding(.horizontal, size == .small ? 5 : 6)
                    .padding(.vertical, size == .small ? 1 : 2)
                    .background(.quaternary, in: Capsule())
                    .draggable(item)
                    .contextMenu {
                        Button("Copy “\(item)”") { Pasteboard.copy(item) }
                    }
            }
        }
    }
}

private extension KindMember.Target {
    var isScheme: Bool {
        if case .scheme = self { true } else { false }
    }
}

extension MemberResult.Outcome {
    var isNotChanged: Bool {
        self == .unchangedAfterSuccess || self == .declined
    }

    var isFailure: Bool {
        if case .failed = self { true } else { false }
    }

    var isNotSupported: Bool {
        if case .skipped(.notSupported) = self { true } else { false }
    }
}

private func previewEditing(results: [MemberResult] = [], isEnabled: Bool = true, isApplying: Bool = false, progress: WriteProgress? = nil) -> KindEditing {
    KindEditing(isEnabled: isEnabled, isApplying: isApplying, progress: progress, results: results, setDefault: { _ in }, setMemberDefault: { _, _ in }, fixSplit: {})
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
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "web-page" }, editing: previewEditing(isEnabled: false, isApplying: true, progress: WriteProgress(step: 1, total: 2, call: WritePlan.Step(call: .scheme("http"), covers: WritePlan.browserTargets))))
        .frame(width: 320, height: 640)
}

#Preview("Read-only") {
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "web-page" })
        .frame(width: 320, height: 600)
}
