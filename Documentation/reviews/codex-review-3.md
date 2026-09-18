# Review 3 — Mac conventions and Undo

Reviewed committed HEAD **`900a87a7cc359ec1b15ec5d423bb38024075f4b4`** (includes `ac90b10` and `bb6d2fc`), exported with `git archive` to `.build/reports/codex-review-3-artifacts/source`. All source locations below refer to that frozen revision. **Two P1 findings, three P2 findings, and one remaining P3 wording issue.** No app-code edits or live setter calls.

## Findings

### R1 — P1: Undo overwrites an intervening external change, even after Refresh

**Location:** `Short Circuit/Stores/KindStore.swift:545–554,603–637`; refresh at `266–298`.

An Undo record stores only the destination to restore, not the handler installed by the original operation. `performUndo` calls the writer without checking that the target still has that expected post-change handler. The writer's live plan only asks whether it already equals the *old* app, so a third-party change is treated as another reason to restore. Refresh neither validates nor clears these records.

**Reproduced with a simulated backend and real UndoManager:** PNG Preview → Photos; an external change sets TextEdit; forced refresh displays TextEdit and leaves `canUndo == true`; Undo calls the setter and replaces TextEdit with Preview. This overwrites a newer choice outside the operation being reversed. There is no stale-history notice.

**Fix:** retain before/verified-after identities for every affected target, then validate the live after-state before restoring. Skip/invalidate conflicting history with an explanation. Decide and implement an explicit refresh policy: reconcile remaining history against refreshed handlers or clear stale entries. Capture transaction evidence alongside actual writer execution rather than relying solely on the store's earlier, separate pre-read.

### R2 — P1: Every successful “Other…” sheet selection loses its target before completion

**Location:** `Short Circuit/ContentView.swift:34–41,78–79`; `Short Circuit/Stores/KindStore.swift:749–751`.

The `choosingApp` binding calls `cancelAppChoice()` whenever presentation becomes false. SwiftUI sets that binding to false **before** invoking the successful completion callback, per Apple's [fileImporter contract](https://developer.apple.com/documentation/swiftui/view/fileimporter%28ispresented%3Aallowedcontenttypes%3Aallowsmultipleselection%3Aoncompletion%3Aoncancellation%3A%29). The callback then schedules `completeAppChoice`, whose first guard sees `pendingAppChoice == nil` and returns. Whole-type and per-identifier “Other…” both silently do nothing; the chosen folder is not remembered either.

**Reproduced:** drive the exact binding setter before completion, as documented: zero backend calls, nil pending target, nil remembered folder. This is a deterministic callback-order reproduction, not a screenshot/manual sheet test.

**Fix:** separate presentation state from the pending command. Preserve its target until completion consumes it; clear it on explicit cancellation/failure. Capture a stable command for the async task. Add a success-path test with dismissal occurring before completion, not just tests of requesting/cancelling the panel.

### R3 — P2: Undo bypasses current per-type and browser-call eligibility

**Location:** `Short Circuit/Stores/KindStore.swift:621–629`, compared with normal writes at `515–520` and batches at `383–386`.

Undo sends its saved app/target directly to `writer.apply`; it never rechecks current `isSettable`, whether the type still exists in the loaded inventory, or whether the restored app is accepted for that type. A browser restore likewise bypasses the HTTP eligibility rule. Eligibility may have changed since the original write through an app update/removal or registry refresh.

**Reproduced:** after PNG Preview → Photos, the simulated system's allowed list is changed to Photos only. Undo still makes a second setter call requesting Preview; the backend rejects it with 256, Undo stops, and its history entry is gone. The failure banner is accurate, but the new write path violates the accepted-target filtering used elsewhere.

**Fix:** re-resolve the saved target and validate current app availability, settable status, and exact-target acceptance immediately before restoration; use HTTP eligibility for the browser operation. Preserve the fact that an explicit per-member original action may legitimately restore a shadowed member—do not indiscriminately apply whole-Kind effective filtering to Undo. Report unsupported restores without issuing knowingly rejected calls.

### R4 — P2: Busy Undo consumes its history entry although no restore runs

**Location:** `Short Circuit/Stores/KindStore.swift:590–605`; `Short Circuit/Views/AppCommands.swift` leaves native Undo enabled; test gap at `Short CircuitTests/UndoTests.swift:119–134`.

