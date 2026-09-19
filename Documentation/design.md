# Design

What Short Circuit is, how it is put together, and which choices are settled. Read this
before changing the shape of anything; the companion documents are
[launch-services.md](launch-services.md) (what the OS does and why the parser exists),
[write-path.md](write-path.md) (the write contract), and
[catalog-notes.md](catalog-notes.md) (why the catalog groups what it groups).

## The problem

macOS decides what opens a file through Launch Services, which thinks in Uniform Type
Identifiers. People do not. One human format routinely has several identifiers, and
System Settings exposes exactly one of these choices (the default browser).

Markdown is the standing example. Two UTIs claim `.md`, several editors bind the bare
extension with no UTI at all, and sibling extensions (`.markdown`, `.mkd`) can resolve to
generated dynamic types with defaults of their own. Set one of them and some Markdown
files still open in the old app, with nothing on screen to explain why.

## Kinds

A **Kind** is the thing a person means — "Markdown", "Web browser", "JPEG image". It
groups:

- one or more **UTIs** (`public.markdown`, `net.daringfireball.markdown`),
- the **extensions** and **MIME types** those UTIs declare, used for display, search and
  matching,
- zero or more **URL schemes** (`http`/`https` for the browser, `mailto` for email),
- and, where an extension resolves to no declared type, that **extension** as a target of
  its own.

Setting the default app for a Kind sets it for every member that can take it. A Kind whose
members currently point at different apps is **split**, and Short Circuit can fix that in
one reviewed step. That is the feature the tool exists for.

Not every member is worth changing. macOS resolves each extension to exactly one type, so
a member that wins no extension is **shadowed**: nothing opens through it. Whole-Kind
changes target effective members only, and shadowed ones move only if you ask for them
individually. `write-path.md` covers the rules.

### How Kinds are built

Two layers, in this order:

