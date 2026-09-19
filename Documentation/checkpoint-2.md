# Checkpoint 2

Date: 2026-09-18, evening. Branch: `main`. macOS 26.6.2, Xcode 27.0. Replaces `checkpoint-1.md`, which is kept for history.

The app's set actions are real. macOS asks you to confirm every change; the app has no dialog of its own.

## What changed since checkpoint 1, and why

Everything here came from your hands-on session or from a review.

| Finding | Source | What the app does now |
|---|---|---|
| Continue in the app's dialog cancelled its own change | Your Web browser test | Dialog removed entirely; changes apply directly with inline progress ("Waiting for macOS… change 1 of 2") |
| `public.xhtml` doesn't follow the default browser | Your Chrome ⇄ Arc test | Browser role is `http` + `https` + `public.html`; XHTML is an ordinary type |
| `public.markdown` fails with 256, no prompt | Your Markdown test + probe | The type has no supertypes; macOS won't assign it. Marked unsettable, dimmed, never set |
| `com.microsoft.word.mhtml` → Chrome fails with 256 | Your MHTML test + probe | macOS only accepts apps it lists for that exact type. Each type carries its own candidates; others are skipped with a neutral note |
| Splits caused by types no file uses | Your question about strict `.docx` | A split counts only among types that win an extension, and only if one app could unify them. Each type shows the extensions it governs |
| Fixed items vanished from Split | You | Split list is fixed per session; fixed items show a green check until ⌘R |
| Word icon on Markdown | You | Icon comes from the type that the extension resolves to |
| "Common" was 381 alphabetical entries | You | Curated `Catalog.json`: 146 types, 60 ranked, 56 present on this Mac |
| Browser role ignored per-type candidates (ChatGPT, Sublime Text) | Codex review 2, R1 | Eligibility follows the `http` call actually made; one result per target |
| Whole-type change could still write shadowed types | Codex review 2, R2 | No fallback when every type is known to be non-preferred |
| `/Applications/Safari.app` not recognized | Codex review 2, R3 | App paths compare by resolved location |

## Current numbers on this Mac

932 types (617 shown by default), 56 in Common, 5 fixable splits (Markdown, Web browser via XHTML, SQL source, Tab-separated table, MIME HTML), 202 apps (129 shown). 242 unit tests pass; no build warnings. First load from cache under a second; a full `lsregister -dump` takes about 6 seconds. A stale cache is detected through the Launch Services sequence number (about 30 ms to read).

## New since checkpoint 1

- **Applications view**: pick an app; see Default for / Partly default / Can open / Also offered by macOS; check types; the footer counts the macOS prompts to expect; Apply runs them one at a time; Stop ends the batch after the current prompt.
- **Catalog** (`Short Circuit/Resources/Catalog.json`, notes in `Documentation/catalog-notes.md`) and a DEBUG menu item that exports a Launch Services snapshot for catalog authors.
- **Release structure** mirrored from Chronicle: CI, tag-driven release with notarization, `Documentation/RELEASING.md`, `README.md`, `CLAUDE.md`. Nothing has been pushed; the repo has no remote. Secrets and first-release steps are in `RELEASING.md`. The `runs-on: xcode-27` runner label is unverified.
- **Reviews**: `Documentation/reviews/codex-review-1.md` (with re-review), `codex-review-2.md`, `mac-assed-review-1.md`.

## Mac-conventions pass (done, bb6d2fc)

Implemented from `Documentation/reviews/mac-assed-review-1.md`, which now has a Status column per finding:

- Keyboard: the grid takes focus, arrow keys, Return, Space and type-to-select; selection scrolls into view, including after a file drop.
- Menus: View ▸ as Icons ⌘1 / as List ⌘2, Show Inspector, Go To ▸ Split / Common / All Types / Applications (⌥⌘1–4); a Type menu with Open With ▸, Fix Split, Copy Identifiers, Copy Extensions, Show App in Finder; File ▸ Show Type of File… ⌘O; Help links. Context menus offer the same actions.
- Copy and drag out for types and extension chips.
- **Undo**: every change registers with the window's UndoManager and restores through the same writer, so macOS prompts again. Batches undo as one group and stop at the first declined prompt. Session only.
- Remembered state: layout, sidebar section, inspector, table sort and columns, window frame.
- Accessibility labels and announcements; failure messages stay until dismissed.
- "Other…" is a sheet; an app dropped on Opens With sets it.
- Applications view uses tables (Type / Opens With / Extensions / Status), which also ended AppKit's reentrancy warning in the agent's runs.
- Strings moved to a String Catalog; "Kind" and "member" no longer appear in the UI.
- No Settings window, on purpose: every candidate preference is already covered by remembered state.

201 unit tests pass. **No screenshots of this pass were reviewed**: the screen was locked while the agent ran, so its captures came out blank. Its manual QA list is at the end of the review file.

## Codex review 3 (of the Mac-conventions pass)

`Documentation/reviews/codex-review-3.md`. Two serious bugs, both fixed with tests: "Other…" did nothing after a pick (the sheet's target was cleared on dismissal, the same trap as the old dialog), and Undo could overwrite a change made after the one being undone. Undo now re-reads each type first, passes the normal eligibility checks, keeps its entry while the app is busy, and says what a browser undo cannot restore when http, https and HTML weren't on one app before. Codex confirmed that menus, context menus, app drops and batches all pass the single-write gate, and that live snapshot mode cannot write or undo. 211 unit tests pass.

Not done, held for a decision: opening files dropped on the Dock icon and a Services entry. Both need document-type declarations, which could list Short Circuit in every "Open With" menu.

## Since the Mac-conventions pass

- **By-extension defaults** (40ea8b7). Your spike showed `setDefaultApplication(at:toOpenFileAt:)` changes only the one extension when it resolves to a generated `dyn.` type, reverses cleanly, and shows **no macOS prompt**. Such extensions are now rows of their own (".markdown files → Claude"). The writer refuses if the extension resolves to a declared type. Prompt counts leave these out ("3 changes; macOS will ask about 2"), and they only change through an explicit action. Markdown is split again on this Mac: `.md` → Sublime Text, `.markdown` → Claude, `.mdown` and `.mkd` → Cursor; only Cursor is listed for all four.
- **Sparkle** (f7c6ff3), mirroring Chronicle: Check for Updates… after About, signed appcast in the release workflow, Sparkle's helpers re-signed. Automatic checks are off until there is a setting; Sparkle asks on the second launch. It reuses Chronicle's update key. No Release build has been run.
- **App-specific link types hidden by default** (your decision): All Types shows 617 of 932 types and Applications 129 of 202 apps. View ▸ Show App-Specific Link Types brings them back; an exact scheme search still finds one.
- **Skipped by your decision**: opening files dropped on the Dock icon and a Services entry, because the document-type declarations they need could list Short Circuit in every "Open With" menu.

242 unit tests pass. With the screen unlocked I looked at the live All Types list, the Markdown inspector with its extension rows, and the Applications table; they render as intended. Undo, keyboard focus, menus and context menus still have not been seen by anyone.

## Hand tests still owed

1. A two-prompt change: Web browser → another browser while XHTML differs. Expect "change 1 of 2", then "2 of 2".
2. MIME HTML → Google Chrome. Expect one prompt and a neutral "Google Chrome can't open this type" on Word's type.
3. Applications: check 2–3 harmless types; does the footer's prompt count match? Press Stop during the first prompt of a longer batch; nothing further should prompt.
4. "Other…", declining a macOS prompt, and a real drag from Finder.
5. After the Mac pass lands: its manual QA list (menus, Tab order, VoiceOver, window restore, Undo).

## Not started

A Homebrew cask, localization beyond English, a first push and release (needs you: repo, secrets, and a working runner label).
