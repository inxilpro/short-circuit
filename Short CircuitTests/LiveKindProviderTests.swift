import Foundation
import Testing
@testable import Short_Circuit

struct LiveKindProviderTests {
    private func app(_ path: String, _ bundleID: String, _ name: String) -> AppRef {
        AppRef(url: URL(fileURLWithPath: path), bundleID: bundleID, name: name, version: nil)
    }

    @Test func candidatesAreTieredAndUniqueByURL() {
        let textEdit = app("/System/Applications/TextEdit.app", "com.apple.TextEdit", "TextEdit")
        let preview = app("/System/Applications/Preview.app", "com.apple.Preview", "Preview")
        let notes = app("/System/Applications/Notes.app", "com.apple.Notes", "Notes")
        let calculator = app("/System/Applications/Calculator.app", "com.apple.calculator", "Calculator")
        let chess = app("/System/Applications/Chess.app", "com.apple.Chess", "Chess")
        let missing = app("/Applications/Definitely Not Installed.app", "com.example.missing", "Missing")

        let merged = LiveKindProvider.mergeCandidates(
            live: [chess, textEdit, calculator, notes, missing],
            explicit: [preview, notes, textEdit],
            defaults: [textEdit.url]
        )
        #expect(merged.map(\.name) == ["TextEdit", "Notes", "Preview", "Calculator", "Chess"])
    }

    @Test func sameBundleIDAtTwoPathsStaysTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "LiveKindProviderTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = directory.appending(path: "Tool 2025.app")
        let new = directory.appending(path: "Tool 2026.app")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)

        let merged = LiveKindProvider.mergeCandidates(
            live: [AppRef(url: new, bundleID: "com.example.tool", name: "Tool", version: "2026")],
            explicit: [AppRef(url: old, bundleID: "com.example.tool", name: "Tool", version: "2025"),
                       AppRef(url: new, bundleID: "com.example.tool", name: "Tool", version: "2026")],
            defaults: []
        )
        #expect(merged.count == 2)
        #expect(merged.map(\.version) == ["2025", "2026"])
    }
}
