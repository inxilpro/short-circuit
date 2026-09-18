import SwiftUI

struct KindIconView: View {
    let kind: Kind
    var size: CGFloat = 64
    var showsBadge = true

    var body: some View {
        documentIcon
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    badge
                        .offset(x: size * 0.08, y: size * 0.04)
                }
            }
    }

    @ViewBuilder
    private var documentIcon: some View {
        if let uti = kind.utis.first {
            Image(nsImage: IconCache.icon(forTypeIdentifier: uti))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "link")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .fontWeight(.light)
                .foregroundStyle(.tint)
                .padding(size * 0.18)
        }
    }

    @ViewBuilder
    private var badge: some View {
        let badgeSize = size * 0.42
        if let app = kind.defaultApp {
            AppIconView(app: app, size: badgeSize)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
        } else if kind.isSplit {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: badgeSize * 0.7))
                .frame(width: badgeSize, height: badgeSize)
        }
    }
}

struct AppIconView: View {
    let app: AppRef
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconCache.icon(for: app))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel(app.name)
    }
}

struct DefaultAppLabel: View {
    let kind: Kind

    var body: some View {
        if kind.isSplit {
            Label("Split", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if let app = kind.defaultApp {
            Text(app.name)
                .foregroundStyle(.secondary)
        } else {
            Text("No default")
                .foregroundStyle(.tertiary)
        }
    }
}

#Preview {
    HStack(spacing: 24) {
        ForEach(SampleKindProvider.kinds.prefix(4).map { $0 } + SampleKindProvider.kinds.filter { $0.utis.isEmpty }) { kind in
            KindIconView(kind: kind)
        }
    }
    .padding(40)
}