1. **A runtime heuristic**, so the app works on any Mac. Union-find over type declarations
   that share an extension or MIME type, restricted to types some app claims, with names
   from `UTType.localizedDescription`. Formats the catalog has never heard of still get a
   Kind. The heuristic's failure modes, and the specific tags that must never create an
   edge, are in [launch-services.md](launch-services.md#what-the-shared-tag-heuristic-actually-produces).
2. **A curated catalog** (`Short Circuit/Resources/Catalog.json`), which overrides names,
   assigns categories, merges or splits clusters the heuristic got wrong, attaches
   schemes, adds search keywords, and ranks the everyday "Common" list. It is plain JSON
   in the repo so it can be improved by pull request. A broken catalog logs and falls back
   to the heuristic; it is never fatal.

## UI model

A Finder-style browser: a category sidebar, a grid or table of Kinds, one search field,
and an inspector.

- Tiles show the system document icon for the type — which already reflects the current
  default app — badged with the default app's icon.
- **One** search field matches names, extensions (`.md`), MIME types, UTIs and schemes
  (`slack:`).
- **Dropping a file on the window** jumps to its Kind. It is the fastest answer to "why
  does this open in X?", and `File ▸ Show Type of File…` is its keyboard equivalent.
- **Split** lists Kinds whose members disagree, plus a second section for those that
  disagree with no single app able to unify them.
- **Applications** starts from an app instead: pick one, see everything it can open, check
  a set, and apply it as a reviewed batch — never a blind loop, because every change costs
  a system prompt.
- App-specific link types (single-app URL schemes, the bulk of what a real Mac registers)
  are hidden by default; `View ▸ Show App-Specific Link Types` brings them back, and an
  exact scheme search finds one anyway.

Every change goes through the window's `UndoManager`, for the session.

## Architecture

macOS 26.6+, SwiftUI, Swift 6 language mode, `@Observable` models. Not sandboxed (the
sandbox blocks both `lsregister` and the setters), hardened runtime, Developer ID and
notarization. No CLI. The only package dependency is Sparkle, for in-app updates, which
starts in Release builds only.

- **`Services/LaunchServicesIndex`** (an `actor`) runs `lsregister -dump` (~4 s, ~32 MB),
  parses it with `LSDumpParser` into `Models/LSRecords`, and caches the result under
  `~/Library/Caches/`. It serves the cache first and detects staleness through the Launch
  Services sequence number. The parser is deliberately tolerant: the format is
  undocumented, so unknown fields, flags and roles are preserved rather than rejected.
  - *If the dump format ever breaks*, the fallback is scanning app `Info.plist`s
    (`CFBundleDocumentTypes`, `UT*TypeDeclarations`, `CFBundleURLTypes`), which needs no
    private API. It would lose system type declarations.
- **`Services/KindBuilder`** turns a snapshot into Kinds: the heuristic, overlaid by
  `Models/Catalog`.
- **`Services/LiveKindProvider`** enriches Kinds with live `NSWorkspace` reads — current
  handler and candidate apps per member.
- **`Services/HandlerWriter`** plans every write from **live** reads rather than from the
  displayed Kind, runs one setter call at a time, and re-reads after each.
  `HandlerBackend` is the seam: `WorkspaceHandlerBackend` is the only type that calls a
  real setter; `SimulatedHandlerBackend` and `RefusingHandlerWriter` cover tests,
  previews and automated app runs.
- **`Stores/KindStore`** is the observable state the views render; **`Stores/AppIndex`**
  backs the Applications view.
- **`Models/Kind.swift`** is the contract between the data layer and the UI. Change it
  deliberately, and follow the isolation note in its header.

Candidate apps show name and icon; the version, or the containing folder, appears only
when the same bundle identifier is installed more than once. "Other…" is always available.

## Settled decisions

These are decided. Reopen them only with a reason, not by drift.

1. **Minimum macOS 26.** The consent model and the APIs below it differ too much earlier.
2. **No per-role (Viewer / Editor / Shell) handlers.** The public API sets the "all" role;
   matching the old tool would mean keeping deprecated C functions that (measured) do not
   work on 26.6 anyway.
3. **No "Do nothing" handler.** It required shipping a dummy app.
4. **No CLI.**
5. **No app-level confirmation dialog.** macOS already confirms every change, so a second
   dialog only doubled the questions — and the one that existed had a SwiftUI ordering bug
   that made Continue apply nothing. Progress is shown inline instead
   ("Waiting for macOS… change 1 of 2").
6. **No automatic fallback when a setter fails.** Every retry route that was tried changed
   a type the user had not approved. Failures are reported.
7. **No Settings window.** Every candidate preference (sidebar section, layout, sort,
   inspector visibility, window frame) is already remembered as view state, so a Settings
   scene would be empty. Add one when a real preference exists — Sparkle's automatic-check
   toggle is the likely first.
8. **No document-type declarations.** Accepting files dropped on the Dock icon, or a
   Services entry, needs `CFBundleDocumentTypes` / `NSServices`, which would list Short
   Circuit in every "Open With" menu on the system. Not worth it for a utility that never
   opens documents.
9. **No private SPI**, no `@_silgen_name`, no direct writes to
   `com.apple.launchservices.secure.plist`.
10. **Never call a setter during development.** Each one raises a system consent prompt on
    a machine nobody is sitting at. Tests and automated runs use the simulated or refusing
    backend; only a person at the Mac exercises the live write path.

## Known gaps

Current, as far as anyone has checked. Fixed findings are not listed.

**Behaviour**

- The browser is single-select. Multi-select would suit "make this app the default for
  these six types", which the Applications view does instead.
- Nothing can be pasted into the window; a pasted path, `.md` or UTI could jump to a Kind,
  the counterpart of dropping a file.
- App icons are not drag sources (Kinds, table rows and extension chips are).
- Pressing Space again while the inspector is still animating closed does not reopen it —
  SwiftUI reverts the change.
- `Localizable.xcstrings` exists but stays empty until an Xcode IDE build syncs it;
  `xcodebuild` extracts strings without writing the catalog. English only.
- No Homebrew cask.

**Not yet verified by a person**

The write path can only be finished by hand, since every call needs a human answer.

- Declining a prompt mid-batch: Stop during the first prompt of a longer Applications
  batch should leave nothing else prompting.
- Right-click selecting the tile, list row or Applications row under the pointer.
- Undo of every kind, and extension rows (`.markdown files`) now that they prompt.
- Tab order through the window; whether closing the last window quits and whether the
  frame is restored on relaunch; ⌘C against the key window; VoiceOver reading tiles,
  menus and failure banners.
- Whether a *refusal* can ever take longer than the 500 ms threshold that separates it
  from a declined prompt (see [launch-services.md](launch-services.md#error-256-means-two-different-things)).

## Deliberately out of scope

- **Removing an app from Finder's "Open With" list.** No public API and no durable
  workaround exists; see [launch-services.md](launch-services.md#what-the-modern-api-drops).
  Worth revisiting only if Apple adds one.
- **The Mac App Store.** The sandbox blocks the entire feature set.
- **Shortcuts / App Intents** ("get the default app for a type"). A good fit for a
  power-user utility, but it follows the no-CLI decision — post-1.0 at the earliest.
