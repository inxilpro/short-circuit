import SwiftUI

struct KindInspectorView: View {
    let kind: Kind?
    /// Nil until the write path exists; every editing control disables itself when it is.
    var onSetDefault: ((AppRef, Kind) -> Void)?

    var body: some View {
        if let kind {
            KindInspectorForm(kind: kind, onSetDefault: onSetDefault)
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
    let onSetDefault: ((AppRef, Kind) -> Void)?

    private var canEdit: Bool { onSetDefault != nil }

    var body: some View {
        Form {
            Section {
                header
            }

            Section("Opens With") {
                OpensWithPicker(kind: kind, onSetDefault: onSetDefault)
                if kind.isSplit {
                    SplitNotice(kind: kind, onSetDefault: onSetDefault)
                }
            }

            Section("Members") {
                ForEach(kind.members) { member in
                    MemberRow(member: member, isOddOneOut: kind.isSplit && member.defaultApp?.url != kind.majorityApp?.url)
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

private struct OpensWithPicker: View {
    let kind: Kind
    let onSetDefault: ((AppRef, Kind) -> Void)?

    /// A member's handler can be an app that no longer claims the type, so it must still appear.
    private var choices: [AppRef] {
        var seen = Set<URL>()
        return (kind.candidates + kind.members.compactMap(\.defaultApp)).filter { seen.insert($0.url).inserted }
    }

    var body: some View {
        Picker("Default app", selection: selection) {
            if kind.defaultApp == nil {
                Text(kind.isSplit ? "Mixed" : "None").tag(AppRef?.none)
                Divider()
            }
            ForEach(choices) { app in
                Label {
                    Text(app.name)
                } icon: {
                    AppIconView(app: app, size: 16)
                }
                .tag(Optional(app))
            }
        }
        .disabled(onSetDefault == nil)
        .help(onSetDefault == nil ? "Changing the default app isn’t available yet." : "")
    }

    private var selection: Binding<AppRef?> {
        Binding(
            get: { kind.defaultApp },
            set: { app in
                if let app { onSetDefault?(app, kind) }
            }
        )
    }
}

private struct SplitNotice: View {
    let kind: Kind
    let onSetDefault: ((AppRef, Kind) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("These members open in different apps, so files of this type may not open where you expect.", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let majority = kind.majorityApp {
                Button("Fix Split — Use \(majority.name) for All") {
                    onSetDefault?(majority, kind)
                }
                .disabled(onSetDefault == nil)
            }
        }
    }
}

private struct MemberRow: View {
    let member: KindMember
    let isOddOneOut: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: member.target.isScheme ? "link" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(member.target.displayName)
                    .font(.callout.monospaced())
                    .lineLimit(2)
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
            }
        }
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

#Preview("Split") {
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "markdown" })
        .frame(width: 320, height: 600)
}

#Preview("Web page") {
    KindInspectorView(kind: SampleKindProvider.kinds.first { $0.id == "web-page" })
        .frame(width: 320, height: 600)
}

#Preview("Empty") {
    KindInspectorView(kind: nil)
        .frame(width: 320, height: 400)
}
