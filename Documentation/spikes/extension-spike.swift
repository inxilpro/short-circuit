// Run with: swift Documentation/spikes/extension-spike.swift
// Reads only:  swift Documentation/spikes/extension-spike.swift --dry-run
//
// Measures NSWorkspace.setDefaultApplication(at:toOpenFileAt:) on a `.markdown` file, whose extension
// resolves to a dyn. type on some Macs so no settable UTI governs it. Interactive: changes the handler
// for that one file, asks what prompts you saw, diffs every related handler, then restores it.

import AppKit
import UniformTypeIdentifiers

let dryRun = CommandLine.arguments.contains("--dry-run")
let workspace = NSWorkspace.shared
let lsregister = "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

let probedExtensions = ["markdown", "mdown", "mkd"]
let trackedExtensions = ["md", "markdown", "mdown", "mkd", "txt"]
let trackedTypes = ["net.daringfireball.markdown", "public.plain-text", "public.text", "public.data"]
let target = "markdown"

// MARK: - Helpers

func name(_ url: URL?) -> String { url?.deletingPathExtension().lastPathComponent ?? "(none)" }

/// Symlinked and cryptex spellings of one app compare equal.
func identity(_ url: URL?) -> String { url?.standardizedFileURL.resolvingSymlinksInPath().path ?? "(none)" }

func pause(_ message: String) -> String {
    print("\n>>> \(message)")
    return readLine() ?? ""
}

let directory = FileManager.default.temporaryDirectory.appending(path: "extension-spike-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
var files: [String: URL] = [:]
for ext in trackedExtensions {
    let url = directory.appending(path: "spike.\(ext)")
    try Data("# Extension spike\n".utf8).write(to: url)
    files[ext] = url
}

func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
}

func contentType(of file: URL) -> String {
    (try? file.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier) ?? "(unknown)"
}

/// Every tracked handler, keyed by a label, valued by the app's resolved path.
func snapshot() -> [String: String] {
    var state: [String: String] = [:]
    for identifier in trackedTypes {
        state["type \(identifier)"] = identity(UTType(identifier).flatMap { workspace.urlForApplication(toOpen: $0) })
    }
    for ext in trackedExtensions {
        state["file .\(ext)"] = identity(files[ext].flatMap { workspace.urlForApplication(toOpen: $0) })
    }
    return state
}

func report(_ label: String, _ state: [String: String]) {
    print("\n[\(label)]")
    for key in state.keys.sorted() {
        print("  \(key) → \(name(URL(fileURLWithPath: state[key]!)))  (\(state[key]!))")
    }
}

/// Handler-pref records from `lsregister -dump` that mention the probed extensions or their dyn. types.
func handlerPrefs(matching needles: [String]) -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: lsregister)
    process.arguments = ["-dump"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return ["(lsregister failed to start)"] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let records = String(decoding: data, as: UTF8.self).components(separatedBy: String(repeating: "-", count: 80) + "\n")
    return records
        .filter { $0.hasPrefix("handlerpref id:") }
        .filter { record in needles.contains { record.localizedCaseInsensitiveContains($0) } }
        // The relative age ("𝛥 3hr 24min") changes between dumps and would make every record look new.
        .map { $0.replacingOccurrences(of: ", 𝛥[^)]*", with: "", options: .regularExpression) }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
}

func diff(_ before: [String: String], _ after: [String: String]) -> [String] {
    before.keys.sorted().compactMap { key in
        before[key] == after[key] ? nil : "\(key): \(name(URL(fileURLWithPath: before[key]!))) → \(name(URL(fileURLWithPath: after[key] ?? "(none)")))"
    }
}

@MainActor func setFile(_ app: URL, for file: URL) async -> (ok: Bool, detail: String) {
    let started = Date()
    do {
        try await workspace.setDefaultApplication(at: app, toOpenFileAt: file)
        return (true, String(format: "OK after %.1fs", Date().timeIntervalSince(started)))
    } catch {
        let nsError = error as NSError
        return (false, String(format: "ERROR %@ %d after %.1fs: %@", nsError.domain, nsError.code, Date().timeIntervalSince(started), nsError.localizedDescription))
    }
}

// MARK: - 1. How the probed extensions resolve

print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\(dryRun ? "  (dry run: reads only)" : "")")
print("\n[Resolution]")
var dynamicIdentifiers: [String] = []
for ext in probedExtensions {
    let flat = UTType(filenameExtension: ext)
    if let flat, flat.isDynamic { dynamicIdentifiers.append(flat.identifier) }
    let file = files[ext]!
    let current = workspace.urlForApplication(toOpen: file)
    let candidates = workspace.urlsForApplications(toOpen: file)
    print("  .\(ext): flat lookup → \(flat?.identifier ?? "nil")\(flat?.isDynamic == true ? " (dyn.)" : "")")
    print("         file content type → \(contentType(of: file))")
    print("         default → \(name(current))")
    print("         candidates (\(candidates.count)) → \(candidates.map(name).joined(separator: ", "))")
}

