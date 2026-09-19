# Short Circuit

**[⬇ Download the latest release](https://github.com/inxilpro/short-circuit/releases/latest)**
(macOS 26.6 or later)

Short Circuit is a native Mac app for choosing which app opens what. It shows
every file type and link type your Mac knows about, which app currently opens
each one, and which other apps could — and lets you change it.

It works in **Kinds**, not raw type identifiers. A Kind is what a person means
("Markdown", "Web browser", "JPEG image"); underneath, it groups every Uniform
Type Identifier, extension, MIME type, and URL scheme that belongs to that
format. Setting the default app for a Kind sets it for every member.

That matters because one format often has several identifiers. `.md` files are
claimed through both `public.markdown` and `net.daringfireball.markdown`, and
some editors bind the bare extension. Change only one and some Markdown files
still open in the old app. Short Circuit flags these Kinds as **split** and
fixes them in one step.

<!-- Screenshots: grid view, inspector with a split Kind, Applications view. -->

## Using it

- **Browse** Kinds by category, or search by name, extension (`.md`), MIME type,
  UTI, or scheme (`slack:`).
- **Drop any file** on the window to jump to its Kind — the quickest answer to
  "why does this open in X?"
- **Split** lists Kinds whose members point at different apps.
- **Applications** starts from an app instead: pick one, see everything it can
  open, and make it the default for a reviewed set of Kinds.

macOS asks you to confirm every default-app change. Changing a Kind with three
members means three system prompts; Short Circuit shows which change each
prompt is for. Nothing changes without your confirmation.

Short Circuit only reads Launch Services data (`lsregister -dump` plus
`NSWorkspace` lookups) and only writes through Apple's public default-handler
APIs. It is not sandboxed — the sandbox blocks both. It has no analytics or
background process, and its only network access is checking GitHub for updates,
which it asks your permission for first.

## Install

Download the DMG from the [latest release](https://github.com/inxilpro/short-circuit/releases/latest)
and drag Short Circuit to Applications. It is signed with a Developer ID and
notarized by Apple.

Short Circuit updates itself with [Sparkle](https://sparkle-project.org). On
its second launch it asks whether to check for updates automatically; either
way, **Short Circuit → Check for Updates…** checks on demand. Updates are
downloaded from this repository's GitHub releases and verified against a
signing key built into the app.

## How Kinds are built

Two layers:

1. **A runtime heuristic** that works on any Mac. Type declarations that share
   an extension or MIME type are clustered, limited to types at least one app
   claims. Apps the catalog has never heard of still get Kinds.
2. **A curated catalog**, [`Short Circuit/Resources/Catalog.json`](Short%20Circuit/Resources/Catalog.json),
   bundled with the app. It names Kinds, assigns categories, says which UTIs
   are really one format and which only look alike, attaches URL schemes, adds
   search keywords, and ranks the **Common** list.

The catalog is plain JSON so anyone can improve it.

### Contributing to `Catalog.json`

Each entry looks like this:

```json
{
  "id": "markdown",
  "name": "Markdown",
  "category": "documents",
  "utis": ["net.daringfireball.markdown"],
  "extensions": ["md", "markdown"],
  "schemes": [],
  "keywords": ["readme", "md"],
  "common": 12
}
```

- `id` is stable and unique. Don't rename existing IDs.
- `category` is one of `documents`, `images`, `audio`, `video`, `code`,
  `archives`, `web`, `communication`, `developer`, `other`.
- `utis` lists identifiers that are **the same format**. Each UTI belongs to at
  most one entry. Only add an identifier you have seen declared in a real
  Launch Services dump; never guess a `public.*` spelling.
- `extensions` (with or without the dot) and `schemes` (with or without the
  colon) are matched case-insensitively.
- `common` is an optional rank; lower sorts first. Leave it out unless the
  format belongs in the short everyday list.
- An entry that matches nothing on a given Mac produces no Kind, so it's fine
  to add formats you don't have apps for.

To gather evidence, run a Debug build and choose **Debug → Export Launch
Services Snapshot…**. It writes every claimed type, scheme, tag, conformance,
and claiming app as JSON. Include the relevant excerpt in your pull request,
and explain why grouped identifiers are the same format.
[`Documentation/catalog-notes.md`](Documentation/catalog-notes.md) records the
reasoning behind the current entries, including identifiers that were
deliberately left out.

Before opening a pull request, run the unit tests (below). `CatalogTests`
checks the bundled catalog: valid categories, unique IDs, and no UTI or scheme
owned by two entries.

## Development

Open `Short Circuit.xcodeproj` in Xcode 27 or later. It's a single SwiftUI app
target (Swift 6, macOS 26.6+) with unit tests in `Short CircuitTests` using
swift-testing.

```sh
xcodebuild build -project "Short Circuit.xcodeproj" -scheme "Short Circuit" \
  -destination 'platform=macOS'

xcodebuild test -project "Short Circuit.xcodeproj" -scheme "Short Circuit" \
  -destination 'platform=macOS' -only-testing:"Short CircuitTests"
```

The unit tests never change your default apps. CI
(`.github/workflows/ci.yml`) runs an unsigned Release build and the unit
tests; releases are cut by tag.

## Documentation

- [Documentation/design.md](Documentation/design.md) — what the app is, how it's built, and its settled decisions
- [Documentation/launch-services.md](Documentation/launch-services.md) — the APIs, the dump format, and what macOS 26.6 actually does
- [Documentation/write-path.md](Documentation/write-path.md) — how default-app changes are made and verified
- [Documentation/catalog-notes.md](Documentation/catalog-notes.md) — why the catalog groups what it groups
- [Documentation/RELEASING.md](Documentation/RELEASING.md) — signing, notarization, and release steps
