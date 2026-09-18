import Foundation

/// Human names for app bundles. Helper apps often ship a team-ID-prefixed bundle identifier as their
/// name ("85C27NK92C.com.flexibits.fantastical2.mac.helper"), which must never reach the UI.
nonisolated enum AppNaming {
    /// Picks the first usable name; failing that, the enclosing app's name for a nested helper, then the
    /// bundle's file name.
    static func name(candidates: [String?], path: String?) -> String? {
        if let usable = candidates.lazy.compactMap({ $0 }).first(where: { !$0.isEmpty && !looksLikeIdentifier($0) }) {
            return usable
        }
        guard let path else { return nil }
        let appComponents = path.split(separator: "/").filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
        if appComponents.count > 1, let parent = appComponents.dropLast().last(where: { !looksLikeIdentifier($0) }) {
            return parent
        }
        return appComponents.last.flatMap { looksLikeIdentifier($0) ? nil : $0 }
    }

    /// Reverse-DNS text with no spaces, optionally behind a ten-character team ID.
    static func looksLikeIdentifier(_ name: String) -> Bool {
        guard !name.contains(" ") else { return false }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count >= 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) { return true }
        return parts.count >= 3 && parts.allSatisfy { !$0.isEmpty }
    }
}
