# Write path

How Short Circuit changes default apps, and which parts have been checked on a real system.

## Flow

1. The inspector calls `KindStore.setDefault(_:for:)`, `setDefault(_:for:in:)` (one member), or `fixSplit(_:)`. Unsettable members (types macOS refuses to assign, such as `public.markdown` on the dev Mac) are never requested.
2. The change applies **immediately**; there is no app-level confirmation (see below). `HandlerWriting.apply(app:targets:onProgress:)` builds a `WritePlan` from **live** handler reads, not from the displayed Kind, and runs that plan straight away. Each plan step is one setter call and one macOS consent prompt. Members already on the chosen app are reported as skipped. If every member is already correct, no call is made and the store says so.
3. Calls run **one at a time**:
   - UTIs use `NSWorkspace.setDefaultApplication(at:toOpen:)`.
   - Schemes use `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`.
   - Before each call, the writer reports `WriteProgress` (step N of M and the call). The inspector shows "Waiting for macOS… change 1 of 2" with the type involved, so a run of system prompts is explained as it happens.
   - After each call, the writer re-reads every covered target, retrying briefly. Each target is reported as `changed`, `unchangedAfterSuccess` (the user probably declined), `declined` (NSUserCancelledError), `failed`, or `skipped`.
4. The store re-reads every requested and affected target and patches those handlers, by target, into every loaded Kind that contains them.

## Why there is no confirmation dialog

Earlier versions asked "macOS will ask you to confirm each of N changes" before applying. Chris removed it (2026-09-18): macOS already asks the user to confirm every single handler change, so nothing can change without that system consent, and the app's own dialog only doubled the questions.

The dialog also carried risk of its own: a SwiftUI ordering bug once made Continue apply nothing. With it gone, the approve/re-approve machinery went too. That included the check that re-asked when a plan grew between the dialog and execution. Planning now happens immediately before execution, so there is nothing stale to re-approve.

## Browser role

`http`, `https`, and `public.html` form one "default browser" setting:

- Any request that includes one of them, including a per-member request from the globe menu, becomes a single `http` call. That step covers all three.
- The inspector says up front, for any Kind that contains these targets, that changing them changes the default browser. While the call runs, the progress line names it "Default browser (http, https, and HTML files)".
- Browser-member menus are labeled "Default Browser" and their items read "Make X the Default Browser".

**Measured by hand on 2026-09-18, macOS 26.6.2 (Chris):**

- Web browser → Chrome, then → Arc, one consent prompt each time.
- `http`, `https`, and `public.html` changed every time. `public.xhtml` stayed on Sublime Text.

So `public.xhtml` is **not** part of the browser role. It is an ordinary type with its own setter call and its own prompt:

- Setting the whole Web page Kind, or fixing its split, plans the browser call plus a separate XHTML call when XHTML differs: two prompts, shown as "change 1 of 2" and "change 2 of 2".
- The ⋯ menu on `public.xhtml` is a plain single-member action.

Every covered target's result still comes from a live re-read, so if a browser target ever fails to follow, it is reported as "Not changed" rather than assumed.

The same hand test confirmed that the (since removed) confirmation dialog's Continue button applied the change in the real app.

## Effective and shadowed members

Several types can declare the same extension, but macOS resolves each extension to one type, and only that type's handler decides what opens the file. `KindMember.governedExtensions` records which extensions a member wins. A member is **effective** if it is a URL scheme or wins at least one extension. A settable member that wins nothing is **shadowed**.

**Planning:**
- Whole-Kind changes and Fix Split target effective members only. That means fewer prompts and no changes nobody would notice.
- A shadowed member changes only through its own ⋯ menu.
- Progress and result counts follow the effective members.

**Split and Fix Split:**
- A Kind is split only when its effective members differ **and** some app could unify them (`Kind.unifyingCandidates`, the apps every effective member accepts).
- Fix Split chooses from those, preferring the app most effective members already use, so it always fits every effective member.
- If effective members differ but no app fits them all (for example `facetime:` and `facetime-audio:` on the dev Mac), the Kind shows "Mixed" with a neutral note. It gets no ⚠ and no Fix Split button, and it is not counted in the Split badge. The Split view still lists it, under a second heading, "Differ, no single app fits", so the mismatch stays visible (Codex review 2, R4).
- The Split list is fixed at load or explicit refresh; Kinds that become split during the session are added. **Resolved** (green check) marks only Kinds that were split when the session began and whose effective members now all agree. When nothing fixable remains, the empty state reads "No Fixable Splits".

**Inspector:**
- Effective members come first, each with chips for the extensions it governs.
- Shadowed members sit dimmed in a collapsed "Other declared types (N)" disclosure, captioned "Not the preferred type for any extension on this Mac." That is the narrower fact the extension lookup proves; an explicit-type lookup can still reach them. When any of them points to a different app than the effective members, the collapsed label adds a quiet "· differs".
- Extensions no member wins are noted under Extensions as handled by a type outside the Kind.

## Browser-role eligibility

A request touching `http`, `https`, or `public.html` becomes one `http` call. So whether an app can take any of those members is decided by whether the **`http` member** accepts it; `https` and `public.html` follow (`Kind.canSet(_:to:)`). This was Codex review 2, R1.

