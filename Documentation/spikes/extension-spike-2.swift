// Run with: swift Documentation/spikes/extension-spike-2.swift
//
// Findings: Documentation/launch-services.md, "Extensions no declared type governs".
//
// The first extension spike read the default back from the same file it had set, so it could not tell
// "every .markdown file changed" from "that one file changed". In the app the by-file change reported
// success and then a fresh .markdown file still opened in the old app. This measures both routes against
// a second, untouched file:
//
//   Test 1  setDefaultApplication(at:toOpenFileAt:)  on file A, then read file A, fresh file B, the type
//   Test 2  setDefaultApplication(at:toOpen:)        with the generated dyn. type, same reads
//
// Interactive. Everything it changes is restored at the end.

import AppKit
import UniformTypeIdentifiers

let workspace = NSWorkspace.shared
let ext = "markdown"

func name(_ url: URL?) -> String { url?.deletingPathExtension().lastPathComponent ?? "(none)" }
func identity(_ url: URL?) -> String { url?.standardizedFileURL.resolvingSymlinksInPath().path ?? "(none)" }

func pause(_ message: String) -> String {
    print("\n>>> \(message)")
    return readLine() ?? ""
}

guard let type = UTType(filenameExtension: ext), type.isDynamic else {
    print(".\(ext) resolves to a declared type on this Mac; this spike only covers generated types.")
    exit(1)
}

let directory = FileManager.default.temporaryDirectory.appending(path: "extension-spike-2-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func makeFile(_ label: String) throws -> URL {
    let url = directory.appending(path: "\(label).\(ext)")
    try Data("# Extension spike 2\n".utf8).write(to: url)
    return url
}

func attributes(of file: URL) -> [String] {
    let size = listxattr(file.path, nil, 0, 0)
    guard size > 0 else { return [] }
    var buffer = [CChar](repeating: 0, count: size)
    listxattr(file.path, &buffer, size, 0)
    return buffer.split(separator: 0).map { String(decoding: $0.map(UInt8.init(bitPattern:)), as: UTF8.self) }
}

func report(_ label: String, setFile: URL?) throws {
    let fresh = try makeFile("fresh-\(UUID().uuidString.prefix(6))")
    print("\n[\(label)]")
    print("  by type (\(type.identifier)) → \(name(workspace.urlForApplication(toOpen: type)))")
    print("  fresh file               → \(name(workspace.urlForApplication(toOpen: fresh)))")
    if let setFile {
        print("  the file that was set    → \(name(workspace.urlForApplication(toOpen: setFile)))")
        print("  its extended attributes  → \(attributes(of: setFile))")
    }
}

@MainActor func attempt(_ label: String, _ body: () async throws -> Void) async {
    let started = Date()
    do {
        try await body()
        print(String(format: "  %@: OK after %.1fs", label, Date().timeIntervalSince(started)))
    } catch {
        let nsError = error as NSError
        print(String(format: "  %@: ERROR %@ %d after %.1fs: %@", label, nsError.domain, nsError.code, Date().timeIntervalSince(started), nsError.localizedDescription))
    }
}

print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
let original = workspace.urlForApplication(toOpen: type)
let candidates = workspace.urlsForApplications(toOpen: type)
guard let original, let alternate = candidates.first(where: { identity($0) != identity(original) }) else {
    print("No alternate app is listed for .\(ext); nothing to test.")
    exit(1)
}
print(".\(ext) → \(type.identifier); default \(name(original)); candidates \(candidates.map(name))")
try report("Before", setFile: nil)

print("\nTest 1: by file, → \(name(alternate))")
let fileA = try makeFile("set-by-file")
await attempt("setDefaultApplication(at:toOpenFileAt:)") {
    try await workspace.setDefaultApplication(at: alternate, toOpenFileAt: fileA)
}
_ = pause("Test 1: did macOS show a prompt? Type notes, press Return.")
try report("After test 1", setFile: fileA)

print("\nTest 2: by generated type, → \(name(alternate))")
await attempt("setDefaultApplication(at:toOpen: \(type.identifier))") {
    try await workspace.setDefaultApplication(at: alternate, toOpen: type)
}
_ = pause("Test 2: did macOS show a prompt? Allow it if so. Type notes, press Return.")
try report("After test 2", setFile: nil)

if identity(workspace.urlForApplication(toOpen: type)) != identity(original) {
    print("\nRestoring .\(ext) → \(name(original)) by type")
    await attempt("restore") { try await workspace.setDefaultApplication(at: original, toOpen: type) }
    _ = pause("Allow the restore prompt if one appears, then press Return.")
}
try report("Final", setFile: nil)
print(identity(workspace.urlForApplication(toOpen: type)) == identity(original) ? "\nRestored." : "\nNOT restored: set .\(ext) back to \(name(original)) by hand.")
