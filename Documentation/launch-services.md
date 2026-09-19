# Launch Services: what the APIs give you, and what this Mac actually does

Background for anyone working on the data or write path. Two kinds of knowledge are
mixed here on purpose: what Apple documents, and what was measured on macOS 26.6.2
(25G83) while building Short Circuit. Measured behaviour is marked as such, because it
is the part that no documentation covers.

## 1. Why the app parses `lsregister -dump`

Everything Short Circuit *reads about one type* has a public API. What has no public
API is the list of types in the first place.

- `UTType.types(tag:tagClass:conformingTo:)` is a reverse lookup: you must already know
  the extension or MIME type, and it invents a dynamic type when nothing matches. There
  is no way to ask the system "what types are declared here?"
- The same is true of URL schemes and of installed applications.
- SwiftDefaultApps, the tool this replaces, solved that with three private symbols bound
  through `@_silgen_name` (`_UTCopyDeclaredTypeIdentifiers`, `_LSCopySchemesAndHandlerURLs`,
  `_LSCopyAllApplicationURLs`). Apple can remove those at any update; the project rule is
  that no private SPI is used.

That leaves `lsregister -dump`, which prints the whole Launch Services database as text:

```
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/\
LaunchServices.framework/Versions/A/Support/lsregister -dump
```

It is undocumented and has no man page, so section 3 records the format precisely enough
to write a tolerant parser against. Never run `lsregister` with any other flag: the
registration flags (`-f`, `-u`, `-kill`) rewrite the user's database.

## 2. The API surface

### Reading

| Task | API | Notes |
|---|---|---|
| Default app for a type | `NSWorkspace.urlForApplication(toOpenContentType:)` | No role granularity |
| All apps for a type | `NSWorkspace.urlsForApplications(toOpen:)` | This is the list macOS will accept in a setter (see §4) |
| Default app for a scheme | `NSWorkspace.urlForApplication(toOpen: probeURL)` | Build a probe URL such as `mailto:a@b` |
| Type metadata | `UTType` (`.localizedDescription`, `.preferredFilenameExtension`, `.preferredMIMEType`, `.supertypes`) | macOS 11+ |

### Writing

| Task | API |
|---|---|
| Content type | `NSWorkspace.setDefaultApplication(at:toOpen:)` |
| URL scheme | `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` |
| One file | `NSWorkspace.setDefaultApplication(at:toOpenFileAt:)` — **not used**, see §4 |

The deprecated Launch Services C functions (`LSSetDefaultRoleHandlerForContentType`,
`LSSetDefaultHandlerForURLScheme`, `LSCopy*`) still compile and still exist on 26.6, and
Apple's own advice has been to keep using them until a replacement lands. Measured here,
they are useless: `LSSetDefaultRoleHandlerForContentType` returned `paramErr` (-50) for
one type and `noErr` (0) for another **while changing nothing and never prompting**. They
are not a fallback for anything, and the app calls none of them.

### What the modern API drops

- **Roles.** `LSRolesMask` distinguished Viewer / Editor / Shell. `NSWorkspace` sets and
  reads the "all" role only. Short Circuit has no per-role UI (a settled decision), so
  this costs nothing here.
- **A "do nothing" handler.** The old tool shipped a dummy app for this. Not supported.
- **Removing an app from Finder's Open With list.** No public API, and no supported
  workaround: the list is built from each app's signed `Info.plist`, `lsregister -u`
  is system-wide and doesn't last, and editing `Info.plist` breaks the signature.

### Sandboxing

A sandboxed app cannot set default handlers at all, and the sandbox also blocks
`lsregister`. Short Circuit is therefore non-sandboxed, Developer ID signed, hardened
runtime, notarized, and can never ship on the Mac App Store. Writing
`com.apple.launchservices.secure.plist` directly is not a supported path either;
Launch Services validates and overwrites it.

## 3. The dump format

Measured against one 32 MB capture of macOS 26.6.2 (390,411 lines, about 4.4 s to
produce). Counts below describe that snapshot and will differ on every Mac; the
*structure* is what to rely on, and even that is undocumented and may change.

### Physical layout

