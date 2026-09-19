import Foundation

/// How changes and prompts are counted in words. Setting an extension through a file shows no
/// macOS prompt, so those changes are counted but never promised a prompt.
enum ChangeWording {
    /// "macOS will ask you to confirm 2 changes", "3 changes; macOS will ask about 2", or
    /// "1 change, made without a macOS prompt".
    static func summary(changes: Int, prompts: Int) -> String {
        switch (changes, prompts) {
        case (0, _):
            return String(localized: "nothing needs changing")
        case let (changes, prompts) where prompts == changes:
            return changes == 1
                ? String(localized: "macOS will ask you to confirm 1 change")
                : String(localized: "macOS will ask you to confirm \(changes) changes")
        case (1, 0):
            return String(localized: "1 change, made without a macOS prompt")
        case let (changes, 0):
            return String(localized: "\(changes) changes, made without a macOS prompt")
        case let (changes, prompts):
            return String(localized: "\(changes) changes; macOS will ask about \(prompts)")
        }
    }

    /// The line shown while a call runs. Only calls macOS confirms say they're waiting for it.
    static func progressTitle(_ progress: WriteProgress) -> String {
        if case .fileExtension = progress.call.call {
            let setting = String(localized: "Setting \(progress.call.call.friendlyName)…")
            return progress.total == 1 ? setting : String(localized: "\(setting) change \(progress.step) of \(progress.total)")
        }
        return progress.total == 1
            ? String(localized: "Waiting for macOS to confirm the change…")
            : String(localized: "Waiting for macOS… change \(progress.step) of \(progress.total)")
    }

    /// Said when an Undo starts.
    static func undoStart(changes: Int, prompts: Int) -> String {
        let restoring = changes == 1
            ? String(localized: "Restoring the previous app.")
            : String(localized: "Restoring the previous apps.")
        switch (changes, prompts) {
        case let (changes, prompts) where prompts == changes:
            return changes == 1
                ? restoring + " " + String(localized: "macOS will ask you to confirm the change.")
                : restoring + " " + String(localized: "macOS will ask you to confirm each of \(changes) changes.")
        case (_, 0):
            return restoring + " " + String(localized: "macOS doesn’t ask about these, so nothing will prompt you.")
        case let (changes, prompts):
            return restoring + " " + String(localized: "\(changes) changes; macOS will ask about \(prompts).")
        }
    }
}
