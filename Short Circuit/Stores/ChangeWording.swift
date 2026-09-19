import Foundation

/// How changes and prompts are counted in words. macOS confirms every setter call, extensions
/// included, but the counts stay separate in case some future call doesn't prompt.
enum ChangeWording {
    /// "macOS will ask you to confirm 2 changes" or "3 changes; macOS will ask about 2".
    static func summary(changes: Int, prompts: Int) -> String {
        switch (changes, prompts) {
        case (0, _):
            return String(localized: "nothing needs changing")
        case let (changes, prompts) where prompts == changes:
            return changes == 1
                ? String(localized: "macOS will ask you to confirm 1 change")
                : String(localized: "macOS will ask you to confirm \(changes) changes")
        case let (changes, prompts):
            return String(localized: "\(changes) changes; macOS will ask about \(prompts)")
        }
    }

    /// The line shown while a call runs, waiting on the macOS prompt.
    static func progressTitle(_ progress: WriteProgress) -> String {
        progress.total == 1
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
        case let (changes, prompts):
            return restoring + " " + String(localized: "\(changes) changes; macOS will ask about \(prompts).")
        }
    }
}
