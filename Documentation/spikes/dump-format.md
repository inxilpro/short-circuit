# Independent ground truth: `lsregister -dump`

Solo process 55, `dump-truth`; checklist 1.5 groundwork. This report was computed independently from one captured dump with Python and shell tools. No Swift parser or app source was read or changed. The numbers below describe this snapshot, not a stable macOS format contract.

## Capture and reproducibility

| Property | Value |
| --- | --- |
| System | macOS 26.6.2 (25G83) |
| Capture start (UTC) | 2026-09-18T17:38:53.512863+00:00 |
| Capture end (UTC) | 2026-09-18T17:38:57.931198+00:00 |
| Elapsed | 4.418 seconds |
| Lines | 390,411 LF-terminated lines |
| Bytes | 32,151,209 |
| SHA-256 | `1153612d5fc59017273f51999dd7e86bed7b80a352131e08ccc78d530d5fdc88` |
| Exit / stderr | 0 / empty |

Command: `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -dump`. It was run once, with no other flags. Capture: [dump.txt](../../.build/dump-truth/dump.txt); metadata: [capture.json](../../.build/dump-truth/capture.json).

Reproduce the calculations without recapturing: `python3 .build/dump-truth/analyze.py`. The script reads only this raw snapshot and writes [analysis.json](../../.build/dump-truth/analysis.json), including complete identifier lists, Markdown evidence, cluster membership, and every shared tag with its member UTIs. [write_report.py](../../.build/dump-truth/write_report.py) renders this document from those results.

## Counts and definitions

There are **2,746 distinct declared UTI identifiers**, of which **0 start with `dyn.`**. The broader inventory from type declarations plus both app-claim views is **3,059 identifiers**, including **282 `dyn.` identifiers**. These answer different questions: dynamic identifiers are printed in bundle summaries even though no dynamic `type` declaration is printed.

| Measure | Count | Definition |
| --- | --- | --- |
| Declared UTIs | 2746 | Distinct `uti:` values in type records |
| Explicit app-claimed UTI identifiers | 675 | Distinct UTI-like tokens in `claim.bindings`, owner class Application |
| Explicit app-claimed, with declarations | 643 | 675 intersected with the declaration inventory |
| Explicit app-claimed, without declarations | 32 | Preserved verbatim; includes one dynamic identifier and malformed-looking identifiers |
| Bundle-summary app-claimed identifiers | 967 | Distinct tokens in application `claimed UTIs`, removing parenthesized tag annotations |
| Bundle-summary dynamic identifiers | 282 | `dyn.` prefix; 655 summary identifiers have type declarations |
| Combined app-claimed identifiers | 1014 | Union of explicit bindings and bundle summaries; 701 have declarations |
| Explicit UTIs across all bundle classes | 699 | Includes claims belonging to CoreTypes and SystemLibrary |
| Unique schemes in app claim bindings | 382 | Trailing `:` stripped; all such claim owners are applications |
| Unique schemes in application summaries | 376 | `claimed schemes` field; strict subset of the 382 |
| Bundles | 1316 | 809 Application, 505 RemotePlaceholder, 1 SystemLibrary, 1 CoreTypes |
| Handler preferences | 120 | 47 content-type, 61 scheme, 12 extension, with caveats below |

“App-claimed” here means an actual dump claim or bundle summary. It does not infer handlers through UTI conformance, wildcards, MIME matching, or an NSWorkspace query. Claim tokens are classified before accepting them as UTI-like: leading dot = extension, single-quoted token = OSType, trailing colon = scheme, slash = MIME; remaining nonempty tokens are retained as identifiers. Case and Unicode are preserved. All rankings count distinct identifiers, not repeated records, bundle copies, or tag occurrences. No active/inactive filter is applied unless explicitly stated.

Application classification uses `class: kLSBundleClassApplication (0x2)`, not a `.app` suffix. The 507 other bundle records include 505 remote placeholders; “other” therefore does not mean every item is intrinsically unrelated to an application. No disk-existence or live handler validation was attempted. Claim bundle references all resolve. Only CoreTypes and SystemLibrary own non-Application claims.

