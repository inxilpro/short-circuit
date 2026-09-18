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