- A database/status/memory preamble occupies the first ~63 lines, ending at a line of
  exactly 80 ASCII hyphens.
- Every record header starts at column zero as `<kind> id:`. Dictionary records start
  with `values:` and have no ID.
- Fields are `key:` at column zero, values aligned around column 29. **Split on the first
  colon only** — values contain URLs and schemes.
- Blank lines and braces do not delimit records; only a new column-zero header does. The
  final record must be flushed at EOF.
- Encoding is valid UTF-8 but not ASCII: localized values contain non-Latin text,
  directional marks and non-breaking spaces. Two real claim identifiers contain U+200B
  zero-width spaces (`com.adobe.postscript-lwfn​-font`, `com.netscape.javascript-​source`).
  Do not normalize them away.

### Record kinds

`bundle`, `type`, `claim`, `service`, `container`, `plugin`, `extensionpoint`,
`handlerpref`, and anonymous `values` dictionaries. Short Circuit parses `bundle`, `type`,
`claim`, and `handlerpref` and ignores the rest.

Records are **printed twice**: interleaved with their owning bundle, and again in global
runs at the end. Repeated IDs have identical bodies, so deduplicating by record ID is
safe. The preamble's unit counts match *distinct* records, not printed occurrences.

Fields observed per kind (top-level only; indented plist blobs are not promoted):

- **bundle**: `bundle id`, `path`, `name`, `identifier`, `canonical id`, `version`,
  `versionString`, `teamID`, `class`, `claimed UTIs`, `claimed schemes`, `flags`,
  `sequenceNum`, plus ~60 more.
- **type**: `type id`, `bundle` *or* `plugin`, `uti`, `localizedDescription`, `flags`,
  `conforms to`, `tags`, `iconFiles`.
- **claim**: `claim id`, `localizedNames`, `rank`, `bundle`, `flags`, `roles`, `bindings`.
- **handlerpref**: `handlerpref id`, `unknown`, `all roles`, `mod date`, `extension`.

```text
type id:                    com.autodesk.forge.f3d (0x6ef0)
bundle:                     Fusion (0x2980)
uti:                        com.autodesk.forge.f3d
flags:                      inactive  rel-icon-path  exported  untrusted (0000000000000018)
conforms to:                public.data, public.content
tags:                       .f3d

claim id:                   Fusion 3D Design (0x44e0)
rank:                       Owner
bundle:                     Fusion (0x2980)
roles:                      Viewer (0000000000000002)
bindings:                   com.autodesk.forge.f3d, .f3d
```

### Traps a parser must survive

Each of these was hit in the real capture:

1. **Ownership is a reference, not proximity.** `claim.bundle: Fusion (0x2980)` joins on
   the trailing numeric ID to `bundle id: … (0x2980)`, and global claim runs have no
   preceding bundle at all. Numeric IDs are local to their record table — do not build
   one cross-table ID map. Some `type` records are owned by `plugin:` rather than `bundle:`.
2. **Lists are comma-*space* separated.** `tags: .md, .markdown, text/markdown`. Splitting
   on every comma corrupts device models (`iPhone12,1`). Legacy OSTypes are quoted
   (`'TEXT'`, `'****'`) and can contain spaces. Multi-part extensions (`.css.erb`) are one
   token. `.*` and `'****'` are wildcards, not types.
3. **Tag class is implicit.** Leading dot = extension; unquoted token containing a slash =
   MIME; trailing colon = scheme; quoted = OSType. Everything else may be a device model
   or pasteboard name. Bundle `claimed UTIs` may print annotations that are not part of
   the identifier: `dyn.ah62d4qmuhk2x43dts71g255bqu (.download)`.
4. **Flags and roles are whitespace-separated plus a bare hex mask** —
   `flags: active  exported  core  trusted (0000000000000075)` — not comma lists. Keep the
   mask for future values. `inactive` must not match a substring test for `active`.
5. **Indented plist blobs are large and are not XML.** `infoDictionary`, `entitlements`,
   `icons`, `Intents`, `SDKData` introduce multi-line `{ … }` / `( … )` bodies that
   themselves mention UTIs and schemes. Matching text indiscriminately double-counts them.
   Do not trim indentation before deciding whether a line is a top-level field.
