import SwiftUI

struct KindTableView: View {
    @Environment(KindStore.self) private var store
    let kinds: [Kind]
    @Binding var selection: Kind.ID?
    var resolvedIDs: Set<Kind.ID> = []
    var onActivate: () -> Void = {}
    /// Empty until the user clicks a column header, so the caller's order (catalog rank in
    /// Common) is the default.
    @State private var sortOrder: [KeyPathComparator<Kind>] = []
    /// "column:ascending", remembered so a chosen sort survives relaunch.
    @AppStorage("kindTableSort") private var storedSort = ""
    @AppStorage("kindTableColumns") private var storedColumns = Data()
    @State private var columnCustomization = TableColumnCustomization<Kind>()

    private var sortedKinds: [Kind] {
        sortOrder.isEmpty ? kinds : kinds.sorted(using: sortOrder)
    }

    private static let sortColumnIDs = ["name", "opensWith", "apps", "targets", "category"]

    private static func comparator(for id: String) -> KeyPathComparator<Kind>? {
        switch id {
        case "name": KeyPathComparator(\Kind.name)
        case "opensWith": KeyPathComparator(\Kind.defaultAppSortName)
        case "apps": KeyPathComparator(\Kind.candidates.count)
        case "targets": KeyPathComparator(\Kind.targetsSortText)
        case "category": KeyPathComparator(\Kind.category.title)
        default: nil
        }
    }

    private static func encode(_ order: [KeyPathComparator<Kind>]) -> String {
        guard let first = order.first,
              let id = sortColumnIDs.first(where: { comparator(for: $0)?.keyPath == first.keyPath })
        else { return "" }
        return "\(id):\(first.order == .forward ? "ascending" : "descending")"
    }

    private static func decode(_ stored: String) -> [KeyPathComparator<Kind>] {
        let parts = stored.split(separator: ":").map(String.init)
        guard parts.count == 2, var comparator = comparator(for: parts[0]) else { return [] }
        comparator.order = parts[1] == "descending" ? .reverse : .forward
        return [comparator]
    }

    var body: some View {
        ScrollViewReader { proxy in
            Table(of: Kind.self, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                columns
            } rows: {
                ForEach(sortedKinds) { kind in
                    TableRow(kind)
                        .draggable(kind)
                }
            }
            .contextMenu(forSelectionType: Kind.ID.self) { ids in
                if let id = ids.first, let kind = kinds.first(where: { $0.id == id }) {
                    KindActions(kind: kind, store: store)
                }
            } primaryAction: { _ in
                onActivate()
            }
            .copyable(kinds.filter { $0.id == selection })
            .task {
                sortOrder = Self.decode(storedSort)
                if let saved = try? JSONDecoder().decode(TableColumnCustomization<Kind>.self, from: storedColumns) {
                    columnCustomization = saved
                }
            }
            .onChange(of: sortOrder) { storedSort = Self.encode(sortOrder) }
            .onChange(of: columnCustomization) {
                storedColumns = (try? JSONEncoder().encode(columnCustomization)) ?? Data()
            }
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            .onAppear {
                guard let selection else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(selection, anchor: .center)
                }
            }
        }
    }

    @TableColumnBuilder<Kind, KeyPathComparator<Kind>>
    private var columns: some TableColumnContent<Kind, KeyPathComparator<Kind>> {
        TableColumn("Name", value: \.name) { kind in
            HStack(spacing: 6) {
                KindIconView(kind: kind, size: 18, showsBadge: false)
                Text(kind.name)
            }
        }
        .width(min: 140, ideal: 180)
        .customizationID("name")
        .disabledCustomizationBehavior(.visibility)

        TableColumn("Opens With", value: \.defaultAppSortName) { kind in
            HStack(spacing: 4) {
                if let app = kind.defaultApp {
                    AppIconView(app: app, size: 16)
                }
                DefaultAppLabel(kind: kind, isResolved: resolvedIDs.contains(kind.id))
            }
        }
        .width(min: 110, ideal: 140)
        .customizationID("opensWith")

        TableColumn("Apps", value: \.candidates.count) { kind in
            Text(kind.candidates.count, format: .number)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .width(40)
        .customizationID("apps")

        TableColumn("Extensions & Schemes", value: \.targetsSortText) { kind in
            Text((kind.extensions.map { ".\($0)" } + kind.schemes.map { "\($0):" }).joined(separator: " "))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .customizationID("targets")

        TableColumn("Category", value: \.category.title) { kind in
            Text(kind.category.title)
                .foregroundStyle(.secondary)
        }
        .width(min: 80, ideal: 110)
        .customizationID("category")
    }
}

#Preview {
    @Previewable @State var selection: Kind.ID? = "markdown"
    KindTableView(kinds: SampleKindProvider.kinds, selection: $selection)
        .environment(KindStore(provider: SampleKindProvider(), writer: SimulatedHandlerWriter.preview))
        .frame(width: 720, height: 480)
}

private extension Kind {
    /// Split Kinds sort after every app name rather than under an empty string.
    nonisolated var defaultAppSortName: String {
        defaultApp?.name ?? (isSplit ? "\u{10FFFF}Split" : "\u{10FFFF}")
    }

    nonisolated var targetsSortText: String {
        (extensions + schemes).joined(separator: " ")
    }
}