The six schemes present in claim bindings but absent from bundle summaries are `adbai`, `adobe+ilst`, `com.tinyapp.tableplus`, `li.zihua.medis2`, `orion`, and `unifi-protect`. Preserve both views rather than silently assuming equality.

### Handler preferences: the field label is not the category

The 120 records have 107 `unknown:` fields, 12 `extension:` fields, and one with neither. Of the unknown values, 46 have a trailing type-record reference, and 61 are bare strings. All 46 references resolve to type declarations, including `com.apple.default-app.web-browser` and `com.apple.default-app.mail-client`. The header-only `public.pax-archive` preference is also content-type evidence: its identifier occurs in a document claim and bundle claimed-UTI summary, despite lacking a declaration. This yields **47 content-type / 61 scheme / 12 extension** preferences.

The 61 scheme classification is an interpretation of the bare-string preference representation, not an explicit `scheme:` label: 43 match current claim bindings; the remaining 18 have no matching current scheme claim. They may be stale preferences. Preserve the raw category/value and distinguish inferred classification from verified current claims. A dotted preference name can be a scheme; do not classify by the presence of dots. `doc` is a scheme preference here, whereas `cs` is explicitly an extension preference.

Bare preference names without a matching current scheme claim: `itms-gc`, `itms-gcs`, `prli`, `linear`, `zoomcontactcentercall`, `mailspring`, `superhuman`, `zoomphonesms`, `zoomphonecall`, `granola`, `xcode-ci`, `x-swift-package-repository-authentication`, `xcarchive`, `x-source-tag`, `x-xcode-ci-build-report-feedback`, `xcpref`, `xcode-ci-handler`, `gamecenter`.

## Physical format and record counts

The first 63 lines are a database/status/memory preamble. Records begin after a line of exactly 80 ASCII hyphens. Every record header starts at column zero: `<kind> id:` except dictionary records, which start with `values:`. Fields are colon-delimited at column zero, normally with the value aligned around column 29. Split on the first colon only, since values include URLs and schemes. Empty lines are cosmetic; neither empty lines nor braces delimit top-level records. End-of-file must flush the final record.

| Record kind | Printed occurrences | Distinct record IDs | Distinct bodies |
| --- | --- | --- | --- |
| bundle | 1316 | 1316 | 1316 |
| type | 5972 | 3100 | 3100 |
| claim | 3897 | 2034 | 2034 |
| service | 146 | 73 | 73 |
| container | 10 | 10 | 10 |
| plugin | 606 | 606 | 606 |
| extensionpoint | 326 | 326 | 326 |
| handlerpref | 120 | 120 | 120 |
| values | 391 | No header ID | 391 |

Total: **12,784 record blocks**. Type/claim/service records are first interleaved with bundles and later printed again in global runs (2,034 claims, 73 services, 3,100 types at the end). Exactly 2,872 type IDs occur twice and 228 once; 1,863 claim IDs occur twice and 171 once; all 73 service IDs occur twice. After removing trailing blank lines, repeated IDs have identical bodies. A second distinct declaration with the same `uti:` but a different type ID is not a duplicate record: 3,100 declaration IDs describe 2,746 UTI identifiers. Keep declaration provenance and aggregate tags into sets.

The memory preamble independently reports Type=3,100, Claim=2,034, Bundle=1,316, HandlerPref=120, Plugin=606, ExtensionPoint=326, Service=73, Container=10, and dictionary=391 units, matching distinct records rather than printed occurrences. A separate direct line scan found 5,972 `uti:` lines / 2,746 unique values, 3,100 distinct `type id:` values, and 2,034 distinct `claim id:` values.

### Keys observed, by record kind

These are top-level keys only; indented plist/dictionary content is not promoted into fields. Key spelling and case matter. Optional fields are omitted, not reliably represented as empty values.

