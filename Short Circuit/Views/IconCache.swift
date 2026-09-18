import AppKit
import UniformTypeIdentifiers

/// NSWorkspace icon lookups hit the disk and Launch Services, and tiles re-render often.
enum IconCache {
    private static var typeIcons: [String: NSImage] = [:]
    private static var appIcons: [URL: NSImage] = [:]

    static func icon(forTypeIdentifier identifier: String) -> NSImage {
        if let cached = typeIcons[identifier] { return cached }
        let icon = NSWorkspace.shared.icon(for: UTType(identifier) ?? .data)
        typeIcons[identifier] = icon
        return icon
    }

    static func icon(for app: AppRef) -> NSImage {
        if let cached = appIcons[app.url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path(percentEncoded: false))
        appIcons[app.url] = icon
        return icon
    }

    static func invalidate() {
        typeIcons.removeAll()
        appIcons.removeAll()
    }
}
