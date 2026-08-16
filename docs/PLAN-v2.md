# Dock v2 — the full dock experience

v1 is a launcher that looks right: theme-native tiles, glyphs, auto-hide.
v2 makes it a real dock in the macOS sense — it knows what is running,
running apps appear in it, pinning is a gesture rather than a config edit,
and every icon reads as part of the theme.

Current state is tagged `v1.0.0`. v2 lands as phases on `main`, each one
shippable and behind config flags where behavior changes; `manifest.json`
goes to `2.0.0` when Phase 6 lands. The hover-stack grouping is v2.1.

## Feasibility — verified against the installed stack

Everything below was checked against Quickshell 0.3.0 (28771c7c) and the
Omarchy 4 shell source on this machine, not assumed:

| Need | Mechanism | Status |
|---|---|---|
| Which apps are running | `ToplevelManager.toplevels` (Quickshell.Wayland, foreign-toplevel): `appId`, `title`, `activated`, `activate()`, `close()` | ✅ shell's own ActiveWindow widget uses it |
| Per-workspace/monitor window info | `Quickshell.Hyprland` — Dock.qml already walks `monitor.activeWorkspace.toplevels` | ✅ in use today |
| Context menu that dismisses on click-out | `PopupWindow` + `HyprlandFocusGrab` — the shell's `PopupCard` ("click" triggerMode) is the exact idiom | ✅ installed + precedent |
| Tinted app icons | `QtQuick.Effects` `MultiEffect` (`colorization` + `colorizationColor`); Qt5Compat `Colorize` as fallback | ✅ both installed |
| Live window thumbnails (v2.1 stack) | `ScreencopyView` (`captureSource`, `live`) | ✅ installed |
| Icon resolution + launching | `shell.appLibrary.iconSource()/launch()` | ✅ dock uses it today |
| Config persistence | dock entry in `shell.json`; validated jq writes already exist in `bin/omarchy-dock-config` | ✅ reuse, don't reinvent |

## The one genuinely hard problem: app identity

Everything in v2 hinges on matching a live toplevel to a dock item: the
running dot, click-to-focus, pinning, grouping. The key is the Wayland
`appId` (Hyprland "class").

Resolution order for a pinned item's match key:

1. `item.appId` — explicit override, string or array (e.g. Claude Desktop's
   `com.anthropic.Claude`).
2. The desktop entry's `StartupWMClass`, when set.
3. The desktop id itself (`org.gnome.Nautilus` → appId `org.gnome.Nautilus`
   is the common well-behaved case).
4. Nothing matched → the item is launch-only, never shows a running state.

Matching is case-insensitive and also compares the last dot-segment
(`nautilus` vs `org.gnome.Nautilus`), since apps are sloppy here.

**Known limitation, documented not solved:** two chromium profile
launchers both open windows with appId `chromium` — the compositor cannot
tell them apart. The honest fix is at the launcher: add `--class=chromium-work`
to the work profile's Exec so each profile gets its own appId. The plan
does not attempt title-regex matching; it's fragile and title changes per
tab. The README gets a section on this.

## Config schema (additions, all optional — v1 configs stay valid)

```jsonc
{
  "id": "rdf.dock",
  "showRunning": true,          // the whole v2 running section on/off
  "runningIndicator": "dot",    // "dot" | "line" | "none"
  "tintIcons": false,           // global default: tint desktop icons to theme
  "tintRunning": true,          // tint auto-appearing running apps (they have no curated look)
  "hoverActivate": false,       // v2.1: hovering a stack row focuses the window
  "items": [                    // = the PINNED section, exactly as today
    {
      "desktop": "org.gnome.Nautilus",
      "appId": ["org.gnome.Nautilus"],  // NEW: explicit match key(s)
      "tint": true,                     // NEW: per-item override, wins over tintIcons
      "glyph": "󰉋", "icon": "...", "label": "...", "iconScale": 1.0,
      "exec": "...", "when": "...", "spacer": true   // all as in v1
    }
  ]
}
```

The running section is **never persisted** — it is derived state. Pinning
moves an app from derived to persisted by writing an item into `items[]`.

All shell.json writes from the dock go through the CLI, not QML:
`omarchy-dock-config` grows non-interactive subcommands (`pin <appId>`,
`unpin <index>`, `move <from> <to>`, `set-item <index> <json>`) so every
write path shares the existing staged-tempfile + jq-validation plumbing.
The QML side just `Util.execDetached()`s them and the shell.json
hot-reload closes the loop — no second config writer to keep correct.

---

## Phase 0 — groundwork

- Tag `v1.0.0` (done at plan time), set manifest to `2.0.0-dev`.
- Split the 863-line `Dock.qml`: `DockItem.qml` (one slot), `RunningModel.qml`
  (toplevel matching), `ContextMenu.qml`, keeping `Dock.qml` as layout +
  reveal state. Sibling QML files in the plugin dir import cleanly; no
  manifest change needed.
- `scripts/dev-watch.sh` already covers the edit loop.

**Done when:** dock renders pixel-identical to v1 from the split files.

## Phase 1 — running apps section + indicator + focus

- `RunningModel`: group `ToplevelManager.toplevels` by appId; partition
  into *matched to a pinned item* vs *unmatched*.
- Unmatched groups render right of an auto-divider (only present when the
  section is non-empty), using the app's desktop-entry icon (matched by
  appId against `DesktopEntries`), falling back to a generic glyph.
