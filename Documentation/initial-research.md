# Building a Modern Replacement for SwiftDefaultApps: Technical Report & Build Plan

## TL;DR
- **SwiftDefaultApps is effectively unmaintained (last release v2.0.1, published 29 July 2019) and structurally obsolete**: it ships as a `.prefPane`, relies on three private/undocumented symbols pulled in via `@_silgen_name` (`_LSCopySchemesAndHandlerURLs`, `_LSCopyAllApplicationURLs`, `_UTCopyDeclaredTypeIdentifiers`) plus the now-deprecated Launch Services C API, and breaks in visible ways on Ventura and later (e.g. the pane dead-locks System Preferences so you must Force Quit, Issue #52/#61).
- **Build the replacement as a standalone, notarized, non-sandboxed SwiftUI app**, not a preference pane: use the modern macOS 12+ `NSWorkspace` read/write APIs (`urlsForApplications(toOpen:)`, `urlForApplication(toOpenContentType:)`, `setDefaultApplication(at:toOpen:)`, `setDefaultApplication(at:toOpenURLsWithScheme:)`) for everything that has a public equivalent, and fall back to `lsregister -dump` parsing for the one thing Apple still exposes no public API for — enumerating every UTI and URL scheme on the system.
- **Apple has partly absorbed this tool's job and partly walled it off**: changing the default browser (the shared http/https/html role) has required a mandatory, un-bypassable consent dialog for years, and per Armin Briegel (scriptingosx), macOS 26.4 (released March 2026) extends that confirmation to *every* file-type change. A sandboxed Mac App Store build essentially cannot change handlers, so plan for Developer ID distribution.

## Key Findings

1. **The original app's architecture is the core problem, not just its age.** SwiftDefaultApps is a System Preferences pane (`SwiftDefaultApps.prefPane`) plus a CLI (`swda`) and a "ThisAppDoesNothing.app" dummy handler. Its Launch Services wrapper (`LSWrappers.swift`, 486 lines) is built on the Launch Services C API (`LSSetDefaultRoleHandlerForContentType`, `LSSetDefaultHandlerForURLScheme`, `LSCopyDefaultRoleHandlerForContentType`, etc.) — all of which Apple deprecated in macOS 12.0 — and, crucially, on three **private, undocumented** symbols bound with Swift's `@_silgen_name`: `_LSCopySchemesAndHandlerURLs`, `_LSCopyAllApplicationURLs`, and `_UTCopyDeclaredTypeIdentifiers`. These private symbols are how it enumerates every URL scheme, every application, and every declared UTI — capabilities that still have no public API.

2. **It is broken or degraded on modern macOS.** Documented issues include: the pane deadlocking System Preferences on Monterey/Ventura — Issue #52 (macOS 12.0.1) states "as soon as you flip to one of the other tab groups e.g. URI Schemes, the close button greys out and you can no longer quit System Prefs… The only option at that point is to Force Quit"; the "OK" button being unresponsive on Ventura (Issue #61); "Do Nothing" registration failing (Issue #12); code-signature/notarization rejection of the CLI (`swda`, Issue #59); and no Apple-Silicon-native testing/build from the maintainer (a community arm64 build exists as a separate repo, Timer00/swift-default-apps-silicon-build). The maintainer posted a README announcement that Apple "introduced replacements for the deprecated APIs" and that development would resume, but there has been no new release since v2.0.1 (published 29 July 2019, which fixed a CLI crash "when displaying the results for setHandler with shortcuts such as internet, browser, email, etc.").

3. **Most read/write operations now have clean, public NSWorkspace replacements (macOS 12+).** Reading handlers: `urlForApplication(toOpenContentType:)`, `urlsForApplications(toOpen:)` (all apps for a type), `urlForApplication(toOpen: URL)`. Writing handlers: `setDefaultApplication(at:toOpen: UTType)`, `setDefaultApplication(at:toOpenURLsWithScheme:)`, `setDefaultApplication(at:toOpenFileAt:)`. These supersede the deprecated `LSCopy*`/`LSSet*` functions one-for-one.

4. **The consent model is the single biggest behavioral change.** Changing the default web browser (http/https/html, which macOS treats as one shared role) triggers a mandatory OS-level confirmation dialog the app cannot suppress. Other URL schemes and file types were historically silent. Per Armin Briegel's 26 March 2026 post "macOS 26.4 brings more default app confirmation prompts": "The 26.4 updates have been released and among the many documented changes, there is one that the Apple documentation team seems to have missed… Changing the default app to open any file type will prompt for user confirmation." This erodes the "browser prompts, everything else is silent" rule that held from macOS 12 through early 26.

5. **Apple has shipped its own (limited) default-apps UI, reducing but not eliminating the tool's value.** The default web browser lives in System Settings ▸ Desktop & Dock; there is no first-party UI for arbitrary UTIs or arbitrary URL schemes. Notably, in macOS 26 Tahoe the ability to change the `tel:` handler disappeared from FaceTime settings with no replacement UI (Apple DTS confirmed it as bug-worthy, FB20321931). This is exactly the gap a third-party utility fills.

6. **`.prefPane` bundles still load in macOS 15/26, but they are a dead end.** Howard Oakley (Eclectic Light Company, 11 Oct 2022) confirms: "macOS Ventura still has Preference Panes that work essentially the same as they did in Monterey… They're still written around NSPreferencePane, which doesn't appear to have changed significantly since Mac OS X 10.1. Disappointingly, creating a new Preference Pane project in Xcode still doesn't make any provision for the use of Swift." A standalone SwiftUI app is the correct modern target.

## Details

### PART 1 — What SwiftDefaultApps does and how

The app (v2.0.1, 2019) presents four tabs matching RCDefaultApp's model:

- **Internet tab** — Convenience shortcuts for the common roles: default web browser (http/https + HTML documents), default email client (mailto), plus news/RSS/FTP-type roles. Under the hood these are just specific URL schemes and content types funneled through the same Launch Services calls.
- **URI Schemes tab** — Lists every registered URL scheme on the system (via the private `_LSCopySchemesAndHandlerURLs`), shows the current handler, and lets you pick a new handler from all valid apps for that scheme (`LSCopyAllHandlersForURLScheme`), plus "Do Nothing" and "Other…". Also allows adding a custom scheme.
- **Uniform Type Identifiers tab** — Lists every declared UTI (via the private `_UTCopyDeclaredTypeIdentifiers`), shows description/handlers, and lets you assign a handler per Launch Services **role** (Viewer, Editor, Shell, All — `LSRolesMask`). Handler candidate lists come from `LSCopyAllRoleHandlersForContentType`.
- **Applications tab** — Lists all applications (via the private `_LSCopyAllApplicationURLs`) and lets you set, for a chosen app, all the types/schemes it can handle — the "make this app the default for everything it can open" workflow.

**Mechanisms it depends on:**
- Launch Services C API (`LSSetDefaultRoleHandlerForContentType`, `LSSetDefaultHandlerForURLScheme`, `LSCopyDefaultRoleHandlerForContentType`, `LSCopyAllRoleHandlersForContentType`, `LSCopyDefaultHandlerForURLScheme`, `LSCopyDefaultApplicationURLForContentType`, `LSRolesMask`), all deprecated in macOS 12.
- **Private symbols via `@_silgen_name`**: `_LSCopySchemesAndHandlerURLs`, `_LSCopyAllApplicationURLs`, `_UTCopyDeclaredTypeIdentifiers`.
- Reading Info.plist `CFBundleURLTypes` / `CFBundleURLSchemes` / `CFBundleDocumentTypes` from candidate apps to get display names.
- The `LSHandlers` / `LSHandlerPreferredVersions` records ultimately live in `~/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist`.

### PART 2 — Current state of Apple's APIs (2025/2026)

**UniformTypeIdentifiers (UTType, macOS 11+).** `UTType` cleanly replaces the old `UTTypeCopyDeclaration` / `UTTypeCopyPreferredTagWithClass` / MobileCoreServices calls: `.preferredFilenameExtension`, `.preferredMIMEType`, `.localizedDescription`, `.identifier`, `.supertypes`/`.conforms(to:)` for the conformance tree, and `UTType(filenameExtension:)` / `UTType(mimeType:)` for lookups. **Critical limitation confirmed: there is NO public API to enumerate all UTIs declared on a system.** `UTType.types(tag:tagClass:conformingTo:)` is only a per-tag reverse lookup — you must already know the extension or MIME type; it returns matching declared types (or a generated dynamic type if none). To get the full list you must use the legacy/private `UTCopyDeclaredTypeIdentifiers` or parse `lsregister -dump` (the canonical shell idiom is `lsregister -dump | grep 'uti:' | cut … | sort | uniq`).

**NSWorkspace additions (macOS 12+).** Read: `urlForApplication(toOpenContentType:)`, `urlsForApplications(toOpen:)`, `urlForApplication(toOpen:)` (for a file URL), `urlsForApplications(withBundleIdentifier:)`. Write: `setDefaultApplication(at:toOpen:)` (content type), `setDefaultApplication(at:toOpenURLsWithScheme:)`, `setDefaultApplication(at:toOpenFileAt:)`, each with a completion handler taking an `NSError?`. There is a known, still-open bug (Apple forum thread 731555) where `setDefaultApplication(at:toOpen:)` returns a Cocoa error 256 / `permErr -54` in some configurations even though `setDefaultApplication(at:toOpenFileAt:)` works — DTS asked for a Feedback filing, meaning this path is not fully reliable yet.

**Deprecation status of the Launch Services C surface.** `LSSetDefaultRoleHandlerForContentType`, `LSSetDefaultHandlerForURLScheme`, `LSCopyDefaultRoleHandlerForContentType`, `LSCopyAllRoleHandlersForContentType`, `LSCopyDefaultHandlerForURLScheme`, and `LSCopyDefaultApplicationURLForContentType` are all annotated `API_DEPRECATED(..., macos(10.4, 12.0))` (10.10→12.0 for the URL-for-content-type copy). They **still function** on macOS 15/26 — Apple DTS engineer Quinn ("The Eskimo") advises in Developer Forums thread 741305: "1. File an enhancement request for an API that covers the missing functionality… 2. Continue using the LS API in the interim." So: deprecated, warning-generating, but not removed.

**Consent / approval prompts (Sequoia + Tahoe).** The default-browser change (shared http/https/html role) shows a mandatory system dialog and cannot be bypassed programmatically; the call returns immediately, before the user answers, so you cannot directly read the user's choice. http/https/public.html are locked to a single handler — you set it via the `http` scheme; setting `https` or `public.html` independently errors. Other schemes/types were silent through macOS 15 and early 26; per Armin Briegel, macOS 26.4 extends the confirmation prompt to every file-type/UTI change.

**Sandboxing / entitlements / TCC.** A sandboxed Mac App Store app essentially cannot set default handlers. Quinn ("The Eskimo," Developer Forums thread 769441) states: "There is no recommended replacement for LSSetDefaultHandlerForURLScheme… In some cases this functionality is no longer available to your app [1]… [1] Specifically, for apps on the Mac App Store, where such requests are blocked by the App Sandbox." Direct manipulation of `com.apple.launchservices.secure.plist` is not a supported path (it is user-domain, not SIP-protected, but LaunchServices actively overwrites/validates it and will fight you). Therefore the replacement must be **non-sandboxed, Developer ID-signed, hardened-runtime, notarized**.

**Preference pane state.** `.prefPane`/`NSPreferencePane` still load in macOS 15/26 but are legacy (no Swift template, constrained sizing, Objective-C bridging). Opening a specific System Settings pane by file path broke in macOS 13/14; the supported route is the `x-apple.systempreferences:` URL scheme (e.g., `x-apple.systempreferences:com.apple.Profiles-Settings.extension`).

**Public tooling to learn from.** `lsregister` (at `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister`) with `-dump` is the de-facto way to enumerate UTIs and inspect the LS database; it is undocumented (no man page). `duti` (public-domain CLI, relies on the deprecated C API), `dooti`, `dutix`, and scriptingosx's `utiluti` (which documents the modern prompt behavior) are all worth studying. Jeff Johnson's open-source "Default web browser", PrivateWindow, and his deep-dive on the LaunchServices default-browser bug document undocumented fallback behavior (stale records, `/Applications` preference, bundle-version pinning, and the need for `lsregister -f -u` to clear a stuck record).

### PART 3 — Recommended build plan

1. **Target & distribution.** Standalone SwiftUI app, minimum deployment macOS 12 (to get the NSWorkspace APIs); ideally macOS 13+ to sidestep older LS quirks. **Non-sandboxed, Developer ID, hardened runtime, notarized.** Universal binary (arm64 + x86_64). Do not pursue the Mac App Store — sandbox blocks the core feature.
2. **Enumerate types & schemes.** For UTIs and URL schemes, shell out to `lsregister -dump` and parse (cache the result; it is slow). Cross-reference each parsed UTI with a live `UTType(identifier:)` to fetch description, preferred extension, MIME type, and conformance. This avoids the three private `@_silgen_name` symbols entirely. Provide a manual refresh.
3. **Read current handlers.** Use `urlForApplication(toOpenContentType:)` (default) and `urlsForApplications(toOpen:)` (candidate list) for UTIs; for URL schemes, construct a probe URL and use `urlForApplication(toOpen:)`, or read the `LSHandlers` array from `com.apple.launchservices.secure.plist` for display only.
4. **Set handlers.** Use `setDefaultApplication(at:toOpen:)` for content types and `setDefaultApplication(at:toOpenURLsWithScheme:)` for schemes. Surface the completion-handler `NSError` to the user. Expect and design around the mandatory browser prompt, and (on 26.4+) a prompt for every change.
5. **Consent UX.** Detect the browser/mail special cases and warn the user a system dialog will appear. Because the API returns before the user answers, re-read the handler after a short delay to reflect the actual result rather than assuming success.

### PART 4 — Known hard problems / open questions

- **Enumerating all system UTIs without private API**: no public solution; `lsregister -dump` parsing is the only robust route. Risk: output format is undocumented and can change.
- **Complete URL-scheme list**: same problem — Apple exposes no public enumeration; `lsregister -dump` (scheme entries) or reading the LS secure plist are the options.
- **Per-role Viewer/Editor/Shell distinction**: the old `LSRolesMask` supported this; the public `NSWorkspace` API does **not** expose roles — it sets/reads the "all" role only. If per-role fidelity matters, you must keep the deprecated `LSSetDefaultRoleHandlerForContentType`/`LSCopyDefaultRoleHandlerForContentType` (still functional, warning-generating) as a fallback.
- **Bulk/batch "set all types this app can open"**: no single API; iterate the app's declared `CFBundleDocumentTypes`/`CFBundleURLTypes` and call the per-type setter in a loop — which on 26.4+ may produce one consent prompt per type.
- **http/https/html coupling and the browser fallback bug**: setting the browser is special-cased and, per Jeff Johnson, LaunchServices can get "stuck" on stale records (requiring `lsregister -f -u`).

### PART 5 — Distribution considerations
- **Sandbox**: incompatible with the core feature; do not sandbox.
- **Mac App Store**: not viable.
- **Notarization + hardened runtime**: required for Gatekeeper on modern macOS; the original project already hit signing/notarization rejections (Issue #59), so budget time for it.
- **Entitlements**: as a non-sandboxed Developer ID app, few or none are needed for the LS/NSWorkspace calls; you may need `com.apple.security.automation.apple-events` only if you script other apps.

### PART 6 — API mapping table

| Old (deprecated/private) | Modern replacement | Availability | Notes |
|---|---|---|---|
| `LSCopyDefaultRoleHandlerForContentType` | `NSWorkspace.urlForApplication(toOpenContentType:)` | macOS 12+ | Returns app URL; no role granularity |
| `LSCopyAllRoleHandlersForContentType` | `NSWorkspace.urlsForApplications(toOpen:)` | macOS 12+ | Candidate list |
| `LSSetDefaultRoleHandlerForContentType` | `NSWorkspace.setDefaultApplication(at:toOpen:)` | macOS 12+ | Completion returns NSError; loses `LSRolesMask` |
| `LSCopyDefaultHandlerForURLScheme` | `NSWorkspace.urlForApplication(toOpen: URL)` | macOS 12+ | Use a probe URL |
| `LSSetDefaultHandlerForURLScheme` | `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` | macOS 12+ | Browser scheme → mandatory prompt |
| `LSCopyDefaultApplicationURLForContentType` | `NSWorkspace.urlForApplication(toOpenContentType:)` | macOS 12+ (dep. 10.10→12.0) | — |
| `LSCopyAllHandlersForURLScheme` | `NSWorkspace.urlsForApplications(toOpen: probeURL)` | macOS 12+ | — |
| `UTTypeCopyDeclaration` / `UTTypeCopyPreferredTagWithClass` | `UTType` properties (`.preferredFilenameExtension`, `.preferredMIMEType`, `.localizedDescription`, `.conforms(to:)`) | macOS 11+ | — |
| `_UTCopyDeclaredTypeIdentifiers` (private) | *No public API* → parse `lsregister -dump` | — | Hard problem |
| `_LSCopySchemesAndHandlerURLs` (private) | *No public API* → parse `lsregister -dump` | — | Hard problem |
| `_LSCopyAllApplicationURLs` (private) | *No public API* → parse `lsregister -dump` or scan `/Applications` | — | — |

## Recommendations

1. **Prototype the hard part first (week 1):** write and validate the `lsregister -dump` parser for UTIs and URL schemes, since everything else depends on it and it is the only unsupported-format risk. Benchmark parse time and cache.
2. **Build the read path (week 2):** wire `UTType` metadata + `NSWorkspace` read APIs into a SwiftUI list matching the four original tabs. Ship a read-only "inspector" build early — it is useful and risk-free.
3. **Add the write path (week 3):** implement per-type/per-scheme setting via `NSWorkspace`, with explicit consent-prompt handling and post-write re-reads. Keep deprecated `LS*` role functions behind a "per-role (advanced)" toggle for Viewer/Editor fidelity.
4. **Distribution (week 4):** Developer ID sign + hardened runtime + notarize a universal binary. Test on macOS 13, 14, 15, and 26 (including 26.4 for the new per-change prompt).
5. **Decision thresholds:** If Apple removes the deprecated `LS*` symbols in a future SDK, drop the per-role feature. If `lsregister -dump` output format changes, gate enumeration behind a version check. If the macOS 26.4 per-change prompt proves too disruptive for batch operations, redesign "set all types" to a single reviewed confirmation list rather than a loop.

## Caveats
- **The macOS 26.4 "prompt on every change" behavior is documented by Armin Briegel (scriptingosx)** who notes "the Apple documentation team seems to have missed" it; it is not yet in Apple's own docs, so verify on-device before relying on it.
- **The "mailto requires a mandatory dialog" premise is not clearly documented** as distinct from other silent URL schemes prior to 26.4; primary sources single out only http/https/html for the special browser dialog.
- Private `@_silgen_name` symbols can be removed by Apple at any OS update without notice; do not reintroduce them.
- The `setDefaultApplication(at:toOpen:)` permission-error bug (forum 731555) means the content-type setter is not 100% reliable across configurations; test thoroughly.
- Issue/PR numbers cited are from the SwiftDefaultApps repo; the newest open issue at time of writing is #93 (opened 11 June 2026), and the repository now shows "Issue creation is restricted in this repository." Confirm the current open-issue count on-device.