**bundle**: `bundle id`, `container`, `mount state`, `isOnRootVolume`, `isSystemManaged`, `isOnPrebootVolume`, `path`, `directory`, `name`, `localizedShortNames`, `teamID`, `identifier`, `version`, `codeInfoID`, `platform`, `executable`, `slices`, `base flags`, `Mach-O UUIDs`, `execSDK ver`, `infoDictionary`, `entitlements`, `Intents`, `class`, `sequenceNum`, `canonical id`, `versionString`, `displayVersion`, `mod date`, `exec mod date`, `reg date`, `rec mod date`, `type code`, `creator code`, `bundle flags`, `item flags`, `App Nap`, `eGPU`, `safeAperture system fullscreen`, `safeAperture app fullscreen`, `safeAperture windowed`, `Game Mode`, `Identified Game`, `iconDict`, `inode`, `exec inode`, `min version`, `min version platform`, `mach min ver`, `activityTypes`, `trustedCodeSignatures`, `displayName`, `localizedNames`, `category`, `uid`, `plist flags`, `icon flags`, `icons`, `MicUsage`, `retries`, `claimed UTIs`, `claimed schemes`, `iconName`, `Device Family`, `Bundle node not found on disk`, `library items`, `more flags`, `plugin Identifiers`, `library`, `itemID`, `itemName`, `storeFront`, `versionID`, `ratingLabel`, `ratingRank`, `genreID`, `vendor`, `PurchaserID`, `2ry category`, `appVariant`, `Wrapper relative path`, `Counterparts`, `EquivalentIDs`, `alt names`, `BGPermittedIDs`, `supportedGameController`, `System Hidden`.

**type**: `type id`, `bundle`, `uti`, `localizedDescription`, `flags`, `iconFiles`, `conforms to`, `tags`, `delegate`, `icons`, `reference URL`, `iconName`, `kextName`, `glyphName`, `plugin`.

**claim**: `claim id`, `localizedNames`, `rank`, `bundle`, `flags`, `roles`, `iconFiles`, `bindings`, `delegate`.

**service**: `service id`, `menu`, `port`, `message`, `timeout`, `send types`, `flags`, `user data`, `key`, `return types`.

**container**: `container id`, `path`, `flags`, `state`, `last checked`, `volume`, `disk image`.

**plugin**: `plugin id`, `container`, `mount state`, `isOnRootVolume`, `isSystemManaged`, `isOnPrebootVolume`, `path`, `directory`, `name`, `displayName`, `localizedNames`, `localizedShortNames`, `teamID`, `identifier`, `version`, `codeInfoID`, `platform`, `executable`, `slices`, `base flags`, `Mach-O UUIDs`, `execSDK ver`, `infoDictionary`, `entitlements`, `pluginIdentifier`, `parent`, `raw extension point ID`, `UUID`, `reg date`, `extension point ID`, `extension point name`, `SDKData`, `Intents`, `flags`.

**extensionpoint**: `extensionpoint id`, `Extension Point ID`, `Platform`, `Type`, `Name`, `Parent Bundle ID`, `TCC Policy`, `reg date`, `SDKDict`, `declaringFramework`.

**handlerpref**: `handlerpref id`, `unknown`, `all roles`, `mod date`, `extension`.

**values**: `values`, `count`.

### Short real examples

Type record:

```text
type id:                    com.autodesk.forge.f3d (0x6ef0)
bundle:                     Fusion (0x2980)
uti:                        com.autodesk.forge.f3d
localizedDescription:       "English" = ?, "LSDefaultLocalizedValue" = "Fusion 3D Design"
flags:                      inactive  rel-icon-path  exported  untrusted (0000000000000018)
iconFiles:                  Contents/Resources/f3d.icns
conforms to:                public.data, public.content
tags:                       .f3d
```

Claim record:

```text
claim id:                   Fusion 3D Design (0x44e0)
localizedNames:             "English" = ?, "LSDefaultLocalizedValue" = "Fusion 3D Design"
rank:                       Owner
bundle:                     Fusion (0x2980)
flags:                      apple-default  doc-type  relative-icon-path (0000000000001021)
roles:                      Viewer (0000000000000002)
iconFiles:                  Contents/Resources/f3d.icns
bindings:                   com.autodesk.forge.f3d, .f3d
```

Bundle excerpt (other fields omitted):

```text
bundle id:                  XProtect (0x14ac)
container:                  / (0x4)
path:                       /Library/Apple/System/Library/CoreServices/XProtect.app (0x24d4)
name:                       XProtect
identifier:                 com.apple.XProtectFramework.XProtect
class:                      kLSBundleClassApplication (0x2)
canonical id:               com.apple.xprotectframework.xprotect
```

