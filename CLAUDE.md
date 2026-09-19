# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and test

One Xcode project, one SwiftUI app target, one unit-test target. Build and run the unit tests with
your own DerivedData so parallel agents don't collide:

```sh
xcodebuild build -project "Short Circuit.xcodeproj" -scheme "Short Circuit" \
  -destination 'platform=macOS' -derivedDataPath .build/dd-<your-name>

xcodebuild test -project "Short Circuit.xcodeproj" -scheme "Short Circuit" \
  -destination 'platform=macOS' -derivedDataPath .build/dd-<your-name> \
  -only-testing:"Short CircuitTests"                              # what CI runs
xcodebuild test ... -only-testing:"Short CircuitTests/CatalogTests"   # one suite
```

The space in the scheme, target, and paths is real; quote everything. The Swift module is
`Short_Circuit` (`@testable import Short_Circuit`). Tests use swift-testing (`@Suite`/`@Test`/`#expect`),
not XCTest. `Short CircuitUITests` exists but is out of scope for automation; don't run it.

CI (`.github/workflows/ci.yml`) builds Release unsigned and runs `Short CircuitTests` on GitHub's
`xcode-27` image. The project file is in Xcode 27 format, so older Xcodes can't open it.

### Env-gated modes

Unit tests normally run offline against trimmed fixture dumps in `Short CircuitTests/Fixtures/`
(`Fixture.snapshot("markdown.lsdump")`, `Fixture.offlineBuilder`). Build on those rather than on this
Mac's Launch Services database. Two suites read the real machine and are off unless opted in.
xcodebuild only forwards variables prefixed with `TEST_RUNNER_`, and strips the prefix:

- `TEST_RUNNER_SHORT_CIRCUIT_LIVE=1` (or an absolute path, to write the report there) runs
  `LivePipelineDebugTests`: the real dump → parse → Kinds pipeline, with printed counts.
- `TEST_RUNNER_SHORT_CIRCUIT_EXPORT=/abs/path.json` writes a Launch Services snapshot export.

The Debug app has two screenshot modes (`Views/DebugSnapshotter.swift`), because agents have no Screen
Recording permission for `screencapture`. Launch the built binary directly:

```sh
SC_SNAPSHOT_DIR=/tmp/sc-shots ".build/dd-<name>/Build/Products/Debug/Short Circuit.app/Contents/MacOS/Short Circuit"
SC_SNAPSHOT_DIR=/tmp/sc-shots SC_SNAPSHOT_LIVE=1 ".../Short Circuit"
```

- `SC_SNAPSHOT_DIR` alone: sample data plus the simulated writer. It walks the main states, including
  the write UI, in light and dark mode, writes PNGs, and quits.
- Adding `SC_SNAPSHOT_LIVE=1`: this Mac's real data with `RefusingHandlerWriter`. Read-only states
  only; files are prefixed `live-`.
- `SC_SNAPSHOT_ONLY=menus,keyboard,apps,batch,undo` runs just those groups and quits. `apps` also writes `apps.txt`, which says whether the selected app stayed selected. `menus` dumps the
  real menu bar (shortcuts and enabled state) to `menus.txt`. `keyboard` sends real key events to the
  grid and logs the selection after each one to `keyboard.txt`.
- Snapshot runs keep view state in a throwaway defaults suite, so they neither read nor overwrite yours.
- Captures come out blank while the screen is locked (`ioreg -n Root -d1 -a | grep -A1 CGSSessionScreenIsLocked`).

## Hard rules

- **Never call a default-handler setter** while developing or testing: no
  `NSWorkspace.setDefaultApplication(…)`, no `LSSetDefault*`. Each one raises a system consent
  prompt, and usually nobody is at the machine. Tests use `SimulatedHandlerBackend`; automated app
  runs use the simulated or refusing writer. Only a person at the Mac tests the live write path.
- Never run `lsregister` with any flag other than `-dump`.
- No private `@_silgen_name` symbols or other private SPI.
- **Never edit `project.pbxproj`** to add files. The project uses file-system-synchronized groups:
  anything created under `Short Circuit/` or `Short CircuitTests/` joins its target automatically.
  Build-setting changes are the only exception, and should be rare.
- Comments explain *why*, never *what*. No boilerplate comments.
- Never hard-code output to make a test pass.

## Language and concurrency

Swift 6 language mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, approachable concurrency on.
Everything is MainActor unless it says otherwise, so anything built or used off the main actor is
marked `nonisolated`: the models in `Models/`, the parser, `KindBuilder`, `LiveKindProvider`, and
the handler writers. `LaunchServicesIndex` is an `actor`. Follow the header note in
`Models/Kind.swift` when adding model types.

## Architecture

macOS 26.6+, not sandboxed (the sandbox blocks `lsregister` and the setters), hardened runtime,
Developer ID + notarization. No CLI. The one Swift package is Sparkle (in-app updates,
`Updates/`); it only starts in Release builds, and `Documentation/RELEASING.md` covers the feed and key.

- `Services/LaunchServicesIndex` runs `lsregister -dump` (about 4 s, 32 MB), caches the parsed result
  under `~/Library/Caches/com.cmorrell.Short-Circuit/`, and serves the cache first.
  `LSDumpParser` is a tolerant line-oriented parser into `Models/LSRecords`.
- `Services/KindBuilder` turns the snapshot into **Kinds**: a union-find heuristic over declarations
  that share extensions/MIME types, overlaid by the curated `Resources/Catalog.json`
  (`Models/Catalog.swift`). A broken catalog logs and falls back to the heuristic; it is never fatal.
- `Services/LiveKindProvider` enriches Kinds with live `NSWorkspace` handler reads and candidate apps.
- `Services/HandlerWriter` plans writes from live reads (not from the displayed Kind), runs one setter
  per step, and re-reads after each. `HandlerBackend` is the seam: `WorkspaceHandlerBackend` is real,
  `SimulatedHandlerBackend` is for tests and snapshots. `Documentation/write-path.md` is the contract.
- `Stores/KindStore` is the `@Observable` state the views render; `Stores/AppIndex` backs the
  Applications view.
- `Models/Kind.swift` is the shared contract between data and UI. Change it deliberately.

## Docs

Project docs live in `Documentation/` (not `docs/`):

- `design.md` — the Kind model, the architecture, the settled **Decisions**, and the known gaps.
- `launch-services.md` — why the app parses `lsregister -dump`, the dump format, and every
  behaviour measured on macOS 26.6 (consent prompts, both causes of error 256, the browser
  role, generated `dyn.` types). Read it before touching the parser or the write path.
- `write-path.md` — the write contract: planning, prompts, results, undo.
- `catalog-notes.md` — why the catalog groups what it groups; read it before editing `Catalog.json`.
- `RELEASING.md` — signing, notarization, secrets, and the tag-driven release.
- `spikes/*.swift` — the scripts behind the measurements. **They call the real setters; never
  run them.**

UI work follows the project-local `mac-assed-mac-app` skill (`.claude/skills/`): full menu-bar command
coverage, keyboard-first operation, drag/copy affordances, VoiceOver. Its standard Settings scene is
the one deliberate exception — see the decisions in `design.md`.
