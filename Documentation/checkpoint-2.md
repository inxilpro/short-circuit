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

932 types, 56 in Common, 4 fixable splits (Web browser via XHTML, SQL source, Tab-separated table, MIME HTML), 202 apps. 176 unit tests pass; no build warnings. First load from cache under a second; a full `lsregister -dump` takes about 6 seconds. A stale cache is detected through the Launch Services sequence number (about 30 ms to read).

## New since checkpoint 1

- **Applications view**: pick an app; see Default for / Partly default / Can open / Also offered by macOS; check types; the footer counts the macOS prompts to expect; Apply runs them one at a time; Stop ends the batch after the current prompt.
- **Catalog** (`Short Circuit/Resources/Catalog.json`, notes in `Documentation/catalog-notes.md`) and a DEBUG menu item that exports a Launch Services snapshot for catalog authors.
- **Release structure** mirrored from Chronicle: CI, tag-driven release with notarization, `Documentation/RELEASING.md`, `README.md`, `CLAUDE.md`. Nothing has been pushed; the repo has no remote. Secrets and first-release steps are in `RELEASING.md`. The `runs-on: xcode-27` runner label is unverified.
- **Reviews**: `Documentation/reviews/codex-review-1.md` (with re-review), `codex-review-2.md`, `mac-assed-review-1.md`.

## In progress

- The Mac-conventions pass: keyboard navigation in the grid, menus, context menus, copy and drag out, **Undo**, state restoration, accessibility, sheet-style "Other…", wording, Applications view polish, and handling the 16 types that have no whole-type target. Status will be recorded in `mac-assed-review-1.md`.
- `Documentation/spikes/extension-spike.swift`: a script for you to run, to measure what `setDefaultApplication(at:toOpenFileAt:)` does for `.markdown`, which no settable type governs here (27 types have such extensions).

## Hand tests still owed

1. A two-prompt change: Web browser → another browser while XHTML differs. Expect "change 1 of 2", then "2 of 2".
2. MIME HTML → Google Chrome. Expect one prompt and a neutral "Google Chrome can't open this type" on Word's type.
3. Applications: check 2–3 harmless types; does the footer's prompt count match? Press Stop during the first prompt of a longer batch; nothing further should prompt.
4. "Other…", declining a macOS prompt, and a real drag from Finder.
5. After the Mac pass lands: its manual QA list (menus, Tab order, VoiceOver, window restore, Undo).

## Not started

Sparkle updates (needs the package and updater code), a Homebrew cask, by-extension defaults (waiting on the spike), localization beyond English.
