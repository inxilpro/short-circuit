import SwiftUI

struct KindGridView: View {
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

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 150), spacing: 8, alignment: .top)]

    var body: some View {
        ScrollView {
            if let secondary {
                let primary = kinds.filter { !secondary.ids.contains($0.id) }
                let others = kinds.filter { secondary.ids.contains($0.id) }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    Section {
                        tiles(primary)
                    } header: {
                        if primary.isEmpty {
                            SectionTitle(text: secondary.emptyPrimaryNote)
                        }
                    }
                    if !others.isEmpty {
                        Section {
                            tiles(others)
                        } header: {
                            SectionTitle(text: secondary.title)
                                .padding(.top, primary.isEmpty ? 0 : 12)
                        }
                    }
                }
                .padding(20)
            } else {
                LazyVGrid(columns: columns, spacing: 16) {
                    tiles(kinds)
                }
                .padding(20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection = nil }
    }

    private func tiles(_ kinds: [Kind]) -> some View {
        ForEach(kinds) { kind in
            KindTile(kind: kind, isSelected: selection == kind.id, isResolved: resolvedIDs.contains(kind.id))
                .onTapGesture { selection = kind.id }
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
    var isResolved = false

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
                            .fill(isSelected ? Color.accentColor : .clear)
                    )
                    .foregroundStyle(isSelected ? Color.white : .primary)

                DefaultAppLabel(kind: kind, isResolved: isResolved)
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
