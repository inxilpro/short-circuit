# Hand tests

Checks only a person at the Mac can run: macOS asks before every default-app change, and
some checks need real clicks, keys and VoiceOver. Agents never run these (see the hard rules
in `CLAUDE.md`).

**Build to test:** the latest release, currently **v0.0.5**, from
<https://github.com/inxilpro/short-circuit/releases/latest>. Delete the old copy before
installing a new one; if the icon looks stale afterwards, `killall Finder Dock`.

There is no app-level confirmation dialog. macOS asks before **every** change, including
by-extension rows (".markdown files").

## Where things stand

| Release | What it was for |
| --- | --- |
| v0.0.1 | First tag-driven release: signing, notarization, Sparkle feed all proven |
| v0.0.2 | Fixes from the first hand-test pass (section R), first app icon |
| v0.0.3 | Updated icon; docs consolidated |
| v0.0.4 | Fix: the Applications list flipped between its last two apps (a 0.0.2 regression) |
| v0.0.5 | Applications: sort apps by name or defaults; sortable type columns; Apps count |

Done by hand so far: all of A and B, C1–C9, and D1. The
first pass found the problems listed under R; their fixes shipped in 0.0.2 and **have not
been retested by a person**. Everything unchecked below is still open.

## R. Retest the first-pass fixes

- [ ] R1 Arrow Down stays in its column at several window widths, including 8 columns
      (it used to drift one column right)
- [ ] R2 Search, then Tab: the first result is selected and the arrows move from it
- [ ] R3 Escape in search clears it and the arrows work straight away; Escape in the grid
      clears the selection and the arrows still work
- [ ] R4 Right-click an unselected tile, a list row and an Applications row: that one
      becomes the only selected item, with the menu showing. Also: **hovering alone never
      changes the selection**, and a clicked app in Applications stays selected. No machine
      check covers the right-click itself
- [ ] R5 Decline a macOS prompt: the row reads "Declined" in grey, not a red "rejected
      without asking"
- [ ] R6 Markdown ▸ ".markdown files" ⋯ → another app: ONE macOS prompt, "Waiting for
      macOS…", result "Changed", and a real `.markdown` file in Finder now opens in that app
- [ ] R7 Whole Markdown → Sublime Text: prompts for `.markdown` and `.mdown`; `.mkd` says
      it can't open this type; the count line says macOS will ask about every change
- [ ] R8 Undo of a by-extension change prompts once and restores it
- [ ] R9 An older installed release → Check for Updates… offers the newest, installs it,
      About shows the new version, and the icon is right in the Dock and Finder

## N. New in v0.0.5

- [ ] N1 Applications: the toolbar sort menu (up/down arrows) and View ▸ Sort Apps By switch
      between Name and Number of Defaults; the selected app stays selected; "Other apps"
      stays at the bottom; the choice survives a relaunch
- [ ] N2 View ▸ Sort Apps By is disabled outside Applications
- [ ] N3 In an app's type table, click Type, Opens With, Apps and Extensions: each sorts
      inside its section, a second click reverses, and the sort survives a relaunch and
      carries to other apps
- [ ] N4 The Apps count looks right for a few types you know; its tooltip gives the
      declaring count and the total macOS offers

## A. Keyboard and menus (no defaults change) — done

- [x] A1 Tab from the sidebar into the grid; arrows move; Return/Space behave; typing a
      name selects it
- [x] A2 ⌘F lands in search; Escape clears the selection
- [x] A3 View ▸ as Icons ⌘1 / as List ⌘2; Show Inspector ⌃⌘I; Show Sidebar ⌃⌘S
- [x] A4 View ▸ Go To ▸ Split / Common / All Types / Applications (⌥⌘1–4)
- [x] A5 The Type menu follows the selected type and is disabled with nothing selected
- [x] A6 Right-click a tile, a list row, an identifier row, an extension chip, an
      Applications row: same actions as the menus
- [x] A7 File ▸ Show Type of File… ⌘O opens as a sheet and jumps to the file's type
- [x] A8 Help ▸ Short Circuit Help / Report an Issue…
- [x] A9 View ▸ Show App-Specific Link Types: off by default; remembered after relaunch;
      searching `slack:` finds it while hidden

## B. Copy, drag, drop — done

