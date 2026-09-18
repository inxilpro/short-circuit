# Checkpoint 1 — basic app working

Date: 2026-09-18. Branch: `main`. Built and verified on macOS 26.6.2, Xcode 27.0.

**The app runs on this Mac's real Launch Services data, and its set actions are real.** "Opens with", "Fix Split" and the per-member menus will change your defaults, each behind a macOS consent prompt. No agent has ever run the real setter; that part is yours to test.

## How to run it

Open `Short Circuit.xcodeproj` and run the `Short Circuit` scheme. The first launch takes about 5 seconds while `lsregister -dump` runs; later launches load from the cache in under a second. ⌘R forces a refresh.

## What works (verified)

| Area | State | How it was verified |
|---|---|---|
| `lsregister -dump` parser | Done | 3,100 types, 2,034 claims and 1,316 bundles parsed from the full dump; Codex compared ownership, tags and bindings against its own shell-only analysis and found zero mismatches |
| Index + disk cache | Done | Unit test for cache-first and refresh; both subprocess pipes drained concurrently |
| Kind clustering | Done | 943 Kinds, 381 with two or more candidate apps, 11 split. Markdown is one Kind with both UTIs and `.md`, without CSV or plain text (tested) |
| Browser UI | Done | Sidebar, grid and list, unified search, inspector, file drop. Reviewed from screenshots on sample and live data, light and dark |
| Write path | Built, **not run** | Unit tests against an in-memory stand-in for Launch Services only |
| Tests | Green | 74 unit tests pass; build has no warnings under Swift 6 |

Split Kinds found on this Mac: CSS, ICS, Markdown, Outlook/Mail `.eml`, MHTML, MPEG-4 movie, Word `.docx`, SQL, SQLite, WAV, Web page. The `.docx` one is a good example of what the tool is for: a rarely used "strict" `.docx` type currently opens in Adobe Illustrator.

## What the spike changed

Your consent spike (`Documentation/spikes/results.md`) reshaped the write path:

- One prompt per changed member, each needing confirmation. The app therefore asks first whenever a change will cause more than one prompt, and says how many.
- `public.markdown` failed with error 256 and no prompt. The app reports that member as failed and keeps the Kind marked split. `public.markdown` is declared only by Word's imported declaration, with no parent type, which may be why.
- The deprecated `LSSet*` functions are silently ignored on 26.6, so they are not used anywhere.

## What the Codex review changed

Codex reviewed all the Swift independently (`Documentation/reviews/codex-review-1.md`, 12 findings, 4 high). The one that mattered most: the `toOpenFileAt:` fallback I had asked for on error 256 would have changed a type you never approved, because a sample `.md` file resolves to `net.daringfireball.markdown`, not `public.markdown`. **The fallback is deleted.** The other high findings (a re-planned change could grow past what was confirmed; a single-member menu on a web member was really a browser-wide change; a wrong merge of Radiance HDR with PICT) are fixed with regression tests. Re-review outcome: see the end of this document.

## Please test by hand

Nothing below can be checked without a person answering prompts. Suggested order, lowest risk first:

1. **Single member, per-member ⋯ menu.** Set `net.daringfireball.markdown` to Mud, then back. Expect one prompt each way and a "Changed" result.
2. **Decline a prompt.** Does the member show "Not changed" or an error? The code handles both, but which one macOS produces is unknown.
3. **Whole Kind.** Set Markdown to one app. Expect a confirmation naming two changes, then one prompt, then "1 changed, 1 failed" with the 256 explanation.
4. **Fix Split** on a harmless Kind such as WAV or SQLite. It should touch only the members that differ.
5. **"Other…"** app picker.
6. **Default browser.** The dialog should say it changes http, https, HTML and XHTML together. Watch whether `public.xhtml` actually follows: on this Mac it currently opens in Sublime Text while the rest open in Arc, so the "locked together" rule is unproven for XHTML.
7. **Drag a file from Finder** onto the window. Only the code path behind the drop was exercised.
8. Put back anything you changed; there is no undo yet.

## Known gaps

- **"Common" is not curated.** It is every Kind with two or more candidate apps (381), alphabetical, so obscure formats sit beside PDF and JPEG. Fixing that is the curated `Catalog.json` from the plan, which is not started.
- Most Kinds in "Other" are app-private URL schemes (361 scheme-only Kinds). Single-app ones stay out of Common, but schemes claimed by two installs of the same app (Illustrator, Bartender, Battle.net) still show there.
- **CSV is now two Kinds** ("Comma-separated values" and Querious's "CSV File"), both for `.csv`. The final round's rule against merging across vendors with different MIME types, added to separate Leica and Panasonic `.raw`, also separated these. That is a missed merge, so a `.csv` split is currently invisible. It needs the catalog or a narrower rule.
- Kinds for formats with no declared UTI (extension-only claims) are skipped when they would have no member the setters can act on.
- Some merge decisions (CPIO/pax, MP2/MP3) rest on the extension rule rather than a catalog.
- No staleness check on the cache; refresh is manual or on launch.
- Grid has no arrow-key navigation. The error state was only seen in a preview.
- Not started: Applications view, batch "make default", undo, Settings, signing and notarization.

## Decisions for you

1. **Direction.** Is the Kind model and the Finder-style browser what you wanted? Look at Markdown, Web page and the `.docx` Kind first.
2. **`Views/DebugSnapshotter.swift`: keep or delete?** Agents have no Screen Recording permission, so this DEBUG-only, env-gated helper captures the app's own window through `CGWindowListCreateImage`, reached with `dlsym` because the SDK marks it unavailable. It is how every screenshot in this run was made. It never ships in Release. Granting Screen Recording to Solo would make it unnecessary.
3. **Next milestone.** I recommend the curated catalog next, since "Common" is the weakest part of the app today, then the Applications view.
4. **Error 256 types.** Accept "macOS won't allow this" as the answer, or spend time finding a supported route?

## How this was built

Orchestrated through Solo (scratchpad `short-circuit-orchestration`). Two Claude Opus agents wrote the data layer and the UI in parallel against a shared `Kind` contract; a Codex agent produced independent ground truth for the dump format, then reviewed the code. Worker prompts are in `.build/prompts/` (untracked). One oddity: unsubmitted text appeared several times in the Claude workers' input boxes ("keep the snapshotter", "Next task: read .build/prompts/catalog.md…"). I did not type it, one named a file that does not exist, and I treated none of it as instruction. It is most likely Claude Code's own prompt suggestions.

## Re-review outcome

Codex re-checked the fixes at `d109df1` (appended to `Documentation/reviews/codex-review-1.md`), re-running its own reproductions against the new code with simulated backends: 68 of 68 tests passed at that commit.

- **Fixed:** R1 (fallback removed; one call, one failure, other UTI untouched), R2 (a plan that grows after confirmation runs nothing and asks again; no bypass found), R3 (browser changes always confirm and name all four members), R4 (Radiance/PICT and CPIO/pax separate), R7 (one write at a time), R8 (refresh cannot erase results), R12 (both pipes drained).
- **R10** was half fixed at re-review and finished in a last round: both installs of an app stay in the list, and colliding names now show the version, or the folder when versions match.
- **No new high-severity problem found.** All 639 UTI members resolve through `UTType`; none is `dyn.`.
- A last round also removed Kinds for application bundles and similar containers, split Leica from Panasonic `.raw`, and softened the browser wording, since nobody has verified that XHTML follows a browser change.

Codex did not review the last round. Its changes are covered by new unit tests and by my read-only live run only.
