# Mac-assed review 1

Date: 2026-09-18. Reviewer: Solo process 56 (`mac-review`), using the project skill `.claude/skills/mac-assed-mac-app`.

**What was reviewed:** the committed `main` HEAD, `a9293d1`. I exported it with `git archive` into `.build/mac-review-src` so the parallel Applications work in the working tree didn't affect the review. All `file:line` references below are to that commit. At this commit the Applications section is still `ApplicationsPlaceholderView` ("Applications Are Coming"). Findings about it are limited to how the placeholder behaves inside the shell.

**How it was checked:**
- I read every file in `Short Circuit/Views`, `ContentView.swift`, `Short_CircuitApp.swift` and the UI-facing parts of `Stores/KindStore.swift`.
- I built HEAD with `-derivedDataPath .build/dd-mac-review`. It succeeded with no Swift warnings.
- I ran both snapshot modes, sample (`SC_SNAPSHOT_DIR`) and live read-only (`SC_SNAPSHOT_LIVE=1`). The images are in `.build/screenshots-mac-review/`. No default handler was touched.

**What I could not check:** anything that needs real input or Screen Recording. That covers the menus as rendered, keyboard focus movement, VoiceOver output, drag feedback and actual shortcut behaviour. Where a finding depends on SwiftUI's automatic behaviour, it is marked **verify** and belongs on the manual checklist at the end.

**App shape (skill step 1).** Short Circuit is a single-window **utility/browser**. It is Finder-like: a sidebar, an icon or list browser and an inspector. Its core objects are:
- **Kinds**, which can be selected, copied, dragged out as text, and opened with an app.
- **Members**, which are UTIs and schemes.
- **Apps**, which can be dropped in, revealed in Finder, and chosen via Other….
- **Files**, which are dropped in to find their Kind.

No documents are saved. The one reversible user action is "change a default app".

Severity:
- **must**: a Mac user will hit it in normal use and feel the app is broken or foreign.
- **should**: an expected convention is missing.
- **nice**: polish that rewards attention.

---

## 1. Menus and the menu bar

The only custom command is **View ▸ Refresh ⌘R** (`Short_CircuitApp.swift:27-36`). Everything else comes from SwiftUI's defaults.

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| M1 | must | **View menu has no view commands.** Icons/List, Show/Hide Inspector and the sidebar sections are reachable only through toolbar buttons and clicks. Finder users expect View ▸ as Icons ⌘1 / as List ⌘2, and View ▸ Show Inspector. | `Short_CircuitApp.swift:27`, toolbar in `ContentView.swift:62-100` | Add a `CommandGroup(before: .toolbar)` with a `Picker` over `store.layout`, using `.keyboardShortcut("1")` and `("2")` as Finder does. Add `InspectorCommands()`, which gives Show/Hide Inspector ⌃⌘I, and `SidebarCommands()` explicitly (**verify** whether NavigationSplitView already adds Show Sidebar ⌃⌘S). |
| M2 | must | **No menu for the core action.** Setting a default app, Fix Split, and "Other…" live only in the inspector. There is no menu command, no shortcut and no context menu (see C1). | `KindInspectorView.swift:55-77` | Add a menu such as "Type" (or put it under File): **Open With ▸** (candidates, Other…), **Fix Split** ⌥⌘F or similar, **Copy Type Identifier**, **Show in All Types**. Route it with `focusedSceneValue`/`@FocusedValue` for the selected Kind, and disable it when `!store.canWrite` or nothing is selected. |
| M3 | should | **Help menu is the empty default.** It opens "Help isn't available for Short Circuit". | app scene | Use `CommandGroup(replacing: .help)` with "Short Circuit Help" opening the README or GitHub page, plus "Report an Issue…". |
| M4 | should | **Go / navigation shortcuts for sidebar sections.** Split and Common are the main entry points, but they can't be reached from the keyboard without tabbing into the sidebar. | `SidebarView.swift:9-32` | A "Go" menu (or View submenu) with Split ⌥⌘1, Common ⌥⌘2, All Types ⌥⌘A, Applications ⌥⌘P. Keep ⌘1/⌘2 for view mode, as in Finder. |
| M5 | should | **File menu offers nothing.** The plan's headline feature is "drag any file onto the window". The menu-bar equivalent, **File ▸ Show Type of File… ⌘O**, doesn't exist, so the feature can't be discovered or used from the keyboard. | `ContentView.swift:33-37` | Add an `NSOpenPanel` (as a window sheet) that feeds `store.revealKind(forFileAt:)`. |
| M6 | nice | Refresh sits in View after the toolbar items, which is right (Safari-like). Its tooltip repeats the shortcut ("Re-read Launch Services (⌘R)"). Apple tooltips don't carry shortcuts; the menu shows them. | `ContentView.swift:89` | Use `.help("Re-read the list of apps and types")`. |
| M7 | nice | No Settings window yet. That is fine while there is nothing to set, and the plan puts it in milestone 5. Once one exists, candidates are the default sidebar section, whether All Types includes single-app Kinds, and whether shadowed members start expanded. | — | Add a `Settings { }` scene when the first preference lands. Don't add an empty one. |

