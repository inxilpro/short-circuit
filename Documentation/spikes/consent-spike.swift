// Run with: swift Documentation/spikes/consent-spike.swift
// Interactive: changes the Markdown handlers, asks what prompts you saw, then restores the originals.

import AppKit
import UniformTypeIdentifiers

let workspace = NSWorkspace.shared
let identifiers = ["public.markdown", "net.daringfireball.markdown"]
let types = identifiers.compactMap { UTType($0) }

func name(_ url: URL?) -> String { url?.deletingPathExtension().lastPathComponent ?? "(none)" }

func pause(_ message: String) -> String {
    print("\n>>> \(message)")
    return readLine() ?? ""
}

func set(_ app: URL, for type: UTType) async {
    let started = Date()
    do {
        try await workspace.setDefaultApplication(at: app, toOpen: type)
        print("  set \(type.identifier) → \(name(app)): OK after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    } catch {
        let nsError = error as NSError
        print("  set \(type.identifier) → \(name(app)): ERROR \(nsError.domain) \(nsError.code) \(nsError.localizedDescription)")
    }
}

func report(_ label: String) {
    print("\n[\(label)]")
    for type in types {
        print("  \(type.identifier) → \(name(workspace.urlForApplication(toOpen: type)))")
    }
}

report("Before")
let originals = types.map { ($0, workspace.urlForApplication(toOpen: $0)) }

guard let first = types.first,
      let alternate = workspace.urlsForApplications(toOpen: first).first(where: { $0 != originals[0].1 })
else {
    print("No alternate candidate app for Markdown; nothing to test.")
    exit(1)
}
print("\nAlternate app: \(name(alternate))")

print("\nTest 1: NSWorkspace setter, \(types.count) UTIs back to back")
for type in types { await set(alternate, for: type) }
_ = pause("How many consent prompts appeared, and did the call return before you answered? Type notes, press Return.")
report("After test 1")

print("\nTest 2: restoring originals via deprecated LSSetDefaultRoleHandlerForContentType")
for (type, original) in originals {
    guard let original, let bundleID = Bundle(url: original)?.bundleIdentifier else { continue }
    let status = LSSetDefaultRoleHandlerForContentType(type.identifier as CFString, .all, bundleID as CFString)
    print("  LSSet \(type.identifier) → \(bundleID): OSStatus \(status)")
}
_ = pause("Did the deprecated API prompt? Type notes, press Return.")
report("After test 2")

let unrestored = originals.filter { workspace.urlForApplication(toOpen: $0.0) != $0.1 }
if !unrestored.isEmpty {
    print("\nRestoring \(unrestored.count) handler(s) via NSWorkspace")
    for (type, original) in unrestored {
        if let original { await set(original, for: type) }
    }
    _ = pause("Answer any prompts, then press Return.")
    report("Final")
}
