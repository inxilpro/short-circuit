import Foundation

/// One identity per installed app bundle, whatever path spelled it. `/Applications/Safari.app` and
/// `/System/Cryptexes/App/…` are symlinks to the Preboot copy NSWorkspace lists, and panels, the
/// snapshot and NSWorkspace also differ in trailing slashes and `..`. Distinct installs stay distinct.
nonisolated enum AppIdentity {
    static func canonical(_ url: URL) -> URL {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    static func same(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return canonical(lhs) == canonical(rhs)
    }
}