## 2. Keyboard navigation and focus

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| K1 | must | **The icon grid isn't keyboard-operable.** Tiles are selected only by `onTapGesture`. The grid isn't `.focusable()`, so Tab skips it, the arrow keys do nothing, and Return/Space do nothing. The table view gets all of this free from `Table`, so the default layout is the less accessible one. (This was already noted as a known gap.) | `KindGridView.swift:10-22` | Make the `ScrollView` `.focusable()` with a `@FocusState`. Handle `.onMoveCommand` left/right as ±1 and up/down as ± the column count; compute the count from the geometry and the adaptive `GridItem`. Add `.onKeyPress(.return)` to open the picker (or focus the inspector), Home/End for first/last, and type-select via `.onKeyPress(characters:)` matching the start of `kind.name`. |
| K2 | must | **Revealed or selected items aren't scrolled into view.** Dropping a file or clicking "Show N in All Types" selects a Kind that can be hundreds of tiles below the fold in All Types (932 live Kinds). The inspector changes but the grid stays at the top (see `live-markdown-inspector.png`). | `KindStore.swift:176-194`, `KindGridView.swift:11` | Wrap the grid in `ScrollViewReader` or use `.scrollPosition(id:)`, and scroll to `selection` whenever it changes from outside. Do the same for `Table`, which also doesn't auto-scroll to a programmatic selection. |
| K3 | should | **Search can't hand off to results.** After typing in the search field, there's no Down-arrow or Return that moves focus to the first result, as there is in Finder, Mail and Music. You have to click or press Tab. | `ContentView.swift:16` | Use `.searchFocused($isSearchFocused)` plus `.onSubmit(of: .search)` to select the first `visibleKinds` item and move focus to the grid or table. **Verify** that ⌘F focuses the toolbar search field (SwiftUI usually wires Edit ▸ Find to `.searchable`). If it doesn't, add a Find command that sets `isSearchFocused = true`. |
| K4 | should | **Escape and background click aren't consistent.** Clicking the grid background clears the selection (good, Finder-like, `KindGridView.swift:21`). Escape doesn't. | `KindGridView.swift` | Add `.onExitCommand { selection = nil }` on the focused grid. |
| K5 | nice | Double-click on a tile or row does nothing. Finder's double-click means "open". The closest meaning here is "choose an app". | grid/table | Double-click (and Return) opens the Opens With pop-up. At minimum, it reveals and focuses the inspector. `Table` supports `.contextMenu(forSelectionType:menu:primaryAction:)` for this. |

## 3. Selection

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| S1 | should | **The custom grid selection ignores focus and window state.** The selected tile's name uses `Color.accentColor` with white text in all cases. Finder greys the selection when the window isn't key or the grid isn't focused, and the Table here does that automatically, so the two layouts disagree. | `KindGridView.swift:34-49` | Read `@Environment(\.appearsActive)` and the grid's focus state. When either is false, use `Color(nsColor: .unemphasizedSelectedContentBackgroundColor)` and `.primary` text. |
| S2 | nice | Selection is single-only in both layouts. That's right for the inspector. The Applications batch flow in the plan will want multi-select ("make default for these 6 types"), so design the grid selection as a `Set<Kind.ID>` now rather than retrofitting it. | `KindGridView.swift:5`, `KindTableView.swift:5` | Use `Set<Kind.ID>` for the selection. With several selected, the inspector shows "N types" and an Opens With limited to the shared candidates. |