UndoManager removes the registered action and invokes its closure synchronously. That closure merely starts a Task; only later does `performUndo` check `canWrite`. If another write or refresh owns the gate, the restore is refused, but nothing retains or reinstates the consumed record. This is lost history, not concurrent setter execution.

**Reproduced:** change PNG, begin a delayed JPEG change, invoke actual `UndoManager.undo()`: the PNG record disappears while PNG remains changed. After JPEG finishes, Undo reverses JPEG, then `canUndo == false` with PNG still changed. Invoking Undo during a delayed refresh also consumes the record with no setter call. Two immediate native Undo requests similarly restore JPEG but lose PNG’s record. Maximum concurrent setter calls remained **1**.

**Fix:** prevent UndoManager from consuming application history while a write/refresh/restore is busy, or queue and retain the operation until it can run. Coordinate native menu validation and async transaction ownership before removing history; a guard only inside the Task is too late. Add actual UndoManager tests for busy writes, refresh, and repeated ⌘Z—not direct calls to `performUndo` alone.

### R5 — P2: Browser Undo can modify previously unchanged handlers instead of restoring the prior state

**Location:** `Short Circuit/Stores/KindStore.swift:568–581`; coupled expansion in `Short Circuit/Services/HandlerWriter.swift:59–68`.

The store reads all three browser targets but reduces their inverse to the prior HTTP app, discarding the prior HTTPS/HTML identities. That inverse is only faithful if the original role was uniform. It also ignores whether every follower actually changed.

**Simulated mixed-baseline reproduction:** before: HTTP=A, HTTPS=B, HTML=B; choose B for the role, so only HTTP changes value; Undo sets HTTP to A and consequently sets HTTPS and HTML to A too. Their original B values are lost. No target outside the browser role was reached, and I did not establish this mixed baseline with real setters; this is a demonstrated conditional inverse defect, not a claim that the current live role is mixed.

**Fix:** preserve the full before/after footprint and register a one-call browser inverse only when it can reproduce the original role. Otherwise identify the operation as not exactly undoable rather than promising restoration. Include partial-follow/partial-success browser cases in Undo tests; the present browser test starts with all followers already uniform.

### R6 — P3: The Mac pass reintroduced the unsupported “unused for files” claim

**Location:** `Short Circuit/Views/KindInspectorView.swift:106`.

The disclosure is now titled **“Not used for files”**, even though its member caption correctly says “Not the preferred type for any extension.” Extension governance does not prove that explicit-type consumers never use those identifiers. WAV and Word still have concrete shadowed-handler differences in the read-only lookup. **Fix:** title the group “Other declared types” or “Not preferred by extension.” This is the residual part of review-2 R4 below.

## Review-2 findings at HEAD

| Prior finding | Status | Evidence |
|---|---|---|
| R1: browser-role acceptance/results | **Fixed for normal entry points** | `KindCategory+Display.swift:109–137` uses HTTP acceptance for all role members; `KindStore.swift:649–652` deduplicates covered results. Replayed the captured inventory with live reads: ChatGPT supports the three-member role, makes one simulated HTTP call, and has unique results; Sublime supports XHTML only and makes no HTTP call. Undo has the separate R3 gap. |
| R2: all-shadowed fallback | **Fixed** | `Kind.swift:111–118` no longer substitutes settable members; Canon TIFF has zero effective members; `NoWholeTypeTargetTests` verifies zero whole-type calls while explicit member changes still work. |
| R3: Safari URL identity | **Fixed** | `AppIdentity.canonical` resolves symlinks and is shared by provider, acceptance, and writer. The live HTTP member now accepts `/Applications/Safari.app`; real/synthetic symlink tests and distinct-install tests pass. |
| R4: mismatch visibility/overclaim | **Partly fixed** | WAV/Word produce `shadowedMembersDiffer == true` and show “· differs”; FaceTime is included under Split via `mixedWithoutFixKinds`, without an impossible fix. The empty state is narrower. The new disclosure title regresses the wording constraint (R6). |
| R5: package adoption | **Fixed for the reported case** | `KindBuilder.swift:260–284` applies `shapeFits` to both adoption paths. `CatalogShapeTests.packagesAreNotAdoptedIntoFlatFileEntries` passes against the bundled JSON entry, retaining the legitimate flat alias and excluding the package. |

## Entry points and safety answers