Handlerpref record:

```text
handlerpref id:             itms-gc (0x5a0)
unknown:                    itms-gc
all roles:                  com.apple.gamecenter.gamecenteruiservice
mod date:                   2000-12-31 19:00 (POSIX 978307200, 𝛥 25yrs 8mths 2wks 3days 18hr 38min 56sec)
```

### Values, ownership, and irregularities

1. **Ownership is a reference, not the preceding bundle.** `claim.bundle: Fusion (0x2980)` joins the trailing numeric ID to `bundle id: Fusion (0x2980)`. The display name can be empty or duplicated, and is not a bundle identifier. Preserve both the numeric record ID and the application `identifier:`. Global claim runs have no immediately preceding owner bundle. Types can instead have `plugin:` ownership: 99 printed type records use that field rather than `bundle:`. Numeric IDs are local to their record table; do not use one cross-table ID map.

2. **Lists use comma-plus-space.** `tags: .md, .markdown, text/markdown`, `bindings: net.daringfireball.markdown, public.markdown`, and `conforms to: public.data, public.content` are single lines. Device tags contain literal commas without a following space (`iPhone12,1`); splitting every comma corrupts them. Legacy OSTypes are quoted (`'TEXT'`, `'ICO '`, `'****'`); retain internal whitespace and classify before testing for MIME slashes. There were no quoted comma-containing tags/bindings in this snapshot. Multi-part extensions such as `.css.erb` are single tokens. Wildcards `.*` and `'****'` are not specific types.

3. **Tag class is implicit in type tags.** Leading-dot tokens are filename extensions, slash-containing non-quoted tokens are MIME candidates. Other tags include device models, OSTypes, and pasteboard names; do not treat every tag as an extension or UTI. Bundle `claimed UTIs` can print derived identifiers such as `dyn.ah62d4qmuhk2x43dts71g255bqu (.download)` or a dynamic identifier followed by `(MIME application/...)`; the annotation is not part of the identifier.

4. **Roles and flags differ from comma lists.** `flags: active  apple-internal  exported  core  trusted (0000000000000075)` is a whitespace-separated list plus a hexadecimal bitmask without `0x`. Observed claim roles are Viewer, Editor, None, Importer, Shell, and QLGenerator, each followed by its mask; no multi-role combination was observed, so no combined-role spelling is asserted. Keep the mask/raw value for unknown future roles or flags. `inactive` must not match a substring check for `active`. Rank is a separate field.

5. **Indented plist/dictionary blobs are substantial.** `infoDictionary`, `entitlements`, `Intents`, `iconDict`, `icons`, `SDKData`, and `SDKDict` may introduce multiline `{ ... }` / `( ... )` descriptions, nested dictionaries, arrays, escaped strings, and data. They are not standalone XML plists. The 391 `values:` records have tab-indented dictionary bodies, including nonbreaking spaces before hex references. Bundle plist content also contains UTI declarations and URL schemes; indiscriminate text matching double-counts them.

6. **The relevant lists did not wrap.** No indented continuation followed `tags`, `bindings`, `conforms to`, `roles`, or `flags`. Maximum observed value lengths: tags 1,253, bindings 1,901, conforms-to 117 characters. Nested plist content and localized text do span many physical lines elsewhere; do not impose a short line limit or trim indentation before deciding whether a line is a top-level field.

7. **Missing/empty/repeated fields are real.** Sixteen printed claims have no `bindings:`. Three unique claims have an empty display name (`claim id: (0x1ca8)`, `(0x8918)`, `(0x8b7c)` after trimming), so extracting IDs must allow the value to begin with `(`. Five bundles repeat `supportedGameController`; a dictionary that overwrites duplicate keys loses data. Optional type icons can be an empty multiline dictionary. The `Bundle node not found on disk:` diagnostic appears in 88 bundles.

8. **Encoding is valid but not ASCII.** Strict UTF-8 decoding succeeds; there are zero NUL and CR bytes. Localizations include non-Latin text, directional marks and nonbreaking spaces. Claim identifiers `com.adobe.postscript-lwfn\u200b-font` and `com.netscape.javascript-\u200bsource` contain actual U+200B zero-width spaces. Do not silently normalize them into other identifiers. No non-UTF-8 behavior could be tested from this capture.

