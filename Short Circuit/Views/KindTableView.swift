import SwiftUI

struct KindTableView: View {
    let kinds: [Kind]
    @Binding var selection: Kind.ID?

    var body: some View {
        Table(kinds, selection: $selection) {
            TableColumn("Name") { kind in
                HStack(spacing: 6) {
                    KindIconView(kind: kind, size: 18, showsBadge: false)
                    Text(kind.name)
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Opens With") { kind in
                HStack(spacing: 4) {
                    if let app = kind.defaultApp {
                        AppIconView(app: app, size: 16)
                    }
                    DefaultAppLabel(kind: kind)
                }
            }
            .width(min: 110, ideal: 140)

            TableColumn("Apps") { kind in
                Text(kind.candidates.count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(40)

            TableColumn("Extensions & Schemes") { kind in
                Text((kind.extensions.map { ".\($0)" } + kind.schemes.map { "\($0):" }).joined(separator: " "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            TableColumn("Category") { kind in
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
