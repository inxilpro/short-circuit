import Foundation

// The project defaults to MainActor isolation; these value types are explicitly
// nonisolated so the background indexing actor can build them.

nonisolated enum KindCategory: String, CaseIterable, Codable, Sendable {
    case documents, images, audio, video, code, archives, web, communication, developer, other
}

nonisolated struct AppRef: Identifiable, Hashable, Codable, Sendable {
    var url: URL
    var bundleID: String?
    var name: String
    var version: String?

    var id: URL { url }
}

nonisolated struct KindMember: Identifiable, Hashable, Codable, Sendable {
    enum Target: Hashable, Codable, Sendable {
        case uti(String)
        case scheme(String)
    }

    var target: Target
    var defaultApp: AppRef?

    var id: Target { target }
}

nonisolated struct Kind: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var name: String
    var category: KindCategory
    var members: [KindMember]
    var extensions: [String]
    var mimeTypes: [String]
    /// Ordered by relevance: current defaults, then apps that explicitly claim a member, then apps that
    /// only match through broad conformance (plain text and the like); alphabetical within each tier.
    /// Unique by URL, so two installs sharing a bundle ID both appear.
    var candidates: [AppRef]
    /// A URL scheme registered by a single app for its own use (login callbacks and the like). Nothing
    /// else can meaningfully handle it, so it belongs outside Common.
    var isAppPrivate: Bool = false

    var utis: [String] {
        members.compactMap { if case .uti(let identifier) = $0.target { identifier } else { nil } }
    }

    var schemes: [String] {
        members.compactMap { if case .scheme(let scheme) = $0.target { scheme } else { nil } }
    }

    var isSplit: Bool {
        Set(members.map(\.defaultApp?.url)).count > 1
    }

    /// Nil when the Kind is split or nothing handles it.
    var defaultApp: AppRef? {
        isSplit ? nil : members.first?.defaultApp
    }
}

nonisolated protocol KindProviding: Sendable {
    func loadKinds(forceRefresh: Bool) async throws -> [Kind]
}
