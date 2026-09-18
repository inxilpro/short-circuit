# Short Circuit — Initial Plan (proposal)

## What I checked on this Mac

`lsregister -dump` on this machine takes about 4 seconds and prints about 390k lines (32 MB). It contains:

| Record | Count | Notes |
|---|---|---|
| `type` | ~5,970 | Type declarations, which reduce to **2,746 unique UTIs** |
| `claim` | ~3,900 | App ↔ UTI, extension, or scheme bindings with role and rank |
| `bundle` | ~1,300 | Apps, plus other bundles |
| `handlerpref` | 120 | **Your saved overrides** (for example `iterm2 → com.googlecode.iterm2`) |
| URL schemes claimed | ~390 | |

Markdown shows why a unified view is worth building. Two UTIs, `public.markdown` and
`net.daringfireball.markdown`, both claim `.md`. Six or more apps declare one or both of them, and some
apps (text editors) bind the bare `.md` extension without any UTI. If you set only one UTI, `.md` files
can still open in the "wrong" app. A tool that works UTI by UTI can't show you this; a unified view can.

## Core idea: "Kinds"

A **Kind** is the thing a human means ("Markdown", "Web page", "Email", "JPEG image"). Under the hood
it's a group of:

- one or more **UTIs** (`public.markdown`, `net.daringfireball.markdown`)
- **extensions** and **MIME types** (`.md`, `text/markdown`), used for display, search, and matching
- zero or more **URL schemes** (`http`, `https` for Web page; `mailto` for Email)

Setting the default app for a Kind sets it for **every member** UTI and scheme. The app flags a Kind as
**split** when its members currently point to different apps. That's the Markdown problem, and it's a
feature SwiftDefaultApps doesn't have.

Some Kinds cover links as well as files. For example, "Web page" = `http` + `https` + `public.html` + `public.xhtml`.
macOS already locks http, https, and html together as the browser role.

## How Kinds get built (two layers)

1. **Runtime heuristic (works on any Mac).** Union-find over UTI declarations that share an extension or
   MIME tag, limited to types that at least one app claims. Descriptions come from
   `UTType(identifier:).localizedDescription`. With this layer alone, Kinds exist even for apps the
   catalog has never heard of.
2. **Bundled curated catalog (`Catalog.json`).** This layer overrides names, sets categories (Documents,
   Images, Audio, Video, Code, Archives, Web & Links, Communication, Developer…), merges or splits
   clusters, attaches schemes to Kinds, and adds search keywords.
   - I'll build it the way you described. A debug-menu **"Export LS snapshot"** writes a JSON file of every
     claimed UTI, scheme, tag, conformance, and claiming app. Subagents then classify it into Kinds. The
     first version is seeded from your Mac, then generalized so nothing in it is specific to your apps.
   - It's plain JSON in the repo, so other people can add to it through PRs once the app is public.

## UI: Finder-style browser

```
┌──────────────┬─────────────────────────────────────────┬──────────────────────┐
│ ⚠ Split (4)   │  🔍 markdown | .md | text/x | slack:     │ Markdown             │
│ ★ Common      │                                          │ [doc icon]           │
│ Documents     │  [📄]      [📄]      [🖼]      [🌐]      │ Opens with:          │
│ Images        │ Markdown   PDF     JPEG    Web page     │ [▾ Typora         ]  │
│ Audio / Video │  ·Typora   ·Preview ·Preview ·Safari     │   Mud · Xcode · …    │
│ Code          │                                          │   Other…             │
│ Archives      │  [📄]      [📄]     ...                  │ ─ Members ─────────  │
│ Web & Links   │                                          │ public.markdown  → T │
│ Communication │                                          │ net.daring…      → X │⚠
│ All types     │                                          │ .md .markdown .mkd   │
│ ──────────    │                                          │ text/markdown        │
│ Applications  │                                          │ [Fix split]          │
└──────────────┴─────────────────────────────────────────┴──────────────────────┘
```

