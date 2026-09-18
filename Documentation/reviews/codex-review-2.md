# Independent review of 5f0d645

Reviewed **`5f0d645487ee1398d3befb4abd4e83bb7a68da54`**, dated 2026-09-18. I exported that commit with `git archive` into `.build/reports/codex-review-2-artifacts/source`; all reviewed source, compilation, and tests came from that export. The concurrent Applications work in the main working tree is outside this review. File/line references below refer to the reviewed commit, not the moving working tree.

**One P1 finding and four P2 findings.** The largest problem is the interaction between per-member eligibility and the coupled browser role: filtering out an unsupported member does not keep the later plan from changing it. There are also reproducible problems with all-shadowed fallback, Safari path identity, hidden mismatch diagnostics, and automatic catalog adoption.

## Findings

### R1 — P1: Browser-role expansion bypasses the acceptance filter and produces contradictory results

**Locations:** `Short Circuit/Stores/KindStore.swift:241–252`; `Short Circuit/Services/HandlerWriter.swift:59–68`; `Short Circuit/Views/KindCategory+Display.swift:95–99`; `Short Circuit/Views/KindInspectorView.swift:419–434`.

The store filters members by whether they accept the selected app, then passes only those targets to the writer. The writer subsequently expands any browser target into `http`, `https`, and `public.html`. Those newly covered targets can include members the store just rejected. The store then appends its unsupported results without reconciling them against the expanded plan.

**Concrete live inputs and simulated execution:**

- This Mac offers **ChatGPT** for HTTP and HTTPS, but not HTML or XHTML. The Web browser picker therefore advertises **“2 of 4 types.”** A whole-Kind change passes only the two schemes to the writer. The resulting `http` call covers all three browser targets. Against the simulated backend's measured browser coupling, HTML changes too. Results contain both `public.html: changed → ChatGPT` and `public.html: skipped/notSupported → Arc`. The inspector's `resultsByTarget` keeps the last result, so the member row claims HTML was unsupported even while the verified handler is ChatGPT. The summary counts the same target twice.
- **Sublime Text** has the opposite support pattern: HTML and XHTML, but neither browser scheme. Selecting it passes HTML to the writer, which turns that supported content-type request into an unsupported HTTP setter. Simulation reports error 256 for the expanded role and adds separate unsupported rows for the same schemes. The HTML globe menu also offers Sublime as “Make … the Default Browser” because it filters the HTML member, not the actual HTTP operation.

The browser notice correctly discloses coupling, and XHTML is correctly independent. The bug is the conflicting acceptance/count/result model layered on top of that disclosure. This is a real planner path with this Mac's candidate data; **I did not attempt either live setter**. Actual acceptance of ChatGPT as the default browser remains untested.

**Suggested fix:** construct the browser-role operation before calculating eligibility or support notes. Use one consistent policy for that atomic role in whole-Kind actions, per-member menus, support labels, planning, and results. Under the brief's strict “effective, accepting members only” rule, do not offer an atomic operation whose required covered members fail that rule; alternatively, explicitly model browser-role eligibility and disclose all covered targets instead of promising a subset. Filter browser menus against the real operation. Produce exactly one final result per target; never append an unsupported result for a target already covered by a performed step. This does not require restoring the removed app confirmation dialog.

**Regression coverage needed:** run the real store/planner against browser members with the two asymmetric candidate matrices above. Assert the offered operation, affected targets, distinct result IDs, and support-note count agree.

### R2 — P2: A known-empty effective set falls back to changing every settable member

**Locations:** `Short Circuit/Models/Kind.swift:95–99`; `Short Circuit/Stores/KindStore.swift:208–209,217–219`; `Short CircuitTests/LiveKindProviderTests.swift:149–155`.

`KindMember.isEffective` distinguishes unknown extension governance (`nil`, conservatively effective) from known-empty governance (`[]`, ineffective). `Kind.effectiveMembers` erases that distinction when every member is ineffective: it returns `settableMembers` anyway. Consequently, “whole-Kind changes touch effective members only” is false precisely for Kinds whose members all lose extension resolution.

