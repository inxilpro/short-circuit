# Consent spike results

Run on 2026-09-18, macOS 26.6.2 (25G83), via `swift Documentation/spikes/consent-spike.swift`.

## Raw output

| Step | Call | Result |
|---|---|---|
| Before | — | `public.markdown` → Microsoft Word, `net.daringfireball.markdown` → Sublime Text |
| Test 1 | `NSWorkspace.setDefaultApplication(at: Mud, toOpen: public.markdown)` | **Error `NSCocoaErrorDomain` 256** ("The file couldn’t be opened"); handler unchanged |
| Test 1 | same, `net.daringfireball.markdown` | OK after **4.2 s**; handler changed to Mud |
| Test 2 | `LSSetDefaultRoleHandlerForContentType(public.markdown, .all, com.microsoft.Word)` | **OSStatus -50** (paramErr) |
| Test 2 | same, `net.daringfireball.markdown` → `com.sublimetext.4` | OSStatus 0, but handler **still Mud** on immediate re-read |
| Restore | `NSWorkspace` setter, `net.daringfireball.markdown` → Sublime Text | OK after 3.0 s; handler restored |

Final state matches the starting state.

## What this establishes

- **The error-256 bug reproduces**, and it is per-type rather than random: `public.markdown` failed through both the modern and the deprecated API (256 and -50), while `net.daringfireball.markdown` succeeded through the modern one. The deprecated API is therefore not a fallback for the failing case.
- **The async setter appears to wait for the user.** Successful calls took 3–4 s, which is human-response time, not API time. That contradicts the research note that the call returns before the user answers. Post-write re-reads are still worthwhile, but success/failure from the call itself looks meaningful.
- **The deprecated setter can report success without changing anything** (status 0, handler unchanged). Either it prompts asynchronously and the re-read raced it, or it is silently ignored on 26.6. Either way it is unreliable; the plan's decision to skip it stands.
- **A Kind can be partially applied.** Setting "Markdown" changed one member and failed on the other, so the write UX must report per-member results and leave the Kind marked split, rather than assume all-or-nothing.

## Prompts observed (reported by Chris)

Exactly two prompts appeared: one for `net.daringfireball.markdown` → Mud and one for the restore to Sublime Text. So:

- **One prompt per successful member change.** A Kind with N members costs up to N prompts.
- **The 256 failure on `public.markdown` showed no prompt.** It was rejected before consent, not declined by the user.
- **The deprecated LS setter never prompts.** Its status 0 with no change means it is silently ignored on 26.6, which settles it as unusable.

## Still unknown

- Whether `setDefaultApplication(at:toOpenFileAt:)` succeeds for a `.md` file where the `public.markdown` content-type call fails (plan milestone 0, fourth question). Not yet tested.

## Hypotheses for the `public.markdown` failure

1. The system-declared `public.markdown` type is treated differently from the third-party-declared `net.daringfireball.markdown`.
2. The current handler (Word) or the target (Mud) does not claim `public.markdown` directly, only by extension or conformance, and the setter rejects apps without a direct claim.
3. A stale or conflicting `handlerpref` record for the type.

The `dump-truth` ground-truth analysis lists which apps claim each Markdown UTI, which will confirm or rule out hypothesis 2.

## Update: hypothesis 2 ruled out

The independent dump analysis (`Documentation/spikes/dump-format.md`) shows Mud and Microsoft Word both claim `public.markdown` explicitly, and Mud and Xcode claim `net.daringfireball.markdown`. Mud was a direct claimant of the type whose change failed, so a missing direct claim is not the cause of error 256. Hypotheses 1 and 3 remain open.

## Hand test: browser role and XHTML (2026-09-18, macOS 26.6.2)

Chris set the Web browser Kind to Google Chrome and then back to Arc through the app. Each change showed one macOS prompt. `http`, `https` and `public.html` changed together both times. `public.xhtml` stayed on Sublime Text both times.

- The locked browser role on 26.6 is `http` + `https` + `public.html`. `public.xhtml` is not part of it and is set like any other type.
- Setting the role through the `http` scheme alone is enough to move all three.
- The `NSWorkspace` scheme setter worked from the app with a single consent prompt.

## Resolved: why `public.markdown` fails with 256

`UTType("public.markdown")` on this Mac has no supertypes. It is declared only by Word's imported declaration and conforms to neither `public.item` nor `public.data`. `.md` resolves to `net.daringfireball.markdown`, so no file is ever a `public.markdown`. macOS refuses to assign a handler to such a type, without prompting. The app now marks these members unsettable (`KindMember.isSettable`), leaves them out of split detection, and never calls the setter for them. Hypothesis 1 was close; hypotheses 2 and 3 are ruled out.

## Extension spike: defaults for extensions no declared type governs (2026-09-18 evening, macOS 26.6.2)

Run by Chris: `swift Documentation/spikes/extension-spike.swift`.

- `.markdown`, `.mdown` and `.mkd` each resolve to their own generated `dyn.` type. Before the test `.markdown` → Claude, `.mdown` and `.mkd` → Cursor, `.md` → Sublime Text.
- `setDefaultApplication(at: Cursor, toOpenFileAt: spike.markdown)` returned OK in **0.0 s**. Only `.markdown` changed (Claude → Cursor). `.md`, `.mdown`, `.mkd`, `.txt`, `net.daringfireball.markdown`, `public.plain-text`, `public.text` and `public.data` did not move.
- Restoring to Claude the same way also returned OK in 0.0 s, and every tracked handler matched the starting state.
- No new handler-pref record showed up in `lsregister -dump` for it (the script's filter looked for markdown/mdown/mkd and the `dyn.` identifiers). Where macOS stores the choice is unknown.
- The 0.0 s return suggests **no consent prompt appeared**; type-based changes took 3–4 s because they waited for one. Chris's typed notes were not captured, so this needs his confirmation.

Conclusion: setting a default through a file is isolated and reversible when the extension resolves to a `dyn.` type. It must not be used for an extension that resolves to a declared type, because that changes the declared type's handler (the reason the earlier fallback was removed).