- [x] B1 ⌘C on a tile, paste into TextEdit → `Markdown (…identifiers…)`; same in list view
- [x] B2 Drag a tile to TextEdit; drag an extension chip to Terminal
- [x] B3 Drag a file from Finder onto the window → jumps to its type and scrolls to it
- [x] B4 Drag an app from Finder onto "Opens With" → sets it (macOS prompt); dropped
      elsewhere → a hint

## C. Changing defaults — done, but see R5–R7

- [x] C1 Single type via the ⋯ menu: one macOS prompt, result "Changed"
- [x] C2 Decline a macOS prompt (first pass showed a red failure; fixed, retest as R5)
- [x] C3 By-extension row (first pass: no prompt, nothing changed; fixed, retest as R6)
- [x] C4 Whole type with a mix (same fault as C3; retest as R7)
- [x] C5 Two-prompt change: Web browser → another browser while XHTML is elsewhere:
      "change 1 of 2" then "2 of 2", two macOS prompts
- [x] C6 MIME HTML document → Google Chrome: one prompt, and Word's type shows a neutral
      "can't open this type"
- [x] C7 Fix Split on a harmless type: only differing rows change; it stays in the Split
      list with a green check until ⌘R
- [x] C8 "Other…" — checked, with a note asking what it was for. It guards three old bugs:
      the app picker must open as a sheet on the window (not a loose panel), start in the
      folder you last picked from (`/Applications` the first time), and the app you pick
      must actually be applied (macOS prompt, then "Changed"). Try it once from the
      inspector's Opens With menu and once from a row's ⋯ menu
- [x] C9 A type with nothing to set as a whole (search "TrueType"): explains itself, no Fix
      Split, per-row ⋯ menus still work

## D. Undo

- [x] D1 After C1: Edit ▸ Undo Set Default App for "…" → one macOS prompt, back to the original
- [ ] D2 Replaced by R8
- [ ] D3 Decline the undo's prompt → a banner that stays until dismissed
- [ ] D4 Change a type, change it again to a third app, undo twice: each undo restores the
      state before it. Also: change a type, change it in Finder's Get Info, then undo →
      "was changed again since; left as is"
- [ ] D5 Default browser change, then ⌘Z → a single prompt; https and HTML follow
- [ ] D6 Undo is disabled while a change or refresh is running
- [ ] D7 ⌘Z in the search field still undoes typing

## E. Applications view

- [ ] E1 Pick an app; the sections read sensibly (Default for / Partly default / Can open /
      Also offered by macOS)
- [ ] E2 Check 2–3 harmless types → the footer's count of macOS prompts matches what macOS shows
- [ ] E3 Longer batch: press Stop during the first prompt, answer it → nothing further
      prompts; the rest show "Not started"
- [ ] E4 ⌘Z after a batch undoes it as one step, a prompt per restored type, stopping at
      the first decline
- [ ] E5 After a change, the app list's "default for N · can open N" updates at once, and
      the type moves between sections while the batch's Status column stays
- [ ] E6 Console shows no "reentrant operation" warning when opening Applications
- [ ] E7 Type icons in the rows match the grid's (32 pt, with the default app's badge)

## F. Remembered state

- [ ] F1 Switch to List, sort by Opens With, hide a column, pick Images, hide the
      inspector. Quit, relaunch: all restored
- [ ] F2 Window size and position restored

## G. Accessibility (VoiceOver on, ⌘F5)

- [ ] G1 A tile reads its name, then its status (app or "Split")
- [ ] G2 The ⋯ and globe buttons have spoken labels
- [ ] G3 A failure banner is announced and stays until dismissed

## H. First launch and data

- [ ] H1 Delete `~/Library/Caches/com.cmorrell.Short-Circuit/` (or use a fresh account):
      first launch shows a loading state for about 6 s, then the grid
- [ ] H2 Install or delete an app that declares types, relaunch: the list reflects it
      without ⌘R

## I. Release

- [x] I1 Repository pushed; CI passes on the `xcode-27` image
- [x] I2 The 8 secrets are set
- [x] I3 A tag produces a notarized DMG, a zip and `appcast.xml` (v0.0.1–v0.0.5)
- [ ] I4 Install from the DMG; change one default by hand (the macOS prompt works in the
      notarized build); Check for Updates… reports up to date
- [ ] I5 Rotate the GitHub token that showed up in a local process listing during setup