9. **Duplicates are more than repeated records.** Multiple registered paths can share the same bundle identifier (118 identifier values repeat across bundle records); record ID/path distinguishes installations. Aggregate app display carefully, and retain provenance. An app declaring a UTI is not proof it claims to open it: Notes and MacWhisper declare Markdown but have no exact Markdown UTI claim or matching summary entry here.

## Most shared tags

All distinct declared UTIs, including inactive declarations; no app-claim restriction for these two rankings. Ties sort lexically by tag. The full mappings are recoverable from the raw capture and script; each table intentionally stops at exactly 20.

| Extension | Distinct UTIs |
| --- | --- |
| `.xls` | 8 |
| `.xlm` | 6 |
| `.xlw` | 5 |
| `.docx` | 4 |
| `.plist` | 4 |
| `.xml` | 4 |
| `.docm` | 3 |
| `.dotm` | 3 |
| `.epub` | 3 |
| `.ibooks` | 3 |
| `.itms` | 3 |
| `.m3u` | 3 |
| `.m3u8` | 3 |
| `.mp4` | 3 |
| `.orf` | 3 |
| `.xla` | 3 |
| `.aifc` | 2 |
| `.app` | 2 |
| `.asif` | 2 |
| `.book` | 2 |

| MIME type | Distinct UTIs |
| --- | --- |
| `text/plain` | 5 |
| `application/msexcel` | 3 |
| `application/mspowerpoint` | 3 |
| `application/vnd.ms-excel` | 3 |
| `application/vnd.ms-powerpoint` | 3 |
| `audio/mpegurl` | 3 |
| `audio/x-mpegurl` | 3 |
| `application/json` | 2 |
| `application/msword` | 2 |
| `application/x-msdownload` | 2 |
| `application/x-photoshop` | 2 |
| `audio/mp4` | 2 |
| `audio/mp4a-latm` | 2 |
| `audio/mpeg` | 2 |
| `audio/wav` | 2 |
| `audio/x-mpeg` | 2 |
| `audio/x-scpls` | 2 |
| `audio/x-wav` | 2 |
| `message/rfc822` | 2 |
| `text/calendar` | 2 |

## Markdown case study

Exactly **two declared UTIs** have a `.md` tag. Five distinct declaration records supply that tag:

| UTI | Type record ID | Declaring owner | Flags | Tags |
| --- | --- | --- | --- | --- |
| `net.daringfireball.markdown` | `0x6f0c` | Mud (0x2b40) | inactive  imported  trusted | `.md, .markdown, .mkd` |
| `net.daringfireball.markdown` | `0x4894` | Notes (0x3d0) | inactive  apple-internal  imported  trusted | `.md, .markdown, text/markdown` |
| `net.daringfireball.markdown` | `0x4cac` | MacWhisper (0x5b8) | active  exported  trusted | `.md, text/plain` |
| `net.daringfireball.markdown` | `0xb280` | Xcode (0x4eb8) | inactive  apple-internal  imported  trusted | `.md, .mdown, .markdown, .text, text/markdown, text/x-markdown, text/x-web-markdown` |
| `public.markdown` | `0xd66c` | Word (0x5060) | active  public  imported  trusted | `.md, .markdown` |

Every exact UTI claimant and every claimant in the bundle-summary view is listed below. Generic text handlers and inherited conformance are not added. Notes and MacWhisper above are declarers, not exact Markdown claimants.

| UTI | Explicit `claim.bindings` apps | Bundle `claimed UTIs` apps |
| --- | --- | --- |
| `net.daringfireball.markdown` | Mud (`org.josephpearson.Mud`); Xcode (`com.apple.dt.Xcode`) | Mud (`org.josephpearson.Mud`); Xcode (`com.apple.dt.Xcode`); Claude (`com.anthropic.claudefordesktop`) |
| `public.markdown` | Mud (`org.josephpearson.Mud`); Word (`com.microsoft.Word`) | Mud (`org.josephpearson.Mud`); Word (`com.microsoft.Word`) |

All apps with a **bare `.md` binding and no UTI token in that claim**:

