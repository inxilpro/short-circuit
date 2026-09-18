import SwiftUI

struct KindGridView: View {
    let kinds: [Kind]
    @Binding var selection: Kind.ID?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 8, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(kinds) { kind in
                    KindTile(kind: kind, isSelected: selection == kind.id)
                        .onTapGesture { selection = kind.id }
                }
            }
            .padding(20)
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
    }
}

struct KindTile: View {
    let kind: Kind
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            KindIconView(kind: kind, size: 64)
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
                            .fill(isSelected ? Color.accentColor : .clear)
                    )
                    .foregroundStyle(isSelected ? Color.white : .primary)

                DefaultAppLabel(kind: kind)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    @Previewable @State var selection: Kind.ID? = "markdown"
    KindGridView(kinds: SampleKindProvider.kinds, selection: $selection)
        .frame(width: 640, height: 480)
}