**Concrete examples:** the fresh live pipeline has **16 Kinds with no effective member**, including Canon TIFF raw photo, Excel XML spreadsheet, Word 2003 XML document, Word XML document, CD Audio Track, and TrueType font. Canon TIFF RAW declares `.tif`, but `public.tiff` wins it; the Office XML types lose `.xml` to `public.xml`. A simulated whole-Kind selection made setter calls to `com.canon.tif-raw-image`, `com.microsoft.excel.xml`, and `com.apple.music.cdda` despite each member having `isEffective == false` and `governedExtensions == []`.

The UI promotes these members to the primary section because it consumes the same fallback. It can simultaneously say the extension is handled outside the Kind and offer a whole-Kind change that cannot alter that extension's preferred handler. Per-member editing remains useful; silently treating the empty effective set as unknown is the problem.

**Suggested fix:** keep a known-empty effective set empty for batch planning. Preserve conservative inclusion for `nil` governance; if a truly extensionless type needs separate treatment, represent that explicitly rather than inferring it from an empty winner set. Keep explicit per-member actions available, and explain when a Kind has no extension-governing batch targets. Check the resulting empty-set behavior of `unifyingCandidates`, picker availability, and default labels.

**Regression coverage needed:** the existing `allShadowedFallsBackToSettableMembers` test actually locks in this defect. Replace that expectation with a distinction between unknown, extensionless, and known-shadowed members, and assert no whole-Kind setter calls for the known-shadowed case.

### R3 — P2: The ordinary Safari path is rejected as an unsupported app

**Locations:** `Short Circuit/Models/Kind.swift:46–51`; `Short Circuit/Services/LiveKindProvider.swift:83–86`; compare `Short Circuit/Services/HandlerWriter.swift:88–90`.

The provider and `accepts` standardize spelling and trailing slashes but do not resolve symlinks. The writer uses a different identity rule that does resolve symlinks. On this Mac, NSWorkspace lists Safari at its Cryptex location, while the normal Applications path is another spelling of that same installation.

Read-only reproduction for the live HTTP member:

| Selected path | `accepts` | Writer's `sameApp` versus listed Safari |
|---|---:|---:|
| `/Applications/Safari.app` | false | true |
| `/System/Cryptexes/App/System/Applications/Safari.app` | false | true |
| `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app` | true | true |

Thus “Other…” can report that Safari cannot open the type even though selecting the listed Safari succeeds through eligibility. A scratch symlink to Preview reproduced the same disagreement. No app launch or setter was needed.

**Suggested fix:** use one bundle-URL identity function for candidate membership, candidate deduplication, default comparison, overlay, and the writer. Resolve symlinks and normalize directory spelling while keeping genuinely distinct installations distinct; do not collapse by bundle ID. Preserve a user-facing path separately if needed.

**Regression coverage needed:** extend `urlSpellingsDoNotMatter` beyond `..` to a real temporary symlink, compare the chooser spelling with the listed spelling, and preserve the existing two-installations test.

### R4 — P2: “Not split” hides real handler differences and overstates what extension lookup proves

**Locations:** `Short Circuit/Models/Kind.swift:107–118`; `Short Circuit/Views/KindInspectorView.swift:132–139`; `Short Circuit/Stores/KindStore.swift:77–86`; `Short Circuit/Views/KindBrowserView.swift:59–63`.

The current predicate answers **“can one listed app unify the extension-preferred members?”**, but the Split section presents that answer as the absence of handler differences. There are two distinct losses of information:

| Live Kind | Actual difference | Current verdict |
|---|---|---|
| WAV audio | `public.wav` → Fission; `com.microsoft.waveform-audio` → Music | Not mixed, not split; shows Music. WAV/WAVE/BWF all prefer the Microsoft type, so the Fission assignment is collapsed under Other declared types. |
| Word document | `org.strictopenxmlformats.wordprocessingml.document` → Adobe Illustrator; standard DOCX and Microsoft's two DOCX types → Word | Not mixed, not split; shows Word. The organization-prefixed strict type loses `.docx` resolution and is collapsed. |
| FaceTime call | `facetime:` → FaceTime; `facetime-audio:` → Phone | Mixed, not split; absent from Split because there is no unifying app. Both schemes are effective. |

