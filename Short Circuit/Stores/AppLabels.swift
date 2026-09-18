import Foundation

/// Display names that stay distinguishable when several installs of one app are listed together,
/// such as two Adobe Illustrator versions in different folders.
nonisolated struct AppLabels: Sendable {
    private var labels: [URL: String] = [:]

    init(_ apps: [AppRef]) {
        var seen = Set<URL>()
        let unique = apps.filter { seen.insert($0.url.standardizedFileURL).inserted }
        for group in Dictionary(grouping: unique, by: \.name).values {
            guard group.count > 1 else { continue }
            let versionCounts = Dictionary(group.map { ($0.version ?? "", 1) }, uniquingKeysWith: +)
            for app in group {
                var details: [String] = []
                if let version = app.version, !version.isEmpty {
                    details.append(version)
                }
                if versionCounts[app.version ?? "", default: 0] > 1 {
                    details.append(Self.abbreviatedFolder(of: app.url))
                }
                labels[app.url.standardizedFileURL] = "\(app.name) (\(details.joined(separator: ", ")))"
            }
        }
    }

    func label(for app: AppRef) -> String {
        labels[app.url.standardizedFileURL] ?? app.name
    }

    static func abbreviatedFolder(of url: URL) -> String {
        (url.deletingLastPathComponent().path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

extension Kind {
    /// Every app the inspector may list for this Kind, so labels are computed against all of them.
    var labelContext: AppLabels {
        AppLabels(candidates + members.compactMap(\.defaultApp))
    }
}
