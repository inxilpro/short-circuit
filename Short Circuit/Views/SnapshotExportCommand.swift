#if DEBUG
import AppKit
import UniformTypeIdentifiers

/// Debug-only: writes the Launch Services snapshot used to build and review Catalog.json.
enum SnapshotExportCommand {
    static func run(kinds: [Kind]) async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "launch-services-snapshot.json"
        panel.message = "Export every claimed type, scheme, and claiming app as JSON."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let snapshot = try await LaunchServicesIndex().snapshot()
            let data = try SnapshotExporter.encode(SnapshotExporter.export(snapshot, kinds: kinds))
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn’t export the snapshot"
            alert.runModal()
        }
    }
}
#endif
