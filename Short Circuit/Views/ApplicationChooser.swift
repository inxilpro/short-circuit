import AppKit
import UniformTypeIdentifiers

enum ApplicationChooser {
    static func chooseApplication(forOpening kindName: String) -> AppRef? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)
        panel.message = "Choose an app to open \(kindName)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return HandlerService.appRef(for: url)
    }
}
