# Write path

How Short Circuit changes default apps, and which parts have been checked on a real system.

## Flow

1. The inspector calls `KindStore.setDefault(_:for:)`, `setDefault(_:for:in:)` (one member), or `fixSplit(_:)`.
2. `HandlerWriting.plan(app:targets:)` builds a `WritePlan` from **live** handler reads, not from the displayed Kind. Each plan step is one setter call, and at most one consent prompt.
3. The store asks for confirmation when the plan has more than one step **or** touches the browser role. The confirmation lists every step in the plan. A plan with no steps makes no calls; the store re-reads the handlers so the display matches the system.
4. `HandlerWriting.execute(_:)` gets the **same plan** the user approved. It re-plans from live reads first:
   - If the fresh plan fits inside the approved one (the same calls or fewer), it runs the fresh plan. Members that became correct in the meantime are reported as skipped.
   - If the fresh plan would make any call the approved plan didn't include, nothing runs. The store shows the fresh plan in a new confirmation, marked as revised.
5. Calls run **one at a time**:
   - UTIs use `NSWorkspace.setDefaultApplication(at:toOpen:)`.
   - Schemes use `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)`.
   - After each call, the writer re-reads every covered target, retrying briefly. Each target is reported as `changed`, `unchangedAfterSuccess` (the user probably declined), `declined` (NSUserCancelledError), `failed`, or `skipped`.
6. The store re-reads every requested and affected target and patches those handlers, by target, into every loaded Kind that contains them.

## Browser role

`http`, `https`, `public.html`, and `public.xhtml` are treated as one "default browser" setting:

- Any request that includes one of them, including a per-member request from the ⋯ menu, becomes a single `http` call. That step covers all four targets.
- The call is always confirmed first, and the confirmation names all four targets.
- The inspector says this up front for any Kind that contains these targets.
- Browser-member menus are labeled "Default Browser" and their items read "Make X the Default Browser".

**Unverified:** whether `public.xhtml` actually follows the `http` call. Live data on the dev Mac has `public.xhtml` on Sublime Text while the other three are on Arc. The writer never assumes the coupling: each covered target's result comes from a live re-read, so an XHTML that doesn't follow shows as "Not changed".

## Error 256

Some types, such as `public.markdown` on macOS 26.6, make the content-type setter fail with `NSCocoaErrorDomain` 256 and no prompt. That member is reported as failed: "macOS rejected changing the default app for this type without asking. Nothing was changed."

There is **no automatic fallback**. An earlier version retried through `setDefaultApplication(at:toOpenFileAt:)` with a `sample.<ext>` file. It was removed because a sample `.md` file resolves to `net.daringfireball.markdown`, not `public.markdown`, so the retry could have changed a type the user never approved. Any future experiment with that API needs a hands-on test and must include the file's resolved type in the confirmed plan.

## Concurrency and refresh

- One write is in flight app-wide at a time. `KindStore.activity` covers planning, applying, and a pending confirmation, and all set actions are disabled meanwhile.
- A refresh can't start during a write, and a write can't start during a refresh.
- A refresh keeps the per-member results of earlier writes.
- If a write were ever to complete during a refresh, the verified post-write handlers are laid over the refreshed Kinds.

## Test doubles

- `SimulatedHandlerBackend` (in `Stores/`) is an in-memory Launch Services. It is used in previews, in the `SC_SNAPSHOT_DIR` snapshot run, and in `KindStoreWriteTests`.
  - Which targets follow an `http` call is a constructor parameter, because the real coupling is not fully known.
  - It can change handlers "externally" to simulate stale plans.
- `RefusingHandlerWriter` plans from real reads but never writes; the live read-only snapshot mode uses it.
- `WorkspaceHandlerBackend` is the only type that calls the real setters.
