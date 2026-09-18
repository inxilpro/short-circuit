import SwiftUI

struct KindTableView: View {
    let kinds: [Kind]
    @Binding var selection: Kind.ID?
    var resolvedIDs: Set<Kind.ID> = []
    /// Empty until the user clicks a column header, so the caller's order (catalog rank in
    /// Common) is the default.
    @State private var sortOrder: [KeyPathComparator<Kind>] = []

    private var sortedKinds: [Kind] {
        sortOrder.isEmpty ? kinds : kinds.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedKinds, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { kind in
                HStack(spacing: 6) {
                    KindIconView(kind: kind, size: 18, showsBadge: false)
                    Text(kind.name)
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Opens With", value: \.defaultAppSortName) { kind in
                HStack(spacing: 4) {
                    if let app = kind.defaultApp {
                        AppIconView(app: app, size: 16)
                    }
                    DefaultAppLabel(kind: kind, isResolved: resolvedIDs.contains(kind.id))
                }
            }
            .width(min: 110, ideal: 140)

            TableColumn("Apps", value: \.candidates.count) { kind in
                Text(kind.candidates.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(40)

            TableColumn("Extensions & Schemes", value: \.targetsSortText) { kind in
                Text((kind.extensions.map { ".\($0)" } + kind.schemes.map { "\($0):" }).joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("Category", value: \.category.title) { kind in
                Text(kind.category.title)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
    }
}

#Preview {
    @Previewable @State var selection: Kind.ID? = "markdown"
    KindTableView(kinds: SampleKindProvider.kinds, selection: $selection)
        .frame(width: 720, height: 480)
}

private extension Kind {
    /// Split Kinds sort after every app name rather than under an empty string.
    var defaultAppSortName: String {
        defaultApp?.name ?? (isSplit ? "\u{10FFFF}Split" : "\u{10FFFF}")
    }

    var targetsSortText: String {
        (extensions + schemes).joined(separator: " ")
    }
}
