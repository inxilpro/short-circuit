# Independent review 1 — parser, Kind pipeline, and writes

Reviewed commit: `72e3a709b3f2c363f3da2280286d2ceca236e679` (`main` HEAD at review time), on macOS 26.6.2 (25G83), Swift 6.4. Reviewed source files were compared byte-for-byte with that commit; hashes are in `.build/reports/codex-review-artifacts/source-manifest.json`. No app or test source was edited. No live writer/default-handler setter was invoked.

**Assessment:** the parser agrees with the independently captured dump on the checked fields. The current blockers are write authorization/scope and an unsafe Kind merge, followed by gaps in discoverability. All 37 existing tests passed, including the opt-in live pipeline, but they do not cover the reproduced write races or establish the real file-fallback behavior.

## Verification and artifacts

- Ran `TEST_RUNNER_SHORT_CIRCUIT_LIVE="$PWD/.build/reports/codex-review-artifacts/live-counts.txt" xcodebuild -scheme 'Short Circuit' -destination 'platform=macOS' -derivedDataPath .build/dd-codex-review test -only-testing:'Short CircuitTests'`. Result: **TEST SUCCEEDED**, 37 passing cases, no UI tests. Writer tests use simulated backends.
- Ran the exact production Swift models/services/store in a standalone scratch harness with Swift 6, MainActor default isolation, and `NonisolatedNonsendingByDefault`. Its input was the original immutable `.build/dump-truth/dump.txt`, not a reconstructed fixture. The harness only reads the live system; all write-flow checks use in-memory backends.
- Compared all **3,100 type records** for identifier, owning bundle, conformance, extensions and MIME types, and all **2,034 claims** for owning bundle and every classified binding against independent Python extraction. **Zero mismatches** after accounting for intentional wildcard/empty-extension exclusion. Duplicate IDs, three empty claim names, and zero-width-space identifiers survive correctly.
- Original capture: **1,316 bundles / 809 applications; 2,746 declared UTIs; 675 explicit app-claimed identifiers; 382 claimed schemes; 120 preferences**. Fresh live run had **1,320 bundles / 813 applications**, reflecting additional registrations since capture; the other counts matched.
- Preference classification is **46 content-type + 61 scheme + 12 extension + 1 header-only** in the parsed model. This is consistent with ground truth's 47/61/12 after resolving `public.pax-archive`. `Context.init` has that header-only resolution at `KindBuilder.swift:349`; the parser's separate unresolved representation is not a bug.
- Live timings: dump **4.399 s**, parse **0.631 s** in debug, build **0.149 s**, enrich **0.134 s**. The 32 MB stdout pipe completed successfully. Parsing/build work is detached/concurrent rather than running in the store's main-actor load path.
- Both the captured-input harness and fresh live pipeline produced **889 Kinds**, **527 UTI-based**, **299 with at least two live candidates**, and **8 split Kinds**.

Review artifacts under `.build/reports/codex-review-artifacts/`:

| Artifact | Purpose |
| --- | --- |
| `all-kinds.tsv` | **Every resulting Kind**, with name, category, member identifiers, extensions and candidate names |
| `built-kinds.json`, `enriched-kinds.json` | Complete pre/post-enrichment Kind data, including current handlers |
| `parsed-snapshot.json`, `parser-comparison.json` | Production parser output and independent comparison result |
| `live-counts.txt`, `xcodebuild.log` | Opt-in live test output and full test log |
| `ReviewHarness.swift`, `harness.log`, `harness-build.log` | Read-only/simulated reproductions below |
| `check_snapshot.py`, `source-manifest.json` | Reproducible raw-field comparison and reviewed source hashes |

## Findings

### R1 — High: the automatic file fallback can target a UTI outside the user's request

**Location:** `Short Circuit/Services/HandlerWriter.swift:133`, `:181–191`; related test double at `Short Circuit/Stores/SimulatedHandlerBackend.swift:92` and test at `Short CircuitTests/KindStoreWriteTests.swift:96`.

On Cocoa error 256 the writer creates `sample.<preferred extension>` and passes it to the file setter without checking its resolved content type. A preferred extension does not identify a unique UTI. The read-only reproduction on this Mac returned:

