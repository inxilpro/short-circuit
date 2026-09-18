import SwiftUI

struct KindGridView: View {
    @Environment(KindStore.self) private var store

    struct SecondarySection {
        var title: String
        var ids: Set<Kind.ID>
        /// Shown in place of the primary tiles when only the secondary section has any.
        var emptyPrimaryNote: String
    }

    let kinds: [Kind]
    @Binding var selection: Kind.ID?
    var resolvedIDs: Set<Kind.ID> = []
    var secondary: SecondarySection?
    /// Return or a double-click: the icon view's "open", which here means choosing an app.
    var onActivate: () -> Void = {}
    /// Space, like Quick Look in Finder, shows or hides the details for the selection.
    var onToggleDetails: () -> Void = {}

    @FocusState private var isFocused: Bool
    @Environment(\.appearsActive) private var appearsActive
    @State private var width: CGFloat = 0
    @State private var typeSelect = TypeSelectBuffer()

    private static let padding: CGFloat = 20
    private static let spacing: CGFloat = 8
    private static let minimumTile: CGFloat = 120

    /// Where `.adaptive` breaks rows, so up and down land where they look like they should. The
    /// layout itself never reads this: feeding a measured width back into the columns loops.
    private var columnCount: Int {
        max(1, Int((width - Self.padding * 2 + Self.spacing) / (Self.minimumTile + Self.spacing)))
    }

    private let columns = [GridItem(.adaptive(minimum: minimumTile, maximum: 150), spacing: spacing, alignment: .top)]

    private var sections: (primary: [Kind], others: [Kind]) {
        guard let secondary else { return (kinds, []) }
        return (kinds.filter { !secondary.ids.contains($0.id) }, kinds.filter { secondary.ids.contains($0.id) })
    }

    var body: some View {
        let sections = sections
        ScrollViewReader { proxy in
            ScrollView {
                if let secondary {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        Section {
                            tiles(sections.primary)
                        } header: {
                            if sections.primary.isEmpty {
                                SectionTitle(text: secondary.emptyPrimaryNote)
                            }
                        }
                        if !sections.others.isEmpty {
                            Section {
                                tiles(sections.others)
                            } header: {
                                SectionTitle(text: secondary.title)
                                    .padding(.top, sections.primary.isEmpty ? 0 : 12)
                            }
                        }
                    }
                    .padding(Self.padding)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        tiles(kinds)
                    }
                    .padding(Self.padding)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = nil
                isFocused = true
            }
            .onCopyCommand { kinds.filter { $0.id == selection }.map(\.itemProvider) }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                move(direction.gridMove, in: sections)
            }
            .onKeyPress(.home) { move(.first, in: sections); return .handled }
            .onKeyPress(.end) { move(.last, in: sections); return .handled }
            .onKeyPress(.return) {
                guard selection != nil else { return .ignored }
                onActivate()
                return .handled
            }
            .onKeyPress(.space) {
                onToggleDetails()
                return .handled
            }
            .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
                guard press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
                let prefix = typeSelect.append(press.characters)
                if let match = TypeSelectBuffer.match(prefix, in: sections.primary + sections.others, name: \.name) {
                    selection = match.id
                }
                return .handled
            }
            .onExitCommand { selection = nil }
            .onChange(of: selection) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
            }
            .onAppear {
                // A selection made elsewhere (a dropped file, "Show in All Types") often lands in
                // a freshly built grid, so it has to be brought into view once the tiles exist.
                guard let selection else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }

    private func move(_ move: GridNavigator<Kind.ID>.Move, in sections: (primary: [Kind], others: [Kind])) {
        let navigator = GridNavigator(sections: [sections.primary.map(\.id), sections.others.map(\.id)], columns: columnCount)
        if let target = navigator.target(from: selection, move) {
            selection = target
        }
    }

    private func tiles(_ kinds: [Kind]) -> some View {
        ForEach(kinds) { kind in
            KindTile(
                kind: kind,
                isSelected: selection == kind.id,
                isEmphasized: isFocused && appearsActive,
                isResolved: resolvedIDs.contains(kind.id)
            )
            .id(kind.id)
            .accessibilityAction(named: "Show Details") {
                selection = kind.id
                onActivate()
            }
            .draggable(kind) {
                KindIconView(kind: kind, size: 48, showsBadge: false)
            }
            .contextMenu {
                KindActions(kind: kind, store: store)
            }
            .onTapGesture {
                selection = kind.id
                isFocused = true
            }
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                selection = kind.id
                onActivate()
            })
        }
    }
}

private extension MoveCommandDirection {
    var gridMove: GridNavigator<Kind.ID>.Move {
        switch self {
        case .left: .left
        case .right: .right
        case .up: .up
        case .down: .down
        @unknown default: .right
        }
    }
}

private struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KindTile: View {
    let kind: Kind
    let isSelected: Bool
    /// False when the grid isn't focused or the window isn't key: Finder greys the selection then.
    var isEmphasized = true
    var isResolved = false

    private var selectionFill: Color {
        isEmphasized ? .accentColor : Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
    }

    var body: some View {
        VStack(spacing: 6) {
            KindIconView(kind: kind, size: 64, isResolved: isResolved)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.primary.opacity(0.1) : .clear)
                )

            VStack(spacing: 2) {
                Text(kind.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(isSelected ? selectionFill : .clear)
                    )
                    .foregroundStyle(isSelected && isEmphasized ? Color.white : .primary)

                DefaultAppLabel(kind: kind, isResolved: isResolved)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind.name)
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// What the tile's second line says, as a sentence: the icon badge repeats it visually.
    private var accessibilityStatus: String {
        if isResolved { return String(localized: "Resolved") }
        if kind.isSplit { return String(localized: "Split: its identifiers open in different apps") }
        if kind.hasMixedHandlers { return String(localized: "Opens in different apps") }
        if let app = kind.defaultApp { return String(localized: "Opens with \(app.name)") }
        return String(localized: "No default app")
    }
}

#Preview {
    @Previewable @State var selection: Kind.ID? = "markdown"
    KindGridView(kinds: SampleKindProvider.kinds, selection: $selection)
        .environment(KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview))
        .frame(width: 640, height: 480)
}