| App | Bundle identifier | Bundle record | Claim record | Registered path |
| --- | --- | --- | --- | --- |
| Cursor | `com.todesktop.230313mzl4w4u92` | `0x60c` | `0x189c` | `/Applications/Cursor.app` |
| Sublime Text | `com.sublimetext.4` | `0x7b8` | `0x23f4` | `/Applications/Sublime Text.app` |
| Air | `com.jetbrains.air` | `0x4ff4` | `0x8b90` | `/Users/inxilpro/Applications/Air.app` |
| Claude | `com.anthropic.claudefordesktop` | `0x5180` | `0x9830` | `/Applications/Claude.app` |

Claude appears in the bare-binding list and in the `net.daringfireball.markdown` bundle summary: LaunchServices has resolved its extension claim in the summary. Cursor, Sublime Text, and Air have no exact Markdown UTI binding. The seven distinct apps represented by explicit Markdown claims or bare `.md` bindings are Mud, Xcode, Microsoft Word, Cursor, Sublime Text, Air, and Claude. Listing only UTI declarations or only explicit UTI claims misses part of that picture.

## Clustering experiment

Algorithm: build one set of extension/MIME tags per UTI by unioning all its distinct declarations, retain only explicitly app-claimed identifiers, and union every pair sharing any such tag. Undeclared claimed identifiers remain singleton nodes. No conformance, extension-only app claim, role, rank, trust, active flag, or preferred-tag selection adds or removes edges. Namespaces are kept distinct, and ties sort by lexicographic member list. This is the literal shared-tag heuristic, measured rather than guessed.

With **675** nodes, the result has **598 clusters**. The ten largest are:

| Rank | UTIs | All glue tags (number of members sharing each) |
| --- | --- | --- |
| 1 | 14 | `.xls` (8), `.xlw` (5), `application/msexcel` (3), `application/vnd.ms-excel` (3) |
| 2 | 6 | `text/plain` (4), `.csv` (2), `.markdown` (2), `.md` (2), `.text` (2) |
| 3 | 6 | `.xlm` (6) |
| 4 | 4 | `.mp4` (3), `.m4a` (2), `.mpg4` (2), `audio/mp4` (2), `video/mp4` (2) |
| 5 | 4 | `.xml` (4) |
| 6 | 3 | `.plist` (3) |
| 7 | 3 | `.ibooks` (3) |
| 8 | 3 | `.epub` (3) |
| 9 | 3 | `.mpkg` (2), `.pkg` (2) |
| 10 | 3 | `.mp2` (2), `audio/mpeg` (2), `audio/x-mpeg` (2) |

There are eight clusters of size three, so the last five rows are a deterministic selection from a tie. These are all the members of the ten rows above:

1. **14 UTIs:** `com.microsoft.excel.xls`, `com.microsoft.excel.xls.biff2`, `com.microsoft.excel.xls.biff3`, `com.microsoft.excel.xls.biff4`, `com.microsoft.excel.xls.biff5`, `com.microsoft.excel.xls.stationery.biff3`, `com.microsoft.excel.xls.stationery.biff4`, `com.microsoft.excel.xls.stationery.biff5`, `com.microsoft.excel.xlt`, `com.microsoft.excel.xlw`, `com.microsoft.excel.xlw.biff2`, `com.microsoft.excel.xlw.biff3`, `com.microsoft.excel.xlw.biff4`, `com.microsoft.excel.xlw.biff5`.

2. **6 UTIs:** `com.araelium.querious.csv`, `com.araelium.querious.tab`, `net.daringfireball.markdown`, `public.comma-separated-values-text`, `public.markdown`, `public.plain-text`.

3. **6 UTIs:** `com.microsoft.excel.xlm`, `com.microsoft.excel.xlm.biff2`, `com.microsoft.excel.xlm.biff3`, `com.microsoft.excel.xlm.biff4`, `com.microsoft.excel.xlm.stationery.biff3`, `com.microsoft.excel.xlm.stationery.biff4`.

4. **4 UTIs:** `com.apple.m4a-audio`, `public.mpeg-4`, `public.mpeg-4-audio`, `public.mpeg-4-movie`.