```text
Empty sample.md resolves to: net.daringfireball.markdown; public.markdown preferred extension: md
```

A per-member request for `public.markdown` therefore supplies a **different type** to its fallback. If the file setter succeeds for the resolved type, it can alter `net.daringfireball.markdown`, even though that member was not selected, and rereading only the originally requested member cannot detect/report that side effect. In a batch it can also affect a member already skipped or processed. The actual setter side effect remains untested; the type mismatch is directly measured. `Documentation/write-path.md` already acknowledges the uncertainty but the fallback is enabled in the production writer.

The fake success test does not validate the mapping: its file setter ignores the file's type and changes **every** target whose configured behavior is `rejectBeforeConsent`. That manufactures the exact outcome the test expects. Additionally, a fallback cancellation/error is discarded in favor of the original 256 error.

**Suggested fix:** disable this fallback until its actual target and consent behavior are established. If retained later, resolve the sample's content type, require it to match an approved target, include its full side effects in the confirmed plan, and verify every affected member. Make the fake map an explicit file/type to a specific handler and add a mismatched-type regression case; preserve fallback cancellation separately.

### R2 — High: a live replan can increase the number of changes after the confirmation decision

**Location:** `Short Circuit/Stores/KindStore.swift:174–187`; `Short Circuit/Services/HandlerWriter.swift:105–116`.

The store calculates `promptCount` from the displayed `Kind`, and automatically applies when it sees one change. It passes the **original targets**, including those currently considered already set. The writer then rereads live defaults and builds a potentially larger plan without returning to the store for confirmation. A system change since the last load, or while a dialog is open, can turn one expected call into two or more. The converse path at line 178 can say “already opens with” without checking the system at all.

Simulated reproduction using the unchanged production store/writer: display member A on the requested app and B on another app; initialize the backend with both A and B on the other app; select the requested app for the Kind. Result:

```text
STALE PLAN: confirmation requested=false, actual simulated calls=2
```

**Suggested fix:** create the reviewable plan from live reads, pass that approved plan into execution, and permit execution to shrink it as members become already-correct. If it would expand, request confirmation for the expanded scope before making calls. Cover stale zero-call, one-to-two-call, and pending-dialog cases with simulated tests.

### R3 — High: “set just this member” can silently become a browser-wide operation

**Location:** `Short Circuit/Services/HandlerWriter.swift:66–75`; `Short Circuit/Stores/KindStore.swift:163–164`, `:183–187`. UI context: `Short Circuit/Views/KindInspectorView.swift:315`.

Any single browser-role target is changed through `http`, but `Step.covers` contains only the requested subset. Selecting a per-member `public.xhtml` or `https` app therefore plans one call, bypasses the app-level confirmation, and reports only that member while invoking an operation with broader browser-role scope. The menu's tooltip mentions coupling, but the action itself is still presented as opening that individual member with the chosen app; its complete affected scope is not made reviewable.

The in-memory reproduction is deterministic:

```text
PER-MEMBER XHTML: calls=[http], reported targets=[public.xhtml], HTTP changed=true
```

Live reads also show **XHTML → Sublime Text**, while HTML/http/https → Arc. This does not prove how a future setter will behave, but it means the assumption that one http call will repair every listed member cannot be established by this snapshot. The simulator hard-codes full coupling, so the existing browser test cannot establish real XHTML behavior.

**Suggested fix:** represent the browser change as a browser-wide action with a visible full target list, even when initiated from a member row; disable or relabel the misleading per-member option. Report and reread the full affected set. Keep the observed XHTML distinction explicit until measured setter behavior establishes its coupling; do not infer that behavior from the fake.

### R4 — High: category/shape compatibility still merges unrelated formats

**Location:** `Short Circuit/Services/KindBuilder.swift:78–86`, `:130–138`.

The live Kind named **Radiance** contains both `public.radiance` and `com.apple.pict`, with extensions `pic`, `hdr`, `pict`, `pct`. Both active declarations share `.pic`, are categorized as images, and are flat files, so `GroupTraits.isCoherent` accepts the union. Radiance HDR and Apple PICT are distinct formats; selecting an app for the displayed Radiance Kind will attempt changes for both.