- Pinned items with a live match get the running indicator; so does every
  running-section item. `runningIndicator` styles it (theme accent dot or
  short line under the tile, inside the card so geometry doesn't change).
- Click semantics for anything with a live window: focus the most recently
  active window (`toplevel.activate()`). Not running → launch as today.
  Every running-section item also works with `hideOnLaunch`.

**Done when:** opening/closing any app updates the section live; clicking a
running app focuses it across workspaces; v1 configs with `showRunning:false`
render exactly as before.

## Phase 2 — themed icon tinting

- New `TintedIcon.qml`: the existing `Image` wrapped in `MultiEffect`
  (`colorization: 1.0`, `colorizationColor` = accent, hover state matches
  glyph hover behavior). Glyph rendering is untouched — glyphs already win
  over icons and stay the preferred curated look.
- Defaults per the schema above: pinned icons untinted unless asked
  (`tintIcons` / per-item `tint`), running-section icons tinted by default
  so an arbitrary app landing in the dock doesn't break the theme.
- Check contrast: colorization maps luminance, so near-white icons can
  wash out; clamp with a subtle background treatment if needed (evaluate
  on real icons before deciding).

**Done when:** a mixed dock (glyphs + tinted + full-color) reads as one
set in at least two themes (`omarchy theme set` both ways, no restart).

## Phase 3 — context menu

- `ContextMenu.qml`: `PopupWindow` anchored above the icon +
  `HyprlandFocusGrab` (windows list = dock window + menu window), following
  `PopupCard`'s trigger-mode-"click" pattern. Any action closes it; the
  grab's `cleared` signal closes it on click-out; Esc closes it.
- Right-click any item: **New Window** (= the item's launch action),
  **Pin** / **Unpin**, per-window entries when >1 window (title, truncated,
  click focuses), **Close Window(s)** via `toplevel.close()`.
- The menu suspends auto-hide while open (`root.held` already exists for
  exactly this), and releases it on close.
- The v1 double-click-background → settings gesture stays; the menu also
  gets a **Dock Settings…** entry.

**Done when:** menu opens on right-click, never survives a click anywhere,
never strands the dock open, and all actions work.

## Phase 4 — pinning UX

- Hover a running-section icon → small pin badge fades in at the tile's
  top corner (theme accent, same hover grammar as the rest). Click badge
  or menu → `omarchy-dock-config pin <appId>`: writes a minimal item
  (`desktop` id when the appId resolved to a desktop entry, else `exec`
  fallback is impossible — apps without desktop entries pin as
  appId-launch-only and the settings UI can fill in the exec) into
  `items[]` before the divider.
- Unpin (menu or settings) removes the item; if the app is still running
  it reappears in the running section — visibly "the same app moved
  sections", which is the mental model.
- CLI subcommands land here with tests: `pin`, `unpin`, `move`,
  `set-item`, each reusing `apply()`'s validated write.

**Done when:** pin → close app → icon stays; unpin → icon hops back to the
running section; shell.json diff is exactly the one item.

## Phase 5 — drag

- `DragHandler` per item. Drag within the pinned section reorders
  (live gap-opening preview, like macOS); drop persists via `move`.
- Dragging a running-section icon left across the divider pins it at the
  drop position. Dragging pinned → running section unpins (symmetry).
- Drag threshold tuned so tap-to-launch and hover-magnify don't misfire;
  magnify is suppressed during any drag.
- Spacers are drag targets/reorderable too (they're items).

**Done when:** all three gestures work with the tiles look intact, and a
sloppy 3px click still launches instead of dragging.

## Phase 6 — settings GUI  → tag `v2.0.0`

- New `settings` entry point in the manifest (kind `overlay`), summoned
  from the context menu / `omarchy-shell rdf.dock settings-gui`. Built
  from the shell's own Ui kit (Button, PopupCard idioms) so it themes
  itself.
- Per-item editor: label, launch action (desktop entry picker / exec
  command), icon source (entry icon ▸ glyph picker with the curated list
  from the TUI ▸ file path SVG/PNG), tint toggle, iconScale slider,
  appId match override.
- Dock-level page: the v1 numeric/bool settings plus the new v2 ones.
- Writes go through the same CLI subcommands; the gum TUI stays (it
  shares the plumbing, costs nothing, and is the SSH-friendly path).

**Done when:** every documented config key is editable from the GUI and a
fresh user never needs to hand-edit shell.json. Bump manifest `2.0.0`,
tag, update README.

## Phase 7 (v2.1) — grouping + hover stack

- Multiple windows of one app collapse to one icon with a count indicator
  (small `n` badge or stacked-dot variant of the running indicator).
- Hover (with dwell, ~300ms) opens a vertical stack popup above the icon:
  one row per window — `ScreencopyView` live thumbnail + title. Click
  focuses. `hoverActivate: true` opts into focus-on-row-hover; default
  stays click, because hover-focus steals focus from whatever you were
  typing in, and that wants to be a choice.
- Stack reuses the Phase 3 popup/grab machinery; thumbnails are lazy and
  only `live` while the stack is open (screencopy per window is not free).

**Done when:** 4 terminal windows = one icon, stack shows 4 live previews,
and the dock with the stack open survives a window closing under it.

---

## Risks / open items

- **Quickshell is AUR `quickshell-git`** — API drift on update is possible;
  the feasibility table pins what we rely on, re-verify on quickshell bumps.
- **Colorization legibility** (Phase 2) needs eyes-on with real icons
  before locking the default treatment.
- **Chromium profiles** share an appId until the launchers pass `--class`;
  documented, user-fixable, not dock-solvable.
- **Focus grab vs. auto-hide** interactions (menu open while pointer
  leaves) — `held` covers it, but this is the spot to test hardest.
- **Perf**: the running model rebinds on every toplevel event; keep the
  partition function cheap and measure with a dozen windows before v2.0.