5. **4 UTIs:** `com.microsoft.excel.xml`, `com.microsoft.word.wordml`, `com.microsoft.word.wordprocessingml`, `public.xml`.

6. **3 UTIs:** `com.apple.binary-property-list`, `com.apple.property-list`, `com.apple.xml-property-list`.

7. **3 UTIs:** `com.apple.ibooks`, `com.apple.ibooks-container`, `com.apple.ibooks-folder`.

8. **3 UTIs:** `com.apple.ibooks.epub`, `org.idpf.epub-container`, `org.idpf.epub-folder`.

9. **3 UTIs:** `com.apple.installer-meta-package`, `com.apple.installer-package`, `com.apple.installer-package-archive`.

10. **3 UTIs:** `com.apple.music.mp2`, `public.mp2`, `public.mp3`.

The largest (14) cluster combines Excel worksheet, stationery/template, and workspace variants through `.xls`, `.xlw`, and Excel MIME tags. The six-member `text/plain` cluster merges Markdown, CSV, Querious tab data and plain text. `.xml` combines generic XML with Excel XML and two Word XML forms. `.mp4` and audio/video MIME bridges merge audio and movie types. These are useful ambiguity relationships, not sufficient evidence that a default-handler change should target all members.

### Sensitivity to the claim/declaration view

| Experiment | Ten largest sizes |
| --- | --- |
| Explicit claims; all declarations | 14, 6, 6, 4, 4, 3, 3, 3, 3, 3 |
| Bundle summary only; all declarations | 6, 4, 4, 4, 3, 3, 3, 3, 3, 3 |
| Union of both claim views; all declarations | 14, 6, 6, 4, 4, 3, 3, 3, 3, 3 |
| Explicit claims; active declarations only | 14, 6, 6, 4, 3, 3, 3, 3, 3, 3 |
| Explicit claims; omit text/plain and application/octet-stream edges | 14, 6, 4, 4, 3, 3, 3, 3, 3, 3 |

The union of both app-claim views has 1,014 nodes. It yields the same first ten sizes and glue sets as the explicit-claim experiment (the membership of other clusters can differ). The bundle-summary-only view suppresses many Excel subtype claims, reducing the biggest cluster. Active-only filtering does **not** solve the Markdown collision: MacWhisper’s active declaration assigns Markdown `text/plain`. The generic-MIME exclusion splits that collision but leaves other extension collisions intact.

### Recommended guardrails for the heuristic/catalog boundary

Use a **curated semantic equivalence rule** for merges that will drive default-handler changes: two UTIs may be merged only when the catalog confirms equivalence, or when a narrowly approved format-specific alias rule accepts them. Treat other shared extension/MIME links as ambiguity information for candidate matching and search. This fits the planned catalog merge/split layer; it does not require changing the settled UI decisions.

For runtime discovery, at minimum exclude `text/plain`, `application/octet-stream`, wildcard extensions, and generic XML MIME types as automatic union edges; treat broad `.xml`/`.plist` and mixed audio/movie or package/folder collisions as requiring catalog review. A “shared by at most two types” cap alone is unsafe: transitive chains and ambiguous two-way tags still merge distinct formats. Shared `public.data`/`public.content` conformance is not evidence of equivalence either.

Store the tag and declaring bundle behind every proposed edge. Prefer splitting an uncertain component into separate Kinds over turning a generic MIME association into a batch default change. Explicitly curate the two Markdown UTIs as equivalent while preventing their `text/plain` edge from pulling CSV/plain text into the same Kind. Preserve extension-only app bindings as candidates; do not invent a declaration or add a union edge just because an editor handles many extensions.

## Verification limits

Verified: one immutable dump, strict byte/UTF-8 checks, direct field-count cross-check, preamble distinct-unit reconciliation, complete owner joins, exact Markdown claims, both claim inventories, and computed union-find components. No default-handler setter, alternate `lsregister` flag, app build, Swift parser inspection, git mutation, or source-code edit was performed. No live NSWorkspace behavior, current file existence, alternative macOS version, malformed-byte fixture, or future-format behavior was verified. The 18 unmatched bare preference categories remain scheme inferences rather than current-handler evidence. Solo MCP tools were unavailable; the required Agent reports summary is supplied in `.build/reports/dump-truth.md`.