This is exactly the kind of over-merge the category guard cannot detect: equal broad category and shape do not establish format identity. Another component worth reviewing is **CPIO archive** (`public.cpio-archive`, `cx.c3.pax-archive`, extensions `cpio`/`pax`); the dump itself supplies the `.pax` overlap, so its semantic treatment needs an explicit catalog decision rather than reliance on the extension alone.

**Suggested fix:** add a curated split for Radiance/PICT before enabling broad Kind writes. Retain extension collisions as ambiguity information and require stronger/curated equivalence for action-driving unions. Add a real `.pic` collision fixture; the existing different-category test cannot catch this failure.

### R5 — Medium: bare-extension and MIME claimants cannot create missing Kinds

**Location:** `Short Circuit/Services/KindBuilder.swift:57`, `:335–341`, `:427–437`; parser model selection at `Short Circuit/Services/LSDumpParser.swift:23–27`.

Only explicitly claimed UTIs with declaration tags become draft Kinds. Bare extensions are attached only to an **existing** draft, and MIME claims never enter the context indexes. Bundle `claimed UTIs` summaries, which contain the system's resolved type associations, are not represented by the parser. Consequently the live inventory has no CSS or TypeScript Kind despite declarations for `public.css` / `com.microsoft.typescript` and explicit extension claims by editors. It also has no Go/Rust/Lua/JSX Kind (`.go`, `.rs`, `.lua`, `.jsx`), each claimed by Air, Cursor, and Sublime Text. Mud's `.mdx`, `.rmd`, and `.qmd` claims likewise have nowhere to appear.

The independent inventory has 967 identifiers in bundle summaries versus 675 in explicit claim bindings; 58 additional **non-dynamic** summary identifiers alone are absent from the explicit-claim set. This is not a parser-count mismatch, but the builder cannot discover these types from its current input/use of claims. The harness confirms `.css` and `.go` return no results; `.ts` only returns the unrelated prefix match “Tab-separated values.”

**Suggested fix:** resolve bare extension/MIME bindings to appropriate declared types (or consume the bundle summary associations) before choosing candidate UTI nodes. Keep ambiguous resolutions separate rather than merging everything sharing a tag. Decide explicitly how extension-only/dynamic formats are represented; do not silently drop them from the searchable inventory. Add CSS and TypeScript fixture cases where no app claims the UTI directly.

### R6 — Medium: tags excluded from merging are also removed from display/search

**Location:** `Short Circuit/Services/KindBuilder.swift:163–168`; `:36–38`.

`genericTags` correctly prevents overly broad `.xml`/`.plist` merge edges, but `makeKind` also excludes those tags from each Kind's public extensions. The real `public.xml`, `com.apple.property-list`, `com.apple.binary-property-list`, `com.apple.xml-property-list`, and Word/Excel XML Kinds therefore have **empty extensions**. The static generic-MIME denylist also removes `application/json` from the JSON Kind.

Read-only harness output:

```text
SEARCH .xml: []
SEARCH .plist: []
SEARCH application/json: []
```

The app explicitly promises extension/MIME search; these are legitimate tags even when they are unsafe as grouping edges. Dropping them also prevents extension fallback matching when a concrete file's type cannot be resolved.

**Suggested fix:** separate “unsafe to union” from “valid searchable metadata.” Preserve valid extensions and MIME tags with provenance/ambiguity, reserving merge exclusions for the graph. For known polluted tags such as Markdown's `text/plain`, make a specific display decision rather than suppressing the canonical tag on its genuine base type. Add search assertions for XML, plist and JSON.

### R7 — Medium: concurrent writes to different Kinds are not serialized

**Location:** `Short Circuit/Stores/KindStore.swift:197–205`; `Short Circuit/Services/HandlerWriter.swift:104–118`.

`applyingKindIDs` protects only the same Kind. The user can switch to another Kind and start a second write while the first is waiting for consent. Each invocation has a sequential loop, but there is no serialization across invocations. The scratch backend suspended each setter for 100 ms; two production-store applies for different Kind IDs yielded:

```text
CROSS-KIND WRITES: max simultaneous simulated setter calls=2
```

That can interleave system consent sequences and invalidate each batch's pre-read assumptions. This is a logical concurrency problem even though Swift's isolation checks pass.

**Suggested fix:** serialize entire apply operations with one global operation queue/lock, or disable all new writes until the active batch completes. An actor alone is insufficient if its apply method simply suspends and admits another call; queue complete operations and revalidate when they reach the front. Add a two-Kind overlap test.

### R8 — Medium: a refresh can erase verified post-write state and results

**Location:** `Short Circuit/Stores/KindStore.swift:113–116`, `:203–205`, `:210–221`.

`loadGeneration` orders refreshes against other refreshes, not against writes. A refresh whose handler reads precede a write can finish after the write's reload and replace the new handlers with its stale snapshot, then erase `results`. In the opposite ordering, `reloadHandlers` copies an old entire Kind before its awaits and replaces a newer refreshed Kind, potentially losing refreshed membership/candidate metadata despite the comment about merging into the latest state.

A delayed fake provider with the actual store/writer reproduced the first ordering:

```text
REFRESH RACE: write initially reflected=true, reflected after stale refresh=false,
result count=0, backend still new=true
```

**Suggested fix:** track handler mutations as well as refresh generations, and reject/re-enrich refresh results that predate a completed write. Merge refreshed handlers by target into the latest Kind rather than replacing its whole pre-await copy. Preserve write outcomes independently from ordinary inventory refreshes. Test both interleavings.

### R9 — Medium: category rules create visible document misclassification and prevent alias merges

**Location:** `Short Circuit/Services/KindBuilder.swift:218–243`; category-based union gate at `:84–85`.

The unconditional executable/developer check runs before document rules. The actual output categorizes macro-enabled Word/Excel/PowerPoint formats as **Developer**, including `org.openxmlformats.wordprocessingml.document.macroenabled` (`.docm`) and `org.openxmlformats.spreadsheetml.sheet.macroenabled` (`.xlsm`). Conversely `com.microsoft.excel.xml` is **Other** and `com.microsoft.word.wordprocessingml` is **Code** because their declarations say data/XML, although their names and app claims identify office documents.

A related wrong split is MHTML: `com.microsoft.word.mhtml` is **Other**, while `org.ietf.mhtml` is **Documents**. Both actively declare `.mht`/`.mhtml`; the inferred category disagreement prevents them becoming one web-archive Kind. One is named “Microsoft Word Single File Web Page,” the other “MIME HTML document.”

**Suggested fix:** apply format-specific/catalog categories before generic executable/XML ancestry, and do not treat inferred category equality as the proof of identity or inferred inequality as an immutable split. Add macro-enabled Office and MHTML alias regression fixtures.

### R10 — Medium: installed versions sharing a bundle ID disappear from the chooser

**Location:** `Short Circuit/Services/KindBuilder.swift:316–326`; `Short Circuit/Services/LiveKindProvider.swift:57–68`.

Both stages collapse applications to one entry per bundle identifier. On this Mac both `/Applications/Adobe Photoshop 2025/Adobe Photoshop 2025.app` and `/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app` exist and have `com.adobe.Photoshop`; the PSD Kind exposes only **Adobe Photoshop 2026**. The plan explicitly calls for version/path disambiguation when multiple installations share an identifier. Merging their claim ownership also attributes one installation's declared capabilities to the chosen other installation.

**Suggested fix:** preserve installed applications by standardized URL (plus bundle identity metadata), remove only genuinely stale/nonexistent duplicates, and disambiguate same-ID choices by version/path. “Other…” remains a workaround but does not satisfy the planned candidate behavior. Test two existing installation URLs with the same bundle ID and different capabilities/defaults.

### R11 — Low: independent variants have indistinguishable names, with no catalog reconciliation

**Location:** `Short Circuit/Services/KindBuilder.swift:57–62`, `:192–204`.