- **Grid of Kinds.** Each tile shows the system document icon from `NSWorkspace.icon(for: UTType)`,
  which already reflects the current default app, plus a small badge with the default app's icon.
  A toggle switches to a list/table view.
- **One search field** matches names, extensions (`.md`), MIME types, UTIs, and schemes (`slack:`).
- **Drag any file onto the window** to go straight to its Kind. That's the fastest way to answer "why
  does this open in X?"
- **Default filter:** Kinds with at least two candidate apps. A type only one app can open usually isn't
  worth showing. An "All types" view is still there for completeness.
- **Applications section:** pick an app, see everything it can open, and "Make default for…" with a
  checklist you review before applying. Because macOS 26.4 prompts on each change, this is a reviewed
  batch, not a blind loop.

## Architecture

- **Target:** standalone SwiftUI app, Swift 6 language mode, `@Observable` models.
  - **Turn off App Sandbox.** The project currently has `ENABLE_APP_SANDBOX = YES`, and the sandbox
    blocks both `lsregister` and the setters.
  - Keep the hardened runtime. Distribute with Developer ID + notarization (GitHub Releases, and a
    Homebrew cask later).
- **`LaunchServicesIndex`** (actor):
  - Runs `lsregister -dump` in the background and parses it with a tolerant, line-oriented parser into
    `TypeDecl`, `Claim`, `Bundle`, and `HandlerPref`.
  - Caches the result on disk and refreshes it on launch and on demand.
  - Unit tests run against trimmed fixture dumps.
  - Fallback if the dump format breaks: scan app `Info.plist`s (`CFBundleDocumentTypes`,
    `UT*TypeDeclarations`, `CFBundleURLTypes`), which only uses public APIs.
- **`HandlerService`**. Reads use `urlForApplication(toOpenContentType:)`,
  `urlsForApplications(toOpen:)`, and probe URLs for schemes. Writes use
  `setDefaultApplication(at:toOpen:)` and `…toOpenURLsWithScheme:`. After each write, it re-reads with a
  delay, because the call returns before the user answers the consent prompt.
- **`KindCatalog`**: merges the heuristic clusters with `Catalog.json`, then computes split status and
  candidate apps.
- **Candidate apps:** show name and icon. Show the version and path only when the same bundle ID exists
  more than once (for example `/Applications` vs `~/Applications` vs a DerivedData build). Always offer an
  "Other…" app picker.

## Milestones

0. **Spikes on macOS 26.x (half a day):**
   - Does setting a Kind with 3 UTIs trigger 3 consent prompts or 1?
   - Does the deprecated `LSSetDefaultRoleHandlerForContentType` prompt too?
   - Does the error-256 bug in `setDefaultApplication(at:toOpen:)` reproduce?
   - Can `setDefaultApplication(at:toOpenFileAt:)` serve as a fallback?

   These answers shape the write UX, so they come first.
1. **Data layer:** dump parser, models, cache, and tests.
2. **Read-only browser:** grid, search, inspector, split detection, drag-a-file. This is useful on its
   own.
3. **Write path:** per-Kind and per-member setting, consent-aware UX, and re-verify after writes.
4. **Catalog:** snapshot export, subagent classification, a reviewed `Catalog.json`, and catalog merge
   logic.
5. **Applications view + polish:** batch "make default", undo (restore the previous handler for each
   member), and a menu-bar-free Settings window.
6. **Distribution:** signing, notarization, README, and a release workflow.

## Decisions

- Minimum macOS 26.
- No per-role (Viewer/Editor) handlers.
- No "Do nothing" handler in v1.
- No CLI in v1.

## Future scope

- **Removing an app from Finder's "Open With" list for a type.** There is no public API for this. macOS
  builds the list from each app's signed `Info.plist`. Unregistering with `lsregister -u` affects every
  type and doesn't last, and editing `Info.plist` breaks the code signature. Worth revisiting if Apple adds
  an API, or if a safe, durable Launch Services mechanism turns up.