## 4. Context menus

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| C1 | must | **There are no context menus anywhere.** Right-clicking a tile, a table row, a member row, an extension chip or an app icon does nothing. A Mac user will right-click a type expecting at least Open With and Copy. | `KindGridView.swift:14`, `KindTableView.swift:16`, `KindInspectorView.swift:357` | **Tile/row:** Open With ▸ (candidates with icons, Other…), Fix Split (when split), then a divider, Copy Name, Copy Type Identifiers, Copy Extensions, then Show Default App in Finder. For `Table`, use `.contextMenu(forSelectionType: Kind.ID.self)` so the clicked-row focus ring is native. **Member row:** the same items as its ⋯ menu, plus Copy Identifier. **Chip:** Copy. **App label:** Show in Finder, Open. |

## 5. Pasteboard and copy

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| P1 | must | **⌘C does nothing with a selected Kind.** The whole point of the app is identifiers, so "copy a UTI" is the most likely thing a developer tries. Today they must select text in the inspector by dragging over a monospaced label. | grid/table | Add `.copyable([selectedKind])` on the browser, with `Kind` conforming to `Transferable`. Offer plain text (the name, then the UTIs one per line) plus a JSON representation of the Kind (UTIs, extensions, MIME types, schemes, default app bundle IDs). For multi-selection, one line per Kind, tab-separated like Finder's list copy. |
| P2 | should | **Members and chips have no Copy.** `.textSelection(.enabled)` on the member identifier (`KindInspectorView.swift:370`) and on chips (`:525`) works, but a single chip needs a precise drag-select. | `KindInspectorView.swift:365-371, 519-526` | Add a Copy context-menu item (C1). Consider making ⌘C in a focused member row copy its identifier. |
| P3 | nice | No paste. Pasting a path, an extension (`.md`) or a UTI could jump to its Kind, a natural counterpart to drop. | `ContentView.swift` | `.pasteDestination(for: URL.self)`, and `for: String.self` that routes through `KindSearch`/`revealKind`. |

## 6. Drag and drop

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| D1 | should | **Nothing drags out.** Tiles, rows, member identifiers and app icons are all inert as drag sources. | grid/table/inspector | `.draggable(kind)` using the same `Transferable` as P1, so dragging into TextEdit or Terminal drops the UTIs. App icons should drag the app's file URL, so dropping on the Dock or Finder works. |
| D2 | should | **Dropping several files handles one silently.** `urls.first(where: \.isFileURL)` ignores the rest, with no feedback. | `ContentView.swift:33-37` | Reveal the first match and show "Showing the type of notes.md (2 other files ignored)". Better, with S2: select the Kinds of all dropped files. |
| D3 | should | **Dropping an app does nothing useful.** The obvious "I wonder if this works": drag Typora from Finder onto the Opens With pop-up. Today an `.app` dropped on the window tries to find the Kind *of the app bundle* (and those Kinds were deliberately removed). | `ContentView.swift:33`, `KindInspectorView.swift:56` | Add a `.dropDestination(for: URL.self)` on the Opens With row and member rows that accepts `.application` URLs. It calls the same `setDefault` path, and macOS still asks for consent. In the window-level drop, treat an app bundle as "show this app in Applications" once that view exists. |
| D4 | nice | Files dropped on the **Dock icon** or sent via **Open With ▸ Short Circuit** don't work: no document types are declared (`GENERATE_INFOPLIST_FILE = YES`, no `CFBundleDocumentTypes`). | project Info.plist settings | Declare `public.item` with `LSHandlerRank = None` and role Viewer, so Short Circuit is never a default but can accept drops. Handle it with `.onOpenURL` or `NSApplicationDelegate.application(_:open:)`, calling `revealKind`. |
| D5 | nice | The drop highlight is a custom 3 pt accent stroke around the whole window (`ContentView.swift:25-32`). It works. It doesn't respect Reduce Motion for the banner that follows (see A5). | — | Keep it. |