The extension-only graph leaves `public.heic` and `public.heif` as separate single-member Kinds, both named **HEIF Image**. `public.heics` and `public.heifs` are likewise both **HEIF Image Sequence**. Plain text produces three Kinds named **Text**: `public.plain-text`, `public.utf8-plain-text`, and `public.utf16-plain-text`; the latter two have no displayed extension. All three Text Kinds have multiple candidates and appear in the common view.

These need an explicit human-format policy rather than accidental name duplication. HEIC/HEIF and text encodings are useful candidates for curated grouping; if separate controls are intentional, their names must distinguish them. Unlike R4, conservative splitting itself does not risk changing an unrelated handler, so this is lower priority.

**Suggested fix:** add curated variant groups where one human Kind is intended and subtype-specific names where it is not. Assert uniqueness/disambiguation of visible names for these fixtures. Do not merge merely because descriptions happen to match.

### R12 — Low: stderr can still deadlock the dump subprocess

**Location:** `Short Circuit/Services/LaunchServicesIndex.swift:97–99`.

The successful 32 MB run confirms stdout is drained before waiting for exit, on a background queue. However stderr is drained only **after stdout reaches EOF**. If the child fills stderr while stdout remains open, it blocks writing diagnostics and never closes stdout, so the continuation and shared `inFlight` task never finish. No timeout/cancellation path breaks that wait.

This failure was not observed in either capture (stderr was empty); it is a bounded-stream failure condition visible in the implementation, not a claim that this Mac's current dump hangs.

**Suggested fix:** drain stderr concurrently, redirect it to a temporary file, or combine streams only if parser/error separation remains safe. Add an injectable child-process harness that writes beyond both pipe capacities and verify completion/failure propagation.

## Clustering/name audit: concrete output

These rows summarize the complete `all-kinds.tsv`; they do not replace the findings above.

| Actual output | Assessment |
| --- | --- |
| JPEG image: `public.jpeg`, `.jpeg/.jpg/.jpe` | Correctly unified by the existing UTI. No extra JFIF alias declaration appeared in this dump. |
| JPEG 2000 image: `public.jpeg-2000`; JPEG XL: `public.jpeg-xl` | Separate formats; no evidence they should be merged with ordinary JPEG. |
| Office Open XML word processing document: `org.openxmlformats.wordprocessingml.document`, `com.microsoft.word.openxmlformats.wordprocessingml.document`, `com.microsoft.word.strictopenxmlformats.wordprocessingml.document`; `.docx` | The **three claimed** docx variants are correctly grouped. The fourth declaring identifier `org.strictopenxmlformats.wordprocessingml.document` is not an explicit app claimant here. The long name is less useful than a curated Word document name, but not a correctness blocker. |
| Web page: `public.html`, `public.xhtml`, `http`, `https` | Correct intended browser/file grouping; actual XHTML default differs. Write-scope/coupling problem is R3, not an HTML clustering omission. |
| Markdown: `public.markdown`, `net.daringfireball.markdown`; `.md/.markdown/.mkd/.mdown` | Correct group; plain text/CSV no longer contaminate it. Bare `.md` candidates are retained. |
| Radiance: `public.radiance`, `com.apple.pict` | Wrong merge: R4. |
| CPIO archive: `public.cpio-archive`, `cx.c3.pax-archive` | Additional `.pax` ambiguity for catalog review; not independently validated as semantic equivalence. |
| HEIF Image ×2; HEIF Image Sequence ×2; Text ×3 | Variant splits/indistinguishable names: R11. |
| MHTML ×2, categories Other/Documents | Wrong alias split and inconsistent category: R9. |
| XML/property-list Kinds, no extensions | Search/display regression: R6. |
| Macro-enabled Office documents in Developer | Category error: R9. |
| CSS/TypeScript/Go/Rust/Lua/JSX absent | Claim-to-Kind discovery gap: R5. |

## Test and concurrency assessment

The existing fixture tests meaningfully cover ownership, deduplication, header-only preferences, nested plist exclusion, inactive flags, empty names, quoted lists, and invalid-looking identifiers. I found no evidence of test-specific output branches in the production parser/builder. Exact expected values for a fixed fixture are appropriate; they are not themselves hard-coded production behavior.

