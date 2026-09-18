import SwiftUI

struct KindIconView: View {
    let kind: Kind
    var size: CGFloat = 64
    var showsBadge = true
    /// Shown in the Split section for Kinds that were split when loaded and have since been fixed.
    var isResolved = false

    var body: some View {
        documentIcon
            .frame(width: size, height: size)
            .accessibilityHidden(true)
            .overlay(alignment: .bottomTrailing) {
                if showsBadge {
                    badge
                        .offset(x: size * 0.08, y: size * 0.04)
                }
            }
    }

    @ViewBuilder
    private var documentIcon: some View {
        if let uti = kind.iconTypeIdentifier {
            Image(nsImage: IconCache.icon(forTypeIdentifier: uti))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: kind.utis.isEmpty ? "link" : "doc")
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
        if isResolved {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.system(size: badgeSize * 0.7))
                .frame(width: badgeSize, height: badgeSize)
        } else if let app = kind.defaultApp {
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
    var isResolved = false

    var body: some View {
        if isResolved {
            Label("Resolved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if kind.isSplit {
            Label("Split", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else if kind.hasMixedHandlers {
            Text("Mixed")
                .foregroundStyle(.secondary)
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