6. **Missing, empty and repeated fields are normal.** Claims with no `bindings:`; claims
   whose display name is empty, so the header value begins with `(`; bundles that repeat
   a key (a dictionary that overwrites duplicates loses data); the diagnostic line
   `Bundle node not found on disk:`.
7. **One UTI, several declarations.** Distinct `type id`s can declare the same `uti:`
   (3,100 declarations for 2,746 identifiers in the capture). Keep provenance and union
   the tags into a set rather than treating the second one as a duplicate.
8. **The same bundle identifier appears at several paths** (118 identifiers repeated in
   the capture: `/Applications`, `~/Applications`, DerivedData copies, Trash). Record ID
   and path are what distinguish installations — this is why the UI shows a version or
   folder when two candidates share a name.

### `handlerpref`: the field label is not the category

The 120 preference records carry 107 `unknown:` fields, 12 `extension:` fields, and one
with neither. Of the `unknown:` values, those with a trailing type-record reference are
content types (including `com.apple.default-app.web-browser` and
`…mail-client`); the bare strings are schemes. That scheme reading is an *inference*, not
a label — 18 of them match no current scheme claim and are probably stale. A dotted name
can still be a scheme, so do not classify by the presence of dots (`doc` is a scheme here;
`cs` is explicitly an extension). Keep the raw category and value, and keep inferred
classification distinct from verified current claims.

### Two views of "which apps claim this type"

A claim's explicit `bindings:` and a bundle's `claimed UTIs` summary do **not** agree, and
neither is a superset in practice. In the capture, six schemes appeared in bindings but
not in any summary, while the summaries contained resolved identifiers that no explicit
binding mentioned. Parse and preserve both. Also: declaring a UTI is not claiming to open
it — apps declare types they merely understand.

### Markdown, the motivating case

Two declared UTIs carry a `.md` tag, from five separate declarations:

| UTI | Declared by | Tags |
|---|---|---|
| `net.daringfireball.markdown` | four apps, variously | `.md, .markdown, .mkd, .mdown, .text, text/markdown, text/x-markdown, text/plain` |
| `public.markdown` | Microsoft Word's imported declaration | `.md, .markdown` |

Explicit claimants differ from both lists again, and three more editors bind the bare
`.md` extension with no UTI in the claim at all. So seven apps have a stake in `.md`,
reachable only by combining declarations, explicit claims, bundle summaries, and bare
extension bindings. Listing any one of those views misses part of the picture — which is
the whole argument for grouping types into Kinds.

### What the shared-tag heuristic actually produces

Union-find over app-claimed UTIs that share any extension or MIME tag gave 598 clusters
from 675 nodes. The large ones are instructive, not usable as-is:

- 14 UTIs merged through `.xls`/`.xlw` (Excel worksheets, stationery, workspaces — fine).
- 6 UTIs merged through `text/plain`: Markdown, CSV, Querious's tab data and plain text.
  That edge comes from one app's active declaration tagging Markdown `text/plain`, so
  filtering to active declarations does not remove it.
- 4 UTIs merged through `.mp4` plus audio/video MIME bridges, mixing audio with movies.
- `.xml` pulls generic XML together with Excel XML and two Word XML schemas.

Guardrails that follow, and that `KindBuilder` implements:

- Never treat `text/plain`, `application/octet-stream`, generic XML MIME types, or
  wildcard extensions as union edges.
- A "shared by at most two types" cap is not enough on its own; transitive chains still
  merge unrelated formats.
- Shared `public.data` / `public.content` conformance is not evidence of equivalence.
- Merges that will drive a default-handler change need the curated catalog to confirm
  them. Other shared-tag links are useful as *ambiguity* information for search and
  candidate matching, not as grounds for a batch write.
- Prefer splitting an uncertain cluster into separate Kinds over widening a write.

## 4. Measured write behaviour on macOS 26.6.2

Everything in this section was produced by running a spike script or the app by hand and
answering the prompts. It is the evidence behind the rules in
[write-path.md](write-path.md).

### Consent

- **One system prompt per successful change**, for file types and for schemes alike. A
  Kind with N settable members costs up to N prompts, one after another. This is why the
  UI shows "change 1 of 2" instead of a dialog of its own.