The major test weakness is the **file fallback fake** in R1: it directly forces the requested outcome without modeling the file's actual type. Browser tests similarly prove internal consistency with a hard-coded coupled fake rather than real OS coupling. The live test at `Short CircuitTests/LivePipelineDebugTests.swift:12–74` only prints statistics; it asserts that parsing/building produced values, not expected counts, ownership or clustering. A large semantic regression could still pass it. Preserve the independent baseline comparison and add assertions to an immutable full/trimmed fixture; avoid exact counts on a changing live database. Add the race/search/same-category-collision cases above to normal deterministic tests.

Swift 6 compilation passed with the project's isolation settings. `LaunchServicesIndex` owns cache state in an actor, uses one in-flight detached parse task, and writes atomically; I did not reproduce an intra-index cache corruption race. `LiveKindProvider.loadKinds` is `@concurrent`. The concrete concurrency failures found are **cross-Kind write overlap** and **refresh versus post-write state**, not a claim that the normal dump runs on the main actor. The two-stream subprocess concern is separately qualified in R12.

## Limits

No live write was performed, including the file fallback, browser setter, deprecated setters or consent-dialog interactions. Read-only defaults demonstrate current state, not future setter behavior. No UI tests were run; confirmation-dialog dismissal ordering and menu interaction were inspected in source only. No external API behavior was assumed proven by a simulated backend. The report distinguishes reproduced failures, measured file-type resolution, and the conditional stderr failure. The original dump and [ground-truth report](../spikes/dump-format.md), plus [measured setter results](../spikes/results.md), were the primary evidence.

## The five things to fix first

1. **Disable/constrain the file fallback (R1):** a `.md` filename does not identify the approved UTI; replace the misleading fake success coverage.
2. **Bind execution to a live, approved plan (R2):** re-confirm expansions instead of silently increasing batch calls.
3. **Make browser-wide scope explicit (R3):** stop presenting an http-role operation as an isolated member change; verify and report its complete affected set.
4. **Split Radiance from PICT before writes (R4):** broad category/shape agreement is insufficient proof of format identity.
5. **Recover claim-driven discoverability (R5/R6):** include CSS/TypeScript and extension-only formats, and preserve legitimate XML/plist/JSON search tags independently of merge policy.

## Re-review

Reviewed `main` **d109df1e2991ce456734d8e5475be04ede418cc9**; scope limited to R1/R2/R3/R4/R7/R8/R10/R12 and new high-severity regressions from these fixes. Source hashes match HEAD. No app/test edits or live writer calls.

**Validation:** 68/68 tests passed (xcresult summary, zero failures/skips), including the env-gated live pipeline and both subprocess-pipe tests, using `.build/dd-codex-rereview`. An adapted independent scratch harness reran the prior stale-plan, per-member browser, cross-Kind overlap, and refresh/write reproductions against production code with simulated backends. Logs, source hashes, full Kind JSON and live TSV are in `.build/reports/codex-rereview-artifacts/`.

1. **R1 — Fixed.** `Short Circuit/Services/HandlerWriter.swift:118–120,156–162` removes the file-setter backend operation and fallback entirely. The error-256 simulation makes exactly one call for `public.markdown`, returns failure, and leaves `net.daringfireball.markdown` untouched. No temporary-file type guessing remains in the writer.

2. **R2 — Fixed.** `Short Circuit/Stores/KindStore.swift:205–217` plans from live reads; `Short Circuit/Services/HandlerWriter.swift:90–94,142–151` checks the destination app, setter call and covered-target subset before any setter. `KindStore.swift:241–249` surfaces a revised confirmation. Rerun: stale display → confirmation for two calls, **zero calls executed**; one-call approved plan widening to two → `needsApproval`, **zero calls executed**. The ordinary suite also verifies narrowing and changes while the dialog is pending. I found no UI bypass of the wider-plan guard.

3. **R3 — Fixed for scope/authorization and reporting.** `HandlerWriter.swift:39–45,59–69` expands any browser request to the full role; `KindStore.swift:214–215` requires confirmation even for its single call. `Short Circuit/Views/ChangeConfirmation.swift:21–29` names http, https, HTML and XHTML; `Short Circuit/Views/KindInspectorView.swift:326–355` labels the member action as changing the default browser. Independent rerun: no call before confirmation; one http call afterward; four results, with non-following XHTML honestly `unchangedAfterSuccess`. Actual OS XHTML coupling remains unverified, and the UI still describes coupling more categorically than that evidence warrants.