## 7. Window behaviour and state restoration

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| W1 | must | **Nothing the user arranges is remembered.** On every launch the app forgets the icon/list layout, sidebar section, inspector visibility, "Other declared types" disclosure and table sort. They are plain `@Observable` properties initialised to constants. | `KindStore.swift:39-44`, `KindTableView.swift:9` | Persist `layout`, `sidebarSelection`, `isInspectorPresented` and `showsShadowedMembers` with `@SceneStorage` (`@AppStorage` for layout if it should be global). This needs `SidebarItem` to be `RawRepresentable`/`Codable`. Persist table columns with `@SceneStorage` + `TableColumnCustomization` (`.customizationID` on each column), which also gives users column hide/reorder. Leave `selectedKindID` alone, or restore it only if the Kind still exists. |
| W2 | should | **The ⋯ "Other…" app chooser is app-modal, not a sheet.** `NSOpenPanel.runModal()` blocks the whole app, and it always starts in `/Applications`. | `ApplicationChooser.swift:6-13` | Use `panel.beginSheetModal(for: NSApp.keyWindow!)`, or SwiftUI `.fileImporter(allowedContentTypes: [.application])`. Remember the last folder the user chose, since apps in `~/Applications`, Setapp or DerivedData are exactly the ones "Other…" exists for. |
| W3 | nice | `Window` (single-instance) is the right scene for this utility. **Verify** that closing the last window quits the app (SwiftUI's behaviour for a lone `Window` scene) and that the frame is restored on relaunch. If the app stays running, Window ▸ Short Circuit must reopen it. | `Short_CircuitApp.swift:22` | — |
| W4 | nice | The window title follows the sidebar ("Common", "Split"), as in Finder. The Window menu will therefore list "Common", not "Short Circuit". This is acceptable and matches Finder. | `ContentView.swift:114-122` | — |

## 8. Toolbar and sidebar

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| T1 | should | **Toolbar controls stay live where they do nothing.** In Applications, the Icons/List control and the search field remain enabled, and the inspector says "Select a type, or drop a file". Typing a search there filters nothing visible. (`applications-light.png`) | `ContentView.swift:16-19, 62-71` | Hide or disable the layout picker and the inspector toggle when `sidebarSelection == .applications`. Scope the search prompt to apps once that view exists. The Applications agent should own this. |
| T2 | should | **The inspector toggle's tooltip and label don't reflect its state.** It is always "Inspector" / "Show or hide the inspector". | `ContentView.swift:92-99` | Use `.help(store.isInspectorPresented ? "Hide Inspector" : "Show Inspector")`. Better, use `InspectorCommands` (M1) and drop the custom button so the system places a standard trailing toggle. |
| T3 | nice | The toolbar isn't customisable. For a toolbar this small that's fine, but add `.toolbar(id:)` with customizable items if more appear (for example Fix Split or Share). | — | — |
| T4 | nice | The Applications sidebar icon is `app.dashed`, which reads as "placeholder/missing". | `SidebarView.swift:29` | Use `square.grid.3x3.square` or `app.badge` once the view is real. Finder's own Applications uses `app`/`square.grid.2x2`-style glyphs. |
| T5 | good | Sidebar counts use `.badge` (native), sections are grouped as in Finder, and the view picker is a segmented control with `Label`s and a tooltip. The layout mirrors Finder closely and reads as native (`live-common-grid.png`). | | |

## 9. Search

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| F1 | should | **The prompt reads like a syntax spec and ends in a colon.** "Name, .ext, MIME, UTI, or scheme:" looks truncated in the field (`live-common-grid.png`). | `ContentView.swift:16` | Use the prompt "Search Types". Put the syntax in the empty-results view (already there, `KindBrowserView.swift:59`) and in search **suggestions**: `.searchSuggestions` showing "Extension .md", "Scheme md:", "Name contains md" as the user types. Better still, turn `.` and `:` into **search tokens** (`.searchable(text:tokens:)`), which is the modern Mail/Finder pattern and makes the mode visible. |
| F2 | good | Search is scoped to the sidebar section, and the empty state offers "Show N in All Types" (`KindBrowserView.swift:61-65`). That is a very Mac touch. | | |

## 10. Undo

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| U1 | should | **No Undo for "set default app".** Edit ▸ Undo is dimmed after a change, and the plan and checkpoint both list undo as missing. Restoring the previous handler per member is well defined: the store already records the before state in its results. | `KindStore.swift:208-264` | Register with the window's `UndoManager` (`@Environment(\.undoManager)` passed into `KindEditing`) after a successful apply. Name it "Undo Set Default App for Markdown". The undo re-applies each member's previous app through the same writer; macOS will prompt again, which is correct and honest. Register nothing when every member was skipped or declined. |

## 11. Accessibility

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| A1 | must | **Grid tiles have no deliberate VoiceOver label.** `.accessibilityElement(children: .combine)` concatenates the unlabeled document `Image(nsImage:)`, the kind name, the badge app icon (which has a label, `KindIconView.swift:67`) and the default-app text. That likely reads "Markdown, TextEdit, TextEdit" or includes "image". "Split" status comes out only as label text. | `KindGridView.swift:58-59`, `KindIconView.swift:23-26, 47` | On `KindTile`, set `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(kind.name)` and `.accessibilityValue(isSplit ? "Split" : app name ?? "No default")`. Add an `.accessibilityAction(named: "Choose App")`. Mark `documentIcon` `.accessibilityHidden(true)`. |
| A2 | must | **Icon-only member menus have no labels.** The ⋯ / globe `Menu` label is a bare `Image(systemName:)` with only `.help("Set just this member")`. VoiceOver will say "More" or "globe", with nothing about which member. The odd-one-out ⚠ image (`:382`) is also unlabeled. | `KindInspectorView.swift:440-450, 381-385` | `.accessibilityLabel("Choose app for \(member.target.displayName)")` (or "Change Default Browser"). For the warning image, `.accessibilityLabel("Opens in a different app")`. |
| A3 | should | **Transient messages disappear after 3 s and aren't announced.** "No type matches…" and **"Refresh failed: …"** (an error) are shown only as an auto-dismissing toast. VoiceOver users never hear them, and slow readers lose the error. | `KindStore.swift:298-306`, `ContentView.swift:102-112` | Post `AccessibilityNotification.Announcement(message).post()` when showing a message. Show refresh failures persistently (for example a dismissible banner or an inline row) rather than as a 3 s toast. |
| A4 | should | **Dimmed captions are below readable contrast.** Shadowed and unsettable member rows use `.foregroundStyle(.tertiary)` captions *inside* a row already at `.opacity(0.6)`. In `live-markdown-inspector.png`, "macOS doesn't use this type for files, so it can't be changed." is barely legible. That sentence explains *why* a control is missing, so it matters. | `KindInspectorView.swift:394-398, 411` | Dim only the identifier and app line, not the caption. Use `.secondary` for the caption and drop the extra opacity when `colorSchemeContrast == .increased`. |
| A5 | nice | The message banner uses `.move(edge: .bottom)`. | `ContentView.swift:110` | Under `@Environment(\.accessibilityReduceMotion)`, use `.opacity` only. |
| A6 | nice | UTI labels use `.minimumScaleFactor(0.7)`, so long identifiers shrink to about 9 pt. Middle truncation plus the tooltip is enough on its own. | `KindInspectorView.swift:368` | Drop the scale factor and rely on `.truncationMode(.middle)` and `.help`. |

## 12. Localization readiness

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| L1 | should | **No String Catalog, and many strings bypass localization.** `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` and `SWIFT_EMIT_LOC_STRINGS = YES` are set, but there is no `Localizable.xcstrings`. Several UI strings are built as `String` and never become `LocalizedStringKey`:<br>• `title` and `subtitle` (`ContentView.swift:114-128`)<br>• `KindCategory.title` (`KindCategory+Display.swift:5`)<br>• `KindStore.showMessage` arguments<br>• `ApplicationChooser`'s `panel.message` | as listed | Add `Localizable.xcstrings`, which Xcode fills on build. Return `LocalizedStringResource` (or use `String(localized:)`) for computed titles and messages. |
| L2 | should | **Hand-rolled plurals and lists.** Examples:<br>• `count == 1 ? "1 type" : "\(count) types"` (`ContentView.swift:127`)<br>• `"\(changed) changed"` (`KindInspectorView.swift:302-314`)<br>• `formatted(_:)` builds ", " and " and " by hand (`:145-149`)<br>• **Bug:** `count == 1 ? "files are" : "files are"` has identical branches (`:102`), so the singular reads ".mkd files are handled…". That happens to be fine in English but shows the pattern breaking. | as listed | Use `Text("^[\(count) type](inflect: true)")` or catalog plural variants. `KindInspectorView.swift:160` already does this correctly. Use `extensions.formatted(.list(type: .and))` for lists. |

## 13. Wording and capitalization

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| X1 | should | **"Kind" leaks into the UI.** Everywhere else the UI says "type", but the inspector says "handled by a type outside this Kind." | `KindInspectorView.swift:102` | "…handled by a different type." |
| X2 | should | **"Member" is internal jargon.** Examples: the tooltip "Set just this member" (`:450`) and "These members open in different apps…" (`:333`). | as listed | "Choose an app for just this type" / "These types open in different apps…". |
| X3 | nice | **"No default" and "None" mean the same thing.** "No default" is used in `DefaultAppLabel` (`KindIconView.swift:89`) and `MemberRow` (`:378`); the picker uses "None" (`:201`). | as listed | Pick one; "None" matches Finder's Get Info. |
| X4 | nice | **"Reading Launch Services…" is system jargon for a loading state.** | `KindBrowserView.swift:16`, `ContentView.swift:77` | "Loading Types…" (title case for a progress title). Keep "Launch Services" in help text. |
| X5 | good | Title-style capitalization is consistent in buttons, menus and headers: "Try Again", "Fix Split — Use X for All", "Other…" with a real ellipsis, "Couldn't Load Types" with a curly apostrophe. The Opens With pop-up with a trailing **Other…** deliberately mirrors Finder's Get Info. | | |

## 14. Empty, error and loading states

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| E1 | should | **Refresh errors after the first load are transient** (A3). The first-load failure has a proper `ContentUnavailableView` with Try Again (`KindBrowserView.swift:18-25`). That state has only been seen in a preview. | `KindStore.swift:165-171` | See A3. |
| E2 | nice | The Applications placeholder is honest, but it is a dead end in a shipping build. | `ApplicationsPlaceholderView.swift` | Being replaced now. Make sure the replacement has its own empty state ("No apps found") and loading state. |
| E3 | good | Nothing Is Split, No Results (with a scoped fallback), No Selection (with the drop hint) and the inline "Waiting for macOS… change 1 of 2" progress are all well chosen and use native `ContentUnavailableView`/`ProgressView`. | | |

## 15. System integration: Finder, Services, Quick Look, Dock

| # | Sev | Finding | Where | Fix |
|---|---|---|---|---|
| I1 | should | **No Show in Finder for apps.** Duplicate installs are the one case where the path matters (the app already disambiguates labels by version or folder, `AppLabels.swift`). | `KindInspectorView.swift:374-377` | Add a context-menu item on app labels (C1): Show in Finder, via `NSWorkspace.shared.activateFileViewerSelecting([app.url])`. |
| I2 | nice | **Services.** A "Show File Type in Short Circuit" service for files selected in Finder is the Mac-assed version of drop-a-file. | Info.plist `NSServices` | Register a service taking `public.file-url` that calls `revealKind`. |
| I3 | nice | **Quick Look** doesn't apply: Kinds aren't files. Don't bind Space to anything surprising. When grid keyboard support lands (K1), Space could open the Opens With pop-up, which matches Finder's "act on selection" feel. | — | — |
| I4 | nice | **Shortcuts/App Intents** such as "Get default app for type" and "Set default app for type" would suit a power-user utility. That is post-v1, since the plan says there is no CLI in v1. | — | — |
| I5 | nice | No `LSApplicationCategoryType`. | build settings | Set `INFOPLIST_KEY_LSApplicationCategoryType = public.app-category.utilities`. |

---

## Rubric (skill `review-and-qa.md`)

| Category | Score | Note |
|---|---|---|
| Native behaviour | 2 | Native split view, table, form, pickers and search. The grid is the custom exception. |
| Menus/commands | 1 | Only Refresh is added. No view, selection or help commands. |
| Keyboard/focus | 1 | The table is fine. The grid (the default view) is mouse-only. |
| Text handling | 2 | Native fields. Identifiers are selectable. |
| Selection | 1 | Single selection only. Grid selection ignores focus and window state. |
| Drag/drop | 1 | File drop in only. |
| Copy/paste | 0 | Nothing copyable except by text selection. |
| Windows/documents | 2 | Right scene type. The app chooser is app-modal. |
| State/config | 1 | Nothing persisted. |
| Interoperability | 1 | No Finder reveal, Services, Dock drop or document types. |
| Accessibility | 1 | Toolbar labels are good. Tiles and icon menus are weak. |
| Craft/detail | 2 | Finder-like layout, a scoped search fallback, live progress for consent prompts. |
| **Total** | **15 / 36** | "Runs on Mac, but feels generic or incomplete". The *look* is already very Mac. Most of the gap is behaviour, and nearly all of it is cheap in SwiftUI. |

## Prioritized top 10

1. **K1**: arrow keys, Tab focus, Return and type-select in the icon grid (`KindGridView.swift`).
2. **C1**: context menus on tiles, rows, members and apps (Open With ▸, Fix Split, Copy…, Show in Finder).
3. **P1 + D1**: `Transferable` Kind, so ⌘C and drag-out produce names, UTIs and JSON.
4. **W1**: persist layout, sidebar section, inspector visibility, disclosure, table sort and columns (`@SceneStorage`, `TableColumnCustomization`).
5. **K2**: scroll the grid or table to a selection made by drop, reveal or "Show in All Types".
6. **M1 + M2**: View menu (as Icons ⌘1, as List ⌘2, Inspector ⌃⌘I, Sidebar) and a Type menu with Open With / Fix Split, routed through focused values.
7. **A1 + A2**: explicit VoiceOver label and value on tiles, and labels on the icon-only member menus and warning glyphs.
8. **U1**: Undo "Set Default App for X" through `UndoManager`.
9. **A3/E1**: announce transient messages, and make refresh errors persistent rather than a 3 s toast.
10. **D3 + W2**: accept an app dropped on Opens With, and run "Other…" as a window sheet that remembers its folder.

Next after these: M3 Help menu, M5 File ▸ Show Type of File… ⌘O, S1 unemphasized selection, L1/L2 String Catalog and plurals (including the `"files are" : "files are"` bug), F1 search prompt and tokens, T1 disable view controls in Applications.

## Already good

- A real Mac layout: `NavigationSplitView` sidebar with sections and `.badge` counts, a Finder-style icon grid, a native `Table` with sortable columns, and a trailing `.inspector` with a sensible width range.
- Tiles use `NSWorkspace` document and app icons, so the grid literally looks like Finder, and the default-app badge is instantly readable.
- The Opens With pop-up with a trailing **Other…** mirrors Finder's Get Info, and current apps are pulled to the top.
- Consent-aware write UX: inline "Waiting for macOS… change 1 of 2", per-member results, and honest failure text that can be copied.
- Search scoped to the sidebar section, with a "Show N in All Types" escape hatch, and smart `.ext` / `scheme:` parsing.
- Refresh at ⌘R in the View menu, disabled during writes.
- A drop-a-file-to-find-its-type affordance with visible drop targeting.
- Empty and error states use `ContentUnavailableView` with actions. Wording is title case with proper ellipses and curly quotes. `^[… app](inflect: true)` is already used in one place.
- Light and dark mode both render correctly in every snapshot state.

## Manual QA checklist (needs a person; not run by this review)

- [ ] View menu: is there a Show Sidebar item? Does ⌘F focus the search field?
- [ ] Tab from the sidebar: does focus reach the grid, the table and the inspector pop-up?
- [ ] Close the window: does the app quit? Relaunch: is the window frame restored?
- [ ] VoiceOver: read a tile, a split tile, the ⋯ member menu and the globe menu.
- [ ] Increase Contrast: legibility of the dimmed "Other declared types" rows.
- [ ] Drop two files, an app, and a folder on the window.
- [ ] Other…: is the panel modal to the app or to the window, and where does it start?
