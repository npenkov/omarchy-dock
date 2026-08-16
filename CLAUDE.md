# OmarchyDock — orientation

A macOS-style dock for the Omarchy shell (Quickshell/QML on Hyprland),
running live on this machine. `README.md` is the user manual;
`docs/PLAN-v2.md` is the build plan (all 7 phases shipped, tags v1.0.0 →
v2.0.0 → v2.1.0); `docs/mockups/` holds the annotated design mockups.

## The one rule

**shell.json has exactly one writer**: `bin/omarchy-dock-config` (its
`apply()` does a staged-tempfile jq write, validated before swap — a broken
shell.json takes out the whole bar). QML never writes config; the pin
badge, drag, context menu, and settings GUI all shell out to the CLI's
subcommands (`pin/unpin/move/set-item/add/set`, 0-based) and pick the
change up via the shell's config hot-reload.

## Layout

```
plugin/           the shell plugin (id rdf.dock, kind panel, keepLoaded)
  Dock.qml          root: config, reveal state, flow layout, drag, IPC
  DockItem.qml      one slot: tile, glyph/icon, indicators, badges, handlers
  RunningModel.qml  ToplevelManager grouped by appId; window↔item matching
  TintedIcon.qml    MultiEffect colorization of app icons to the theme ink
  ContextMenu.qml   right-click popup: PopupWindow + HyprlandFocusGrab
  WindowStack.qml   hover-dwell stack of live ScreencopyView previews; no
                    grab, follows the pointer along the dock
  SettingsPanel.qml settings GUI overlay, behind a Loader in Dock.qml
  glyphs.json       curated glyph list, shared by GUI and TUI pickers
bin/omarchy-dock-config   gum TUI + the programmatic subcommands
hypr/dock.lua     blur + layer rules, required from hyprland.lua via pcall
install.sh / uninstall.sh  symlink deploy into ~/.config, validated merge
scripts/dev-watch.sh       rebuild loop (see below)
```

Deployed as symlinks: `~/.config/omarchy/plugins/rdf.dock → plugin/`,
`~/.local/bin/omarchy-dock-config → bin/…`, `~/.config/hypr/dock.lua →
hypr/…`. The repo is the source of truth; `git status` reflects the live
desktop.

## Dev loop

- QML edits: `omarchy restart shell` (~3s) is the only *reliable* reload —
  the shell's own plugin watcher can't see through the deploy symlink
  (inotify `-r` doesn't traverse symlinks), and rescanPlugins has been
  flaky even when poked. `scripts/dev-watch.sh` automates the poke.
- shell.json / TUI / CLI edits: hot-reload, no restart.
- Errors: `journalctl --user --since "1 minute ago" | grep "WARN scene"` —
  QML failures are silent otherwise.
- Headless testing: real IPC surface on the plugin —
  `omarchy-shell rdf.dock state|show|hide|launch <slot>|menu <slot>|
  menuClose|stack <slot>|stackClose|settings|settingsState|settingsClose`.
  `state` returns rich JSON (sections, running matches, menu state).
  Screenshot with `grim -o <output>`; crop with `magick`.
- **Synthetic cursor moves do not fire hover on layer surfaces** — hover
  paths (pin badge, dwell, magnify) need a human; that's what the IPC
  hooks exist to route around.

## Hard-won QML/Wayland facts (each cost a debug loop)

- One entry point per plugin: shell loads panel > overlay > menu, one
  only. Extra surfaces = components behind Loaders inside the entry point.
- xdg-popup anchor rects must sit inside the parent surface; to pop above
  the dock, anchor an in-bounds 1×1 point with `gravity: Edges.Top`.
- Positioner sizing from children that size from the positioner = cycle
  that resolves to 0, silently. Menu rows measure from the model
  (FontMetrics.advanceWidth).
- Passive grabs deliver taps to every handler under the point, z-order
  irrelevant: "click-swallow" TapHandlers don't work; gate covered panes
  with `visible: false`, bounds-check scrims, hover-guard stacked badges.
- QML XHR can't read file:// — use Quickshell.Io FileView; plugin dir =
  `manifest.__sourceDir`.
- `jq -e` fails on valid null (use `jq empty` to parse-check).
- Popups follow the shell's PopupCard split: click-dismissed = PopupWindow
  + HyprlandFocusGrab over [popup, dock] (the dock stays inside the grab,
  so it keeps its own hover/taps and drives switch/dismiss itself); hover-
  driven = no grab, the owner opens/closes it. Don't reach for fullscreen
  layers with input masks or cursor polling for either — that was tried
  and is what the grab replaces.
- `dock.windowsFor()` allocates per call: anything that binds a Repeater
  to a window list snapshots it through `dock.sameWindows` first, or the
  delegates rebuild (and lose hover) on every model tick.

## State / loose ends

- User's personal dock config lives in `~/.config/omarchy/shell.json`
  (never in this repo; repo ships neutral defaults in
  `config/shell.dock.json`). Terminal + Claude items carry explicit
  `appId`; chromium profiles share appId `chromium` — known limitation,
  fixable with `--class=` in the profile launchers (README covers it).
- No git remote yet. Local-only history.
- Post-v2.1 fixes: settings input-delivery bugs, popups close with dock,
  `fullWidth` mode, taskbar-style stack (single-window previews, close
  badge, pointer-following), settings keeps the dock revealed. Check
  `git log` since the v2.1.0 tag first.
- Hover paths (menu switch/dismiss on icon hover, stack following, badge
  reveals) can only be verified by a human at the mouse; after touching
  them, ask for a hands-on check.