// MARK: - 2. Before

let prefNeedles = ["markdown", "mdown", "mkd"] + dynamicIdentifiers
let before = snapshot()
let prefsBefore = handlerPrefs(matching: prefNeedles)
report("Before", before)
print("\n[Handler prefs before: \(prefsBefore.count)]")
for record in prefsBefore { print(record.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")) }

// MARK: - 3. Change only the .markdown file

let targetFile = files[target]!
let original = workspace.urlForApplication(toOpen: targetFile)
guard let alternate = workspace.urlsForApplications(toOpen: targetFile).first(where: { identity($0) != identity(original) }) else {
    print("\nNo alternate app is listed for .\(target); nothing to test.")
    cleanUp()
    exit(1)
}
print("\nPlan: set .\(target) → \(name(alternate)) (currently \(name(original))), then restore.")

if dryRun {
    print("\n--- SUMMARY (dry run) ---")
    for ext in probedExtensions {
        print("resolve.\(ext)=\(UTType(filenameExtension: ext)?.identifier ?? "nil")")
    }
    print("original=\(name(original))")
    print("alternate=\(name(alternate))")
    print("prefs_before=\(prefsBefore.count)")
    print("--- END ---")
    cleanUp()
    exit(0)
}

guard let original else {
    print("\n.\(target) has no current default, so it couldn't be restored afterwards; stopping.")
    cleanUp()
    exit(1)
}

print("\nStep 3: setDefaultApplication(at: \(name(alternate)), toOpenFileAt: spike.\(target))")
let change = await setFile(alternate, for: targetFile)
print("  \(change.detail)")
let changePrompts = pause("How many prompts appeared, and what did they say (app names, file type wording)? Type notes, press Return.")

// MARK: - 4. After

let after = snapshot()
let prefsAfter = handlerPrefs(matching: prefNeedles)
report("After change", after)
let changed = diff(before, after)
print("\n[Changed handlers: \(changed.count)]")
for line in changed { print("  \(line)") }
let newPrefs = prefsAfter.filter { !prefsBefore.contains($0) }
print("\n[Handler prefs written or changed: \(newPrefs.count)]")
for record in newPrefs { print(record.split(separator: "\n").map { "  " + $0 }.joined(separator: "\n")) }

// MARK: - 5. Restore

print("\nStep 5: restoring .\(target) → \(name(original)) the same way")
let restore = await setFile(original, for: targetFile)
print("  \(restore.detail)")
let restorePrompts = pause("How many prompts appeared this time? Type notes, press Return.")

let final = snapshot()
let prefsFinal = handlerPrefs(matching: prefNeedles)
report("After restore", final)
let unrestored = diff(before, final)
let restored = unrestored.isEmpty
print(restored ? "\nEverything matches the Before state." : "\nNOT restored:")
for line in unrestored { print("  \(line)") }
if !restored {
    print("\nManual recovery:")
    for key in before.keys.sorted() where before[key] != final[key] {
        let app = name(URL(fileURLWithPath: before[key]!))
        if key.hasPrefix("file .") {
            let ext = key.dropFirst("file .".count)
            print("  • Finder: select any .\(ext) file → File › Get Info → Open with: \(app) → Change All…")
        } else {
            let identifier = key.dropFirst("type ".count)
            print("  • \(identifier): in Short Circuit, set it back to \(app); or Get Info on a file of that type → Open with: \(app) → Change All…")
        }
    }
}

cleanUp()

// MARK: - 6. Summary

print("\n--- SUMMARY (paste this back) ---")
for ext in probedExtensions {
    print("resolve.\(ext)=\(UTType(filenameExtension: ext)?.identifier ?? "nil")")
}
print("original=\(name(original))")
print("alternate=\(name(alternate))")
print("set_result=\(change.ok ? "ok" : "error") \(change.detail)")
print("set_prompts=\(changePrompts)")
print("changed_count=\(changed.count)")
for line in changed { print("changed=\(line)") }
print("only_markdown_changed=\(changed.allSatisfy { $0.hasPrefix("file .markdown") } && !changed.isEmpty)")
print("prefs_written=\(newPrefs.count)")
for record in newPrefs {
    print("pref=\(record.replacingOccurrences(of: "\n", with: " | ").replacingOccurrences(of: "  +", with: " ", options: .regularExpression))")
}
print("restore_result=\(restore.ok ? "ok" : "error") \(restore.detail)")
print("restore_prompts=\(restorePrompts)")
print("restored=\(restored)")
print("prefs_final=\(prefsFinal.count) (before \(prefsBefore.count))")
print("--- END ---")
