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

932 types, 56 in Common, 4 fixable splits (Web browser via XHTML, SQL source, Tab-separated table, MIME HTML), 202 apps. 201 unit tests pass; no build warnings. First load from cache under a second; a full `lsregister -dump` takes about 6 seconds. A stale cache is detected through the Launch Services sequence number (about 30 ms to read).

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

## Waiting on you

- `swift Documentation/spikes/extension-spike.swift`: measures what `setDefaultApplication(at:toOpenFileAt:)` does for `.markdown`, which opens in Claude on this Mac and which no settable type governs (27 types have such extensions). Two macOS prompts; it restores the original.

## Hand tests still owed

1. A two-prompt change: Web browser → another browser while XHTML differs. Expect "change 1 of 2", then "2 of 2".
2. MIME HTML → Google Chrome. Expect one prompt and a neutral "Google Chrome can't open this type" on Word's type.
3. Applications: check 2–3 harmless types; does the footer's prompt count match? Press Stop during the first prompt of a longer batch; nothing further should prompt.
4. "Other…", declining a macOS prompt, and a real drag from Finder.
5. After the Mac pass lands: its manual QA list (menus, Tab order, VoiceOver, window restore, Undo).

## Not started

Sparkle updates (needs the package and updater code), a Homebrew cask, by-extension defaults (waiting on the spike), localization beyond English.
