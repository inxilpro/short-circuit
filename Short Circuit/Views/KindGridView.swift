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
    /// The grid's own width, measured on the grid rather than the scroll view: the scroll view is
    /// wider by the padding, and by the scroller when the Mac shows one.
    @State private var contentWidth: CGFloat = 0
    @State private var typeSelect = TypeSelectBuffer()
    /// When the background was last clicked, so focus arriving that way doesn't select anything.
    @State private var clearedByClick: Date = .distantPast
    /// The tile under the pointer. SwiftUI builds context-menu content for tiles that were never
    /// clicked, so this is what tells a real right-click from a stray build.
    @State private var hovered: Kind.ID?

    private static let padding: CGFloat = 20
    private static let spacing: CGFloat = 8
    private static let minimumTile: CGFloat = 120

    /// Where `.adaptive` breaks rows, so up and down land where they look like they should. The
    /// layout itself never reads this: feeding a measured width back into the columns loops.
    private var columnCount: Int {
        GridNavigator<Kind.ID>.columnCount(fitting: contentWidth, minimum: Self.minimumTile, spacing: Self.spacing)
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
                    .measuringGridWidth($contentWidth)
                    .padding(Self.padding)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        tiles(kinds)
                    }
                    .measuringGridWidth($contentWidth)
                    .padding(Self.padding)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                selection = nil
                clearedByClick = .now
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
            .onExitCommand {
                // Keep the focus: Escape clears the selection, it doesn't leave the grid.
                selection = nil
                isFocused = true
            }
            .onChange(of: store.resultsFocusRequests) { isFocused = true }
            .onChange(of: store.resultsBlurRequests) { isFocused = false }
            .onChange(of: isFocused, initial: true) {
                #if DEBUG
                DebugGridMetrics.gridFocused = isFocused
                #endif
            }
            .onChange(of: isFocused) { _, focused in
                // Tab into the results should show where the keys will go. A click that cleared
                // the selection is the one case where nothing should be selected.
                guard focused, Date.now.timeIntervalSince(clearedByClick) > 0.3 else { return }
                let visible = sections.primary + sections.others
                if selection == nil || !visible.contains(where: { $0.id == selection }) {
                    selection = visible.first?.id
                }
            }
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

    private func selectForContextMenu(_ id: Kind.ID) {
        guard hovered == id, selection != id else { return }
        Task { @MainActor in
            selection = id
            isFocused = true
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
            .onHover { inside in
                if inside { hovered = kind.id } else if hovered == kind.id { hovered = nil }
            }
            .accessibilityAction(named: "Show Details") {
                selection = kind.id
                onActivate()
            }
            .draggable(kind) {
                KindIconView(kind: kind, size: 48, showsBadge: false)
            }
            .contextMenu {
                // Right-click acts on what it points at, as in Finder, so it selects first. The
                // selection is set after this build pass rather than during it.
                let _ = selectForContextMenu(kind.id)
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

private extension View {
    /// Reports the width `.adaptive` columns are fitted into.
    func measuringGridWidth(_ width: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
            width.wrappedValue = measured
            #if DEBUG
            DebugGridMetrics.contentWidth = measured
            DebugGridMetrics.columns = GridNavigator<Kind.ID>.columnCount(fitting: measured, minimum: 120, spacing: 8)
            #endif
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
