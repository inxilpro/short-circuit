import Foundation

// Records parsed from `lsregister -dump`. Unit IDs are the hex store identifiers LS prints
// after each record name, e.g. "Mud (0x2b40)"; claims and types refer to their bundle by it.

nonisolated struct TypeDecl: Hashable, Codable, Sendable {
    var unitID: String?
    var identifier: String
    var bundleUnitID: String?
    var bundleName: String?
    var localizedDescription: String?
    var flags: [String]
    var conformsTo: [String]
    /// Lowercased, without the leading dot.
    var extensions: [String]
    /// Lowercased.
    var mimeTypes: [String]

    /// Several bundles can declare the same UTI; only active declarations are what LS resolves against.
    var isActive: Bool { flags.contains("active") }
    var isDynamic: Bool { identifier.hasPrefix("dyn.") }
}

nonisolated struct Claim: Hashable, Codable, Sendable {
    var unitID: String?
    var name: String
    var rank: String?
    var bundleUnitID: String?
    var bundleName: String?
    var flags: [String]
    var roles: [String]
    var utis: [String]
    /// Lowercased, without the leading dot. Wildcards (`.*`) are dropped.
    var extensions: [String]
    /// Lowercased, without the trailing colon.
    var schemes: [String]
    var mimeTypes: [String]

    /// Claims with only these roles (or rank None) never make an app an "Open With" candidate.
    static let nonHandlingRoles: Set<String> = ["None", "Importer", "QLGenerator"]

    var canHandle: Bool {
        rank != "None" && roles.contains { !Self.nonHandlingRoles.contains($0) }
    }
}

nonisolated struct BundleRecord: Hashable, Codable, Sendable {
    var unitID: String?
    var name: String
    var identifier: String?
    var path: String?
    var displayName: String?
    var version: String?
    var bundleClass: String?
    /// The default entry of `localizedNames`; the only readable name some helpers have.
    var localizedName: String?

    var isApplication: Bool { bundleClass == "kLSBundleClassApplication" }

    var preferredName: String {
        AppNaming.name(candidates: [displayName, localizedName, name], path: path) ?? name
    }
}

nonisolated struct HandlerPref: Hashable, Codable, Sendable {
    enum Target: Hashable, Codable, Sendable {
        case contentType(String)
        case urlScheme(String)
        case filenameExtension(String)
        case other(tagClass: String, tag: String)
    }

    var unitID: String?
    var tag: String
    /// The dump labels URL schemes and UTIs alike as "unknown"; UTIs are told apart by their type reference.
    /// Empty when the record had no tag line at all.
    var tagClass: String
    var tagTypeUnitID: String?
    /// Role label (e.g. "all roles", "viewer") to handler bundle ID.
    var roleHandlers: [String: String]
    var modificationDate: Date?

    var target: Target {
        let tagClass = tagClass.lowercased()
        if tagClass.contains("extension") { return .filenameExtension(tag.lowercased()) }
        if tagTypeUnitID != nil || tagClass.contains("content") { return .contentType(tag) }
        if tagClass == "unknown" || tagClass.contains("scheme") { return .urlScheme(tag.lowercased()) }
        // Header-only records are ambiguous here; callers holding the full snapshot can resolve them.
        return .other(tagClass: self.tagClass, tag: tag)
    }

    /// Viewer is what "Open" uses, so it wins over editor when roles differ.
    var handlerBundleID: String? {
        for key in ["all roles", "all", "viewer", "editor", "shell"] {
            if let handler = roleHandlers[key] { return handler }
        }
        return roleHandlers.sorted { $0.key < $1.key }.first?.value
    }
}

nonisolated struct LSSnapshot: Codable, Sendable {
    /// Bumped when records gain fields, so older caches are re-dumped rather than read with gaps.
    static let currentFormatVersion = 2

    var formatVersion: Int = LSSnapshot.currentFormatVersion
    var capturedAt: Date
    var systemVersion: String?
    var cacheSequenceNumber: Int?
    var types: [TypeDecl]
    var claims: [Claim]
    var bundles: [BundleRecord]
    var handlerPrefs: [HandlerPref]
    /// Records the parser saw but doesn't model, by record label. Useful to notice format drift.
    var skippedRecordCounts: [String: Int]
}