The first two are concrete differences in the live explicit-type handler API, not evidence that an ordinary `.wav` or `.docx` currently opens incorrectly in Finder. Conversely, an extension-preference query does **not** establish that “No files use this type on this Mac” or that an explicit-type consumer can never observe the other handler. I did not find a real file opening through the shadowed WAV or strict-DOCX type, and did not launch a consumer to claim otherwise. The UI should state the narrower fact it measured.

FaceTime's differing defaults can be intentional, and its lack of a Fix Split button is appropriate. But it remains a mismatch the user may want to inspect or change member by member. Once the four fixable splits are resolved, the empty-state claim “Every type opens in a single app” is still false for FaceTime. Hiding it altogether from a mismatch-oriented view is unnecessary.

**Suggested fix:** separate handler divergence, extension-preferred divergence, and availability of a one-click fix. Keep the current restricted whole-Kind write policy, but expose “other handlers differ” and “mixed; no single app supports all members” as inspectable states. Say “Not preferred for any known extension” instead of “No files use this type.” Restrict the green Resolved label to the explicitly defined condition that was resolved, rather than treating every future `!isSplit` state as successful unification. An empty fixable-Split view should describe that narrower condition.

**Regression coverage needed:** assert both the preferred-handler presentation and continued visibility of the underlying mismatch for the WAV and strict-DOCX matrices. Test an effective scheme pair with no common app as a visible mixed state, without offering an impossible Fix Split action. Current tests only assert these cases disappear from Split.

### R5 — P2: Catalog extension adoption bypasses the package/file compatibility guard

**Locations:** `Short Circuit/Services/KindBuilder.swift:86–101` versus `260–276`.

The heuristic merger checks `GroupTraits.isCoherent`, including directory/package versus flat-file shape. The catalog's fallback extension-adoption path checks only category. An unknown category (`.other`) explicitly bypasses even that check. The authoritative catalog is allowed to define a format family; an **unlisted** vendor type should not acquire that authority just by claiming the same suffix.

**Reproduction against the actual bundled catalog:** I added a synthetic claimed type `review.folder-json` to a copy of the captured snapshot, conforming to `com.apple.package` and declaring `.json`. The catalog was unchanged. The fixture uses an offline settable predicate so the synthetic identifier can be exercised without registering anything with macOS. The heuristic keeps that package apart from flat `public.json`, but catalog adoption yields:

```text
PACKAGE JSON adopted into json, ["public.json", "review.folder-json"]
```

This is a fixture demonstrating a reachable loader defect, **not a claim that an installed application currently declares this identifier**. I found no wrong-format vendor adoption in the unmodified live capture. The defect matters as soon as another application registers an ambiguous package extension: the merged Kind can later make a batch change across different formats. The catalog deliberately separates package/file versions of iWork and EPUB, so this path defeats a boundary the content already respects.

**Suggested fix:** apply category and shape compatibility to both unlisted-member adoption paths, using the same conformance/shape evidence as the heuristic. Treat uncertain matches conservatively; explicitly listed UTIs remain the deliberate override. Do not let `.other` mean “compatible with any file shape.”

**Regression coverage needed:** test the real JSON catalog entry with a flat JSON type and a separately claimed `.json` package, plus a legitimate same-format vendor alias that should still join. `adoptionRespectsCategories` currently tests only a category mismatch and cannot detect this case.

## Live inventory and catalog audit

The fresh `lsregister -dump` was **32,218,124 bytes** on macOS **26.6.2 (25G83)**. The production parser produced **3,100 type records**; the catalog pipeline produced **932 Kinds**, **610 UTI members**, **135 catalog Kinds**, **56 Common Kinds**, and **4 Split Kinds**: Web browser, MIME HTML document, SQL source, and Tab-separated table. Counts describe this capture; installed-app registration can change during other agents' builds.

