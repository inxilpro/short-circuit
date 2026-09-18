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

    /// Apple's own apps on the sealed system volume (`/System/Applications`, `/System/Library/CoreServices`).
    var isSystemApp: Bool { url.path(percentEncoded: false).hasPrefix("/System/") }
}

nonisolated struct KindMember: Identifiable, Hashable, Codable, Sendable {
    enum Target: Hashable, Codable, Sendable {
        case uti(String)
        case scheme(String)
    }

    var target: Target
    var defaultApp: AppRef?
    /// False for identifiers macOS refuses to assign a handler to, such as a UTI declared without
    /// conformance to public.item. No file resolves to such a type, so it must not count as a split.
    var isSettable: Bool = true
    /// Apps macOS lists for this member alone. The setter rejects any other app with error 256 and
    /// no prompt, and a Kind's candidates are a union, so not every candidate fits every member.
    /// Nil when unknown, which places no restriction.
    var candidateURLs: Set<URL>? = nil
    /// Extensions whose files macOS resolves to this type. Several types can declare `.docx`, but
    /// only one wins it, and only the winner's handler decides what opens the file. Empty means the
    /// type is known to win none (shadowed). Nil means extension governance is unknown or doesn't
    /// apply (a type that declares no extensions at all), which counts as effective.
    var governedExtensions: [String]? = nil

    /// True when this member's handler can affect what opens something: a URL scheme, or a type
    /// that wins at least one extension.
    var isEffective: Bool {
        guard isSettable else { return false }
        if case .scheme = target { return true }
        return governedExtensions.map { !$0.isEmpty } ?? true
    }

    func accepts(_ app: AppRef) -> Bool {
        guard isSettable else { return false }
        guard let candidateURLs else { return true }
        // An app chosen through "Other…" arrives spelled by NSOpenPanel, not by the provider.
        return candidateURLs.contains(AppIdentity.canonical(app.url)) || candidateURLs.contains(app.url)
    }

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
    /// Position in the curated Common list (lower first); nil when the Kind isn't common.
    var commonRank: Int? = nil
    /// Extra search terms from the catalog ("readme" for Markdown).
    var keywords: [String] = []
    /// The catalog entry this Kind came from, if any.
    var catalogID: String? = nil
    /// Extensions this Kind lists whose files macOS resolves to a type outside it (a `dyn.` type or
    /// another Kind's UTI), so this Kind's default doesn't decide what opens them.
    var unclaimedExtensions: [String] = []
    /// Candidates that explicitly claim a member UTI, a member scheme, or one of the Kind's extensions,
    /// as opposed to apps macOS only offers through broad conformance (Chrome for every text type).
    /// Canonical URLs, comparable with `candidates`.
    var explicitCandidateURLs: Set<URL> = []

    var isCommon: Bool { commonRank != nil }

    var utis: [String] {
        members.compactMap { if case .uti(let identifier) = $0.target { identifier } else { nil } }
    }

    var schemes: [String] {
        members.compactMap { if case .scheme(let scheme) = $0.target { scheme } else { nil } }
    }

    var settableMembers: [KindMember] {
        members.filter(\.isSettable)
    }

    /// The members whose handlers decide what actually opens: whole-Kind changes target exactly these.
    /// Empty when every member is known to be shadowed (Canon TIFF RAW loses `.tif` to TIFF); such a
    /// Kind has nothing a whole-Kind change could affect, though each member can still be set alone.
    var effectiveMembers: [KindMember] {
        members.filter(\.isEffective)
    }

    /// Apps every effective member accepts, in candidate order. Empty when there are no effective members.
    var unifyingCandidates: [AppRef] {
        let effective = effectiveMembers
        guard !effective.isEmpty else { return [] }
        return candidates.filter { app in effective.allSatisfy { $0.accepts(app) } }
    }

    var hasMixedHandlers: Bool {
        Set(effectiveMembers.map(\.defaultApp?.url)).count > 1
    }

    /// A split is a mismatch the user could fix. Members that no file resolves to don't count, and
    /// neither does a mismatch no single app could resolve, such as facetime: and facetime-audio:.
    var isSplit: Bool {
        hasMixedHandlers && !unifyingCandidates.isEmpty
    }

    /// For display. A Kind whose members are all shadowed still shows what its settable members open with.
    var defaultApp: AppRef? {
        if hasMixedHandlers { return nil }
        return (effectiveMembers.first ?? settableMembers.first)?.defaultApp
    }
}

nonisolated protocol KindProviding: Sendable {
    func loadKinds(forceRefresh: Bool) async throws -> [Kind]
}