- **Normal setters:** menu/context-menu actions call `setDefault` or `fixSplit`; inspector picker and app drops share those callbacks; Applications Apply uses `applyBatch`. Whole-type paths use `effectiveMembers`, then common eligibility; per-identifier paths use settable members, allowing explicit shadowed changes. All acquire the same activity gate before suspension. A double-activation simulation produced one call and maximum concurrency one.
- **Return/Space:** the brief overstates their write behavior. Grid Return shows the inspector; grid Space toggles it; a table primary action shows details; Applications Space changes inclusion checkboxes. None directly invokes a setter (`KindGridView.swift:89–96`, `KindBrowserView.swift:51–60`, `ApplicationsView.swift:259–265`). Activating an actual Open With/Apply button still passes the store gate. I did not run UI keyboard-repeat automation.
- **Undo concurrency:** actual restores cannot overlap another write or refresh once the activity gate is held. The asynchronous callback's stack-loss problem is R4. Successful whole-Kind/per-member/batch writes register only changed, previously assigned targets; no-default targets intentionally cannot be cleared by Undo.
- **Live snapshot mode:** `Short_CircuitApp.swift:17–18` injects `RefusingHandlerWriter`; Undo uses that same injected writer, never a separately constructed live backend. A refused normal change creates no Undo record; directly injecting a restore into the refusing store still fails without a setter. No bypass found.
- **Redo/loops:** no Redo is registered, intentionally documented in `Documentation/write-path.md:115`. `canRedo` stays false after a successful simulated Undo. I found no Undo→Redo registration loop or automatic repeated prompting. Failure/decline stops subsequent restores; failed and unattempted work is not retained for retry. No-Redo is a documented design choice, not an additional finding.
- **⌘R:** a successful refresh retains the existing UndoManager stack verbatim. It does not validate its targets, apps, or expected handlers. R1 and R3 therefore remain reachable after the user has explicitly refreshed.

## Restoration and tests

`KindStore.swift:170–181` safely ignores unknown saved layout/section identifiers. A valid remembered category with no remaining choices falls back to Common after load (`294–297`), covered by `RememberedStateTests`. Missing selected Kind IDs are cleared on refresh (`289–293`), and `selectedKind` only resolves visible rows. Kind/app selections themselves are **not persisted**, so there is no stale cross-launch selected-ID restoration to audit. Applications selection can become unresolved after removal, but `selectedApp == nil` prevents a batch plan.

`KindTableView.swift:22–45` whitelists known sort-column identifiers; a removed/unknown column decodes to an empty sort, preserving caller order. Malformed saved customization data is ignored with `try?`. Unknown-column customization behavior is delegated to SwiftUI; visual restoration, column placement, focus, VoiceOver, and window-frame restoration were not hand-tested. No source-level crash path was found for a removed sort column. Applications tables do not persist a sort order.

Frozen-source `xcodebuild test -only-testing:'Short CircuitTests'`, isolated DerivedData `.build/dd-codex-review-3`: **199 passed, 0 failed, 2 opt-in tests skipped** (201 total). Three AppIntents metadata-extraction warnings; no Swift compiler or reported runtime warnings. The independent harness compiled cleanly. Read-only regression checks used review-2's saved snapshot plus current UTType/NSWorkspace lookups, not a fresh dump.

The missing coverage is substantive: `UndoTests` uses fixed candidate lists, a uniform browser baseline, and `groupsByEvent = false`; it never exercises external changes, changed acceptance, refresh-invalidated history, or a busy **native UndoManager**. Its busy test calls `performUndo` directly, bypassing the pop that loses history. Other-app tests exercise request/cancel, not SwiftUI's successful dismissal ordering. Add transaction/precondition tests, actual-manager busy/partial-failure tests, and importer success-order tests; retain the passing concurrency and review-2 regression tests.

Evidence: `.build/reports/codex-review-3-artifacts/{source,source-manifest.json,ReviewHarness.swift,reproduce.sh,harness.log,live-enriched-kinds.json,xcodebuild.log,test-summary.json}`. All changes in the reproductions used simulated backends; live access was read-only. No consent prompts, real default changes, UI tests, commits, or git-state mutations. Solo MCP was unavailable; the required eight-line fallback is `.build/reports/codex-review-3.md`.

## Five things to fix first

1. Guard Undo with the recorded expected post-change state and reconcile stale history on Refresh (R1).
2. Preserve “Other…”'s pending target through successful sheet dismissal (R2).
3. Revalidate restored apps and targets through current eligibility, including HTTP browser eligibility (R3).
4. Keep busy/repeated Undo commands from consuming history without restoring anything (R4).
5. Register browser Undo only when its inverse can faithfully restore the full prior role (R5).