Every surface uses the same rule through `Kind.eligibility(of:for:)`:
- the store's single and batch changes
- the Applications batch count
- the picker's "N of M types" note
- per-member menus (the HTML row's globe menu offers only apps the `http` call accepts)
- Fix Split

Results have exactly one row per target (`KindStore.finalResults`). A target covered by a performed step is never also listed as not supported.

Examples, from the dev Mac's asymmetric lists:
- **ChatGPT**, listed for http and https only: it takes the browser role, so html follows, and XHTML is not supported. That's "3 of 4 types", one call.
- **Sublime Text**, listed for HTML and XHTML only: it is never offered as the default browser. Only XHTML changes: "1 of 4 types", one call.

## Per-member candidates

macOS only accepts an app it lists for that exact type. Setting any other app fails with `NSCocoaErrorDomain` 256 and no prompt.

**How it was found (2026-09-18):**
- Chris's hand test set MHTML to Google Chrome, and it failed with 256 on `com.microsoft.word.mhtml`.
- The orchestrator's probe showed that `urlsForApplications(toOpen: com.microsoft.word.mhtml)` lists only Word and Chromium. Chrome was a candidate for the Kind only through the other member, `org.ietf.mhtml`.
- A Kind's candidates are the union of its members' lists, so not every candidate fits every member.

**The rule:**
- `KindMember.candidateURLs` holds the apps macOS lists for that member. Nil means unknown, and places no restriction.
- **Planning:** members that don't accept the chosen app make no setter call. They are reported as a neutral "X can't open this type" row, and counted separately in the summary ("1 changed · 1 not supported"). If their app differs, the Kind honestly stays split.
- **Fix Split:** picks the current app that the most settable members can take. Ties go to the app more members already use. If some members can't take it, the button reads "Use X Where Possible" and names the members that will stay.
- **Menus:** the per-member ⋯ menu lists only that member's candidates, plus "Other…". The Kind-level picker marks partially supported apps with a quiet note such as "1 of 2 types".
- **"Other…":** a sheet on the window (`.fileImporter`) that starts in the last folder used. Dropping an app from Finder on Opens With or on one identifier row takes the same path. An app picked there can still reach the setter on a member whose candidates are unknown. A 256 then reads "macOS rejected this app for this type without asking. It only allows apps that declare support for the type."



Some types, such as `public.markdown` on macOS 26.6, make the content-type setter fail with `NSCocoaErrorDomain` 256 and no prompt. That member is reported as failed: "macOS rejected changing the default app for this type without asking. Nothing was changed."

There is **no automatic fallback**. An earlier version retried through `setDefaultApplication(at:toOpenFileAt:)` with a `sample.<ext>` file. It was removed because a sample `.md` file resolves to `net.daringfireball.markdown`, not `public.markdown`, so the retry could have changed a type the user never approved. Any future experiment with that API needs a hands-on test and must account for the file's resolved type in the plan.

## Undo

Every change registers one undo group with the window's `UndoManager`: a whole type, one identifier, Fix Split, an app chosen with Other… or dropped on the inspector, and an Applications batch. Edit reads “Undo Set Default App for “Markdown”” or “Undo Make Photos the Default for 3 Types”.

- **What it restores:**
  - Before a change, the store reads the live handler of every target it will touch, and the whole browser role if any browser target is involved.
  - Undo puts back the previous app of each target whose result was `changed`.
  - Targets that had no default are left out, because there is no "no default" to set.
- **How:** through the same writer, one target per call.
  - macOS asks again for every restore, and the status line says so when the undo starts.
  - The browser role goes back as a single `http` call with `http`'s previous app. https and HTML follow it.
- **Stopping:** a declined or failed restore stops the rest. The persistent banner says how many weren't attempted, and per-type results show in the inspector.
- **No Redo:** whether a restore worked is only known after its prompt, so a Redo registered in advance could claim a change macOS refused.
- **Busy:** undo runs under the same app-wide gate. If another change is in progress it does nothing and says so.
- **Scope:** undo lasts for the session only.

Tests: `UndoTests` (simulated backend).

## Concurrency and refresh

- One write is in flight app-wide at a time. `KindStore.activity` covers the whole apply, including its live planning reads, and all set actions are disabled meanwhile.
- A refresh can't start during a write, and a write can't start during a refresh.
- A refresh keeps the per-member results of earlier writes.
- If a write were ever to complete during a refresh, the verified post-write handlers are laid over the refreshed Kinds.

## Test doubles

- `SimulatedHandlerBackend` (in `Stores/`) is an in-memory Launch Services. It is used in previews, in the `SC_SNAPSHOT_DIR` snapshot run, and in `KindStoreWriteTests`.
  - Which targets follow an `http` call is a constructor parameter, because the real coupling is not fully known.
  - It can change handlers "externally" to simulate stale plans.
- `RefusingHandlerWriter` plans from real reads but never writes; the live read-only snapshot mode uses it.
- `WorkspaceHandlerBackend` is the only type that calls the real setters.