The committed catalog still has 146 entries, 162 uniquely owned UTIs, and unique ranks 1–60. I checked explicit ownership against every resulting UTI: **none was stolen**. Comparing catalog-enabled output with heuristic-only output, **no UTI was dropped**; the catalog added the four explicitly claimed plain-text encodings (`public.utf8-plain-text`, `public.utf16-plain-text`, `public.utf16-external-plain-text`, `com.apple.traditional-mac-plain-text`).

The only automatically adopted identifiers were:

| Catalog Kind | Adopted identifier | Result |
|---|---|---|
| Markdown | `public.markdown` | Still unsettable; excluded from effective members and writes. |
| Calendar event | `com.microsoft.outlook15.icalendar` | Still unsettable. |
| Email message | `com.microsoft.outlook15.email-message` | Still unsettable. |
| SQLite database | `com.araelium.querious.sqlite` | Still unsettable. |

These rediscoveries match the catalog notes; they are not new explicit content claims or wrong-format merges. Canon TIFF RAW remained separate from TIFF; Word/Excel XML remained separate from generic XML; MPEG-4 audio remained separate from video; TypeScript remained separate from MPEG transport streams; iWork package/file and EPUB package/container boundaries remained intact in this capture.

**Entries without a match:** `canon-cr3`, `feed`, `leica-raw`, `magnet`, `mkv`, `numbers`, `numbers-package`, `panasonic-raw`, `panasonic-rw2`, `sony-arw`, `sony-sr2`. These explain the four absent Common rows: Numbers, Matroska, Magnet, and Feed. This is consistent with the claimed-member merge rule; a declaration alone does not create a row. Matroska intentionally has no verified explicit UTI.

**Partial unmatched entries:** `property-list` lacks `com.apple.ascii-property-list`; `truetype` lacks `public.truetype-ttf-font`. The latter is particularly useful diagnostic evidence: `.ttf` resolves to `public.truetype-ttf-font`, but the surviving TrueType Kind contains only `public.truetype-font`, so its only member governs nothing and R2's fallback activates. The selected concrete winner is declared but is not independently claimed by the builder's input rules. It was not stolen by another catalog entry. Consider enriching such a catalog family with its live winner when NSWorkspace can demonstrate support, rather than substituting the parent as an “effective” member.

## Extension governance: what the live query establishes

I compared **1,188 unique extensions** from the captured declarations and produced Kinds with unconstrained `UTType(filenameExtension:)`, the production data/package-constrained lookups, and the dump declarations. Every non-dynamic governor returned by the production lookup was among the dump's declaring types for that extension. The dump does not rank competing active declarations; “active” is not proof that a declaration wins.

| Extension | Live governor(s) | Difference worth preserving |
|---|---|---|
| `.wav` | `com.microsoft.waveform-audio` | Both public and Microsoft WAV declarations are active; the public type does not win. |
| `.docx` | `org.openxmlformats.wordprocessingml.document` | Four active DOCX identifiers; only the standard type wins. |
| `.csv`, `.css` | Public CSV / public CSS | Vendor aliases remain valid declared members, but do not win these suffixes. |
| `.ts` | `public.mpeg-2-transport-stream` | The TypeScript declaration is also active. TypeScript correctly reports `.ts` as outside its Kind; its `.tsx` extension still governs. |
| `.xml` | `public.xml` | The three explicit Office XML types do not win generic `.xml`. |
| `.tif` | `public.tiff` | Canon TIFF RAW does not win the generic suffix. |
| `.mp4` | `public.mpeg-4` | Audio and movie aliases declare it, but the video type wins. |
| `.m4a` | `com.apple.m4a-audio` | The public audio type's `.m4a` declaration is inactive. |
| `.raw` | `com.panasonic.raw-image` | Leica is also an active declarer; neither unclaimed catalog entry is fabricated into a row. |
| `.pages` | `com.apple.iwork.pages.sffpages` for data; `com.apple.iwork.pages.pages` for packages | The production two-shape query correctly preserves both; an unconstrained lookup returns only the flat type. |
| `.epub` | `org.idpf.epub-container` for data; `com.apple.ibooks.epub` for packages | The IDPF folder alias does not win the package query. |
| `.ttf` | `public.truetype-ttf-font` | The catalog's surviving parent is not the selected winner. |
| `.plist` | `com.apple.property-list` | XML and binary subtypes do not win the extension. |
| `.mdown` | Dynamic type, excluded from governance | Markdown's declaration for this tag is inactive; the catalog still provides the search term. |

