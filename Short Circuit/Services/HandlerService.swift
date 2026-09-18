import AppKit
import Foundation
import UniformTypeIdentifiers

/// The reads LiveKindProvider needs, so tests can stand in for Launch Services.
nonisolated protocol HandlerLookup: Sendable {
    func defaultApplicationURL(forContentType identifier: String) -> URL?
    func applicationURLs(forContentType identifier: String) -> [URL]
    func defaultApplicationURL(forScheme scheme: String) -> URL?
    func applicationURLs(forScheme scheme: String) -> [URL]
    /// The declared types macOS resolves this extension to: one for a flat file and one for a package
    /// directory (`.pages` is both). `dyn.` results mean no declared type wins and are left out.
    func contentTypes(forFilenameExtension ext: String) -> Set<String>
    func declaredExtensions(forContentType identifier: String) -> [String]
}

/// Live default-handler lookups through NSWorkspace. Launch Services answers these from its own
/// database, so they reflect the current state even when the parsed snapshot is stale.
nonisolated struct HandlerService: HandlerLookup {
    // MARK: - Reads

    func defaultApplicationURL(forContentType identifier: String) -> URL? {
        guard let type = UTType(identifier) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: type)
    }

    func applicationURLs(forContentType identifier: String) -> [URL] {
        guard let type = UTType(identifier) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: type)
    }

    func defaultApplicationURL(forScheme scheme: String) -> URL? {
        guard let probe = Self.probeURL(forScheme: scheme) else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    func applicationURLs(forScheme scheme: String) -> [URL] {
        guard let probe = Self.probeURL(forScheme: scheme) else { return [] }
        return NSWorkspace.shared.urlsForApplications(toOpen: probe)
    }

    func contentTypes(forFilenameExtension ext: String) -> Set<String> {
        Set([UTType.data, .package].compactMap { UTType(filenameExtension: ext, conformingTo: $0) }.filter { !$0.isDynamic }.map(\.identifier))
    }

    func declaredExtensions(forContentType identifier: String) -> [String] {
        UTType(identifier)?.tags[.filenameExtension] ?? []
    }

    func defaultApplication(forContentType identifier: String) -> AppRef? {
        defaultApplicationURL(forContentType: identifier).map(Self.appRef(for:))
    }

    func applications(forContentType identifier: String) -> [AppRef] {
        applicationURLs(forContentType: identifier).map(Self.appRef(for:))
    }

    func defaultApplication(forScheme scheme: String) -> AppRef? {
        defaultApplicationURL(forScheme: scheme).map(Self.appRef(for:))
    }

    func applications(forScheme scheme: String) -> [AppRef] {
        applicationURLs(forScheme: scheme).map(Self.appRef(for:))
    }

    /// Launch Services resolves scheme handlers from the scheme alone, so a bare `scheme:` URL is enough.
    static func probeURL(forScheme scheme: String) -> URL? {
        URL(string: "\(scheme):")
    }

    static func appRef(for url: URL) -> AppRef {
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let name = AppNaming.name(
            candidates: [info["CFBundleDisplayName"] as? String, info["CFBundleName"] as? String],
            path: url.path(percentEncoded: false)
        ) ?? url.deletingPathExtension().lastPathComponent
        return AppRef(
            url: url,
            bundleID: info["CFBundleIdentifier"] as? String,
            name: name,
            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String
        )
    }

    // MARK: - Writes
    // Milestone 3: setDefaultApplication(at:toOpen:) and setDefaultApplication(at:toOpenURLsWithScheme:),
    // followed by a delayed re-read because the call returns before the user answers the consent prompt.
}