4. **R4 — Fixed for the reported collisions.** `Short Circuit/Services/KindBuilder.swift:88–92,517–521` requires mutual preferred-extension agreement before a union. On the original full dump, `public.radiance` and `com.apple.pict` are now separate singleton Kinds; `public.cpio-archive` and `cx.c3.pax-archive` are also separate. The real-record collision test passes. This is a stronger heuristic, not a general proof of semantic equivalence; see the inventory check below.

5. **R7 — Fixed through the app's write entry points.** `KindStore.swift:118,200–207,231–235` gates planning/execution globally; `Short Circuit/ContentView.swift:71–76` routes whole-Kind, member and fix-split controls through that store. Independent overlap rerun: **one setter call, maximum concurrency one**; a second Kind's request is refused. No public store `apply` remains to bypass the gate. The generic writer itself is not a global queue, but no UI path invokes it directly.

6. **R8 — Fixed for the reproduced write/refresh races.** `KindStore.swift:118,123–142` prevents writes during refresh and refresh during writes, preserves results, and overlays verified handlers across mutation generations; `:261–283` patches by target instead of replacing a pre-await Kind. Independent rerun in both orders: a write-first run keeps the new handler/result and refuses refresh; a refresh-first run makes **zero setter calls**. The suite also verifies a subsequent live-reading refresh preserves results.

7. **R10 — Partially fixed.** `KindBuilder.swift:440–450` retains claim ownership per installation URL and `Short Circuit/Services/LiveKindProvider.swift:62–71` deduplicates by URL. Both Photoshop 2025/2026 now survive the full pipeline. However `KindInspectorView.swift:170–176,330–338` still renders only `app.name`, with no version/path disambiguation. The live chooser now contains two identically labeled **Adobe Illustrator** entries (`com.adobe.illustrator`), versions **30.0.0** and **29.8.3**, at the 2026/2025 installation paths. Add version/path only for colliding labels/identities; this is the remaining medium-severity part of R10.

8. **R12 — Fixed.** `Short Circuit/Services/LaunchServicesIndex.swift:106–117` drains stderr concurrently with stdout before waiting for process exit. Both 300,000-byte subprocess tests pass, including stderr-first output; the live ~32 MB dump also completes. This fixes the reported two-pipe deadlock; general timeout/cancellation behavior was not part of this recheck.

### New high-severity regression check

**No new high-severity problem was confirmed.** Whole-Kind, member, Other… and fix-split actions converge on the store's live-plan gate; batch/browser confirmations list the actual planned targets. Single non-browser changes still deliberately rely on macOS's consent prompt rather than an extra app dialog. No alternate file setter or direct UI writer path was found. Actual consent-dialog behavior was not exercised.

The original capture and fresh live pipeline both produce **971 Kinds** (610 UTI-based); the live result has 385 multi-candidate and 12 split Kinds. All **639 distinct UTI members resolve through `UTType`**, and none is `dyn.`; the growth did not introduce a demonstrated unknown-UTI setter failure. This check does **not** prove that macOS accepts every setter: the new `com.apple.application-bundle` / `com.apple.application-file` Kinds have no live default, and their writeability remains untested, as does the already-known rejection for `public.markdown`.

Compared every changed multi-UTI component with the previous capture's output: CSS, SQL, MHTML and the fourth DOCX identifier are added alias groups. The new **“Leica raw image (.raw)”** component contains `com.leica.raw-image` and `com.panasonic.raw-image`; both prefer `.raw`, but declare distinct vendor MIME tags. That deserves an explicit catalog equivalence/name decision before treating the heuristic as semantic truth. I have not established that these camera-format identifiers are incompatible, so this is a qualified follow-up rather than a claimed new high-severity wrong merge.

**Disposition:** seven requested findings fixed at the stated scope; R10 partially fixed. Keep real setter/browser-coupling verification separate from these read-only and simulated results.