I also created scratch binary/XML property lists and a Word 2003 XML sample and queried their URL content types: they resolved to generic property-list/property-list/XML respectively. Those probes support the preferred-extension observations; they do **not** prove that all real files or explicit-type consumers have those types. No document was opened in an application.

## Concurrency, session state, icons, and tests

- **Write/refresh exclusion:** the store acquires its activity gate before any writer suspension and retains it through final handler reloads. Refresh refuses a write in progress, and `canWrite` refuses a refresh in progress. Existing delayed simulation tests for both directions and overlapping writes passed. I found no regression caused simply by removal of the app dialog.
- **Live planning:** the writer re-reads current handlers and checks already-default targets at execution time. The obsolete confirmation/reapproval path is gone. XHTML is its own call; HTTP/HTTPS/HTML remain one measured role. No file-based fallback exists.
- **Split session:** initial splits are captured on load, newly created splits are added after handler reload, fixed entries remain until refresh, and refresh resets the snapshot. Existing session tests passed. No independent session-tracking race was reproduced; the remaining concern is the meaning of “resolved” when mismatch and fixability share one predicate (R4).
- **Icons:** both user-facing refresh entry points invalidate the cache, and post-write reload invalidates the UTI icons of every affected loaded Kind. The extension-selected icon avoids the unsettable Markdown alias. I found no missing normal refresh/write invalidation path. Package-only Kinds fall back to their settable UTI when the unconstrained extension lookup selects another Kind; this worked for the catalog shapes inspected.
- **Unit suite:** `xcodebuild … test -only-testing:'Short CircuitTests'` against the frozen export, with isolated DerivedData `.build/dd-codex-review-2`, reports **135 passed, 0 failed, 2 skipped**. The skipped tests are the opt-in live count/export tests; the independent read-only harness performed a fresh live count/lookup audit instead. There were **three AppIntents metadata-extraction warnings**, no Swift compiler warnings, and no reported runtime warnings. The standalone review harnesses compiled without warnings.
- **Tests proving too little:** browser coupling and per-member support are tested separately, missing R1's composition; the all-shadowed test endorses R2; canonicalization covers `..` but misses actual Safari aliases; split tests assert suppression instead of diagnostic visibility; catalog tests check category but not shape during adoption. The bundled-catalog test checks nonempty content and unique IDs, not UTI ownership or ranks; this review independently checked both. A green suite does not resolve the findings above.

## Evidence and scope

Artifacts are under `.build/reports/codex-review-2-artifacts/`: frozen `source/`, `source-manifest.json`, `live-dump.txt`, `snapshot.json`, `kinds.json`, `unmatched-utis.json`, `uncatalogued-kinds.json`, `extension-resolutions.json`/`.tsv`, `harness.log`, `supplement.log`, source for both harnesses, `reproduce.sh`, `xcodebuild.log`, and `test-summary.json`.

Live operations were `lsregister -dump`, UTType queries, and NSWorkspace **read** APIs. All setter executions described above used `SimulatedHandlerBackend`; **no live writer was run**. I did not retest consent behavior, open sample files in apps, or change handlers. No app source, project file, shared model, or test file was edited; no commit, checkout, worktree registration, or other git-state mutation was performed. Solo MCP was unavailable, so the required eight-line report is `.build/reports/codex-review-2.md`.

## Five things to fix first

1. **Make browser-role eligibility, advertised scope, planning, and per-target results atomic and consistent** (R1).
2. **Stop the known-empty effective set from falling back to whole-Kind writes** (R2).
3. **Share symlink-aware app identity across lookup, acceptance, display state, and writing** (R3).
4. **Expose handler divergence separately from extension preference and one-click fixability** (R4).
5. **Apply category and package/file compatibility checks to unlisted catalog adoption** (R5).
