# Write path

How Short Circuit changes default apps, and which parts have been checked on a real system.

## Flow

1. The inspector calls `KindStore.setDefault(_:for:)`, `setDefault(_:for:in:)` (one member), or `fixSplit(_:)`.
2. The store builds a `WritePlan` from the handlers it knows about. Each plan step costs at most one consent prompt. If a plan has more than one step, the store asks for confirmation first ("macOS will ask you to confirm each of N changes").
3. `HandlerWriter.apply(app:to:)` re-reads the live handlers, rebuilds the plan, and runs the steps **one at a time**:
   - UTIs: `NSWorkspace.setDefaultApplication(at:toOpen:)`
   - Schemes: `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`
   - `http`, `https`, `public.html`, and `public.xhtml` form one locked browser role. The writer sets it once, through `http`, and reports the others as following it.
   - After each call, the writer re-reads the handler, retrying briefly, and classifies the member as `changed`, `unchangedAfterSuccess` (the user probably declined), `declined` (NSUserCancelledError), `failed`, or `skipped`.
4. Once apply finishes, the store re-reads every member of the Kind from the system, so split status reflects what actually happened.

The deprecated `LSSet*` functions are not used; the spike showed that macOS 26.6 silently ignores them.

## UNTESTED: the error-256 file fallback

When a UTI's setter fails with `NSCocoaErrorDomain` 256 (seen for `public.markdown`), the writer writes an empty temporary file named `sample.<preferred extension>` and calls `NSWorkspace.setDefaultApplication(at:toOpenFileAt:)`. The member result records `usedFileFallback`.

This path has **never run against the real system**. It is unknown whether it:

- prompts at all, or prompts once,
- changes the handler for the failing UTI or for whichever UTI Launch Services assigns to the extension (for `.md` that could be `net.daringfireball.markdown`),
- succeeds where the content-type call failed.

The re-read after the call decides what the UI reports, so a wrong guess shows up as "failed" or "not changed" rather than a false success.

## Test doubles

`SimulatedHandlerBackend` (in `Stores/`) is an in-memory Launch Services. It is used in previews, in the `SC_SNAPSHOT_DIR` snapshot run, and in `KindStoreWriteTests`. `WorkspaceHandlerBackend` is the only type that calls the real setters.