- **Successful calls take 3–4 s** — human answering time. The setter does *not* return
  before the user answers, contrary to older third-party accounts.
- **Rejections return immediately** (measured at 0.0 s) and show no prompt.
- The app cannot suppress, detect, or pre-answer any of this.

### Error 256 means two different things

`NSCocoaErrorDomain` 256 comes back both when the user **declines** a prompt and when
macOS **refuses before prompting**. There is no separate `NSUserCancelledError` for a
declined system prompt. Nothing in the error distinguishes them — only the elapsed time
does, and the two populations (0.0 s versus 3–4 s) are far apart. `HandlerWriter` times
every call and treats a 256 under 500 ms as a refusal, anything slower as a decline.

Known causes of a refusal:

1. **The type has no supertypes.** `public.markdown` on this Mac is declared only by
   Word's imported declaration and conforms to neither `public.item` nor `public.data`.
   No file ever resolves to it (`.md` resolves to `net.daringfireball.markdown`), and
   macOS will not assign it a handler. Such members are marked unsettable and skipped.
2. **The app is not on the type's own candidate list.** macOS accepts only apps that
   `urlsForApplications(toOpen:)` lists *for that exact type*. A Kind's candidate list is
   the union of its members' lists, so an app can be valid for the Kind and refused for
   one member. Setting MHTML to Chrome failed this way: Chrome was listed for
   `org.ietf.mhtml` but not for `com.microsoft.word.mhtml`.

Ruled out: a missing direct claim is *not* the cause — for the `public.markdown` failure,
both the old and the new app claimed that exact UTI explicitly.

### The browser role

`http`, `https`, and `public.html` move together as one setting, and setting the `http`
scheme alone moves all three with a single prompt.

`public.xhtml` is **not** part of it. Measured twice in both directions (Arc ⇄ Chrome), it
stayed where it was while the other three moved. It is an ordinary type with its own call
and its own prompt.

### Extensions no declared type governs

Some extensions resolve to a generated `dyn.` type — on this Mac `.markdown`, `.mdown`
and `.mkd`, while `.md` resolves to a declared type. They can hold a default of their own,
which is how `.md` and `.markdown` end up opening in different editors.

- **Set them through the generated type**: `UTType(filenameExtension:)` returns the `dyn.`
  type, and the ordinary `setDefaultApplication(at:toOpen:)` takes it. It moves every file
  with that extension and **prompts like any other change**.
- **`setDefaultApplication(at:toOpenFileAt:)` is not a shortcut and is never called.** It
  returns instantly with no prompt, but it only pins *that one file*, by writing a
  `com.apple.LaunchServices.OpenWith` extended attribute on it. A fresh file with the same
  extension is unaffected.

  > The first extension spike concluded the opposite — that the by-file setter silently
  > changed the whole extension. It had read back the same file it set. The app shipped
  > extension rows on that basis and they appeared to succeed while changing nothing.
  > Anything claiming a prompt-free handler change deserves this specific check: set it,
  > then read back through a **different, fresh** file.
- Before setting an extension target, `ExtensionTargetGuard` re-checks that no declared
  type claims the extension. If one does, `UTType(filenameExtension:)` would hand back the
  declared type and change *its* handler for every extension it covers. That is exactly
  why the old error-256 fallback (retry through a `sample.md` file) was deleted: a sample
  `.md` resolves to `net.daringfireball.markdown`, so the retry would have changed a type
  the user never approved.

### Still unknown

- Whether a refusal can ever be slow enough (>500 ms, on a loaded machine) to be reported
  as "Declined". The outcome shown would still be accurate — nothing changed — only the
  reason would be wrong.
- Where macOS stores a per-extension default for a generated type. It does not appear as a
  `handlerpref` record in the dump.

## 5. Running the spike scripts

`Documentation/spikes/*.swift` are standalone `swift` scripts that produced the
measurements above.

> **They call the real default-handler setters.** Running one changes this Mac's defaults
> and raises consent prompts. Only a person sitting at the machine should ever run them,
> and only deliberately. They are kept as evidence of method, not as a test suite.
