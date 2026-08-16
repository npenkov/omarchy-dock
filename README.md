# OmarchyDock

A macOS-style dock for the [Omarchy](https://omarchy.org/) shell. Hover the
bottom edge of the screen and it slides up; move away and it hides again.

Two sections: **pinned** launchers on the left (glyphs or app icons, themed
tiles), and — after an automatic divider — every **running app that isn't
pinned**, derived live from the compositor and never written to config.
Anything running carries an accent indicator; clicking it focuses its most
recent window, wherever it is. Right-click for New Window, Pin/Unpin,
per-window focus, and Close. Hover a running app for the pin badge; drag
icons to reorder, and drag across the divider to pin or unpin. App icons
can be colorized to the theme accent so arbitrary apps sit next to your
curated glyphs as one set.

Multiple windows of one app collapse to a single icon with a count badge.
Holding the pointer over a running icon for a beat opens a vertical stack of
**live window previews** — even for a single window — click one to focus it,
or hit the close badge on a preview to close that window. Once a stack is
up it follows the pointer along the dock, taskbar-style, and folds when you
drift away. Set `hoverActivate: true` to focus windows as you hover the
stack, full macOS style (off by default: hover-focus steals focus from
wherever you were typing).

The right-click menu dismisses like every other shell popup: click
anywhere else or pick a row. Hovering another icon dismisses it too, so a
menu opened by mistake never needs a trip off the dock.

It ships as a third-party Quickshell plugin (`rdf.dock`) plus a settings
GUI (right-click → Dock Settings…, or double-click the dock background)
and a terminal configurator, `omarchy-dock-config`.

## Requirements

- Omarchy (Hyprland + the Quickshell-based `omarchy-shell`)
- `jq` and `gum` — used by the configurator
- `inotify-tools` — only for `scripts/dev-watch.sh`

## Install

```bash
git clone <this repo> ~/Scripts/vibe/OmarchyDock
cd ~/Scripts/vibe/OmarchyDock
./install.sh
```

`install.sh` is idempotent, backs up anything real it displaces, and takes
`--dry-run` if you want to see the plan first. It:

| Step | Destination |
|------|-------------|
| Links the plugin | `~/.config/omarchy/plugins/rdf.dock` → `plugin/` |
| Links the configurator | `~/.local/bin/omarchy-dock-config` → `bin/` |
| Links the Hyprland settings | `~/.config/hypr/dock.lua` → `hypr/dock.lua` |
| Adds `pcall(require, "hypr.dock")` | `~/.config/hypr/hyprland.lua` |
| Seeds a starter dock entry | `~/.config/omarchy/shell.json` |

Everything except `shell.json` is a symlink back into this checkout, so this
repo stays the single source of truth — edit here, commit here. `shell.json`
is shared with the rest of the shell, so the dock's entry is merged into it
instead, staged through a temp file and only swapped in once `jq` confirms
the result still parses and still contains the dock. A broken `shell.json`
costs the whole bar, not just this plugin.

An existing dock entry is never overwritten; re-running the installer leaves
your settings alone unless you pass `--replace-config`.

The `pcall` on the Hyprland require is deliberate: if this checkout is
deleted, the config degrades to "no blur behind the dock" rather than taking
down the whole Hyprland config with a missing-module error.

## Configure

```bash
omarchy-dock-config      # or right-click the dock
```

The configurator writes straight into the dock's entry in `shell.json`, which
the shell re-reads on save — changes show up immediately, no restart.

**Your dock contents are yours, not the repo's.** What ships in
`config/shell.dock.json` is a neutral starting point (app launcher, browser,
terminal, files) so a fresh install has a working dock. Add your own items
after installing; they live in `shell.json` and are intentionally not tracked
here. If an item points at a custom `.desktop` entry or a script, that entry
or script is a prerequisite you install separately.

Settings on the plugin entry:

| Key | Meaning |
|-----|---------|
| `items` | The pinned section; `{"spacer": true}` draws a divider |
| `showRunning` | The running-apps section (default true; false = the v1 dock) |
| `runningIndicator` | `"dot"` (default), `"line"`, or `"none"` |
| `tintIcons`, `tintRunning` | Colorize pinned / running app icons to the theme (defaults false / true) |
| `hoverActivate` | Row-hover in the window stack focuses that window (default false) |
| `iconSize` | Icon edge length in px |
| `labels` | Show a label above the hovered item |
| `magnify` | macOS-style hover magnification |
| `tiles`, `tileStyle`, `tileOpacity`, `tileRadius` | Draw items as themed tiles |
| `cornerRadius`, `edgeGap` | Shape and offset of the dock card |
| `fullWidth` | Stretch the card across the monitor, edge gap on all sides (icons stay centred) |
| `revealDelay`, `hideDelay` | Hover-in and hover-out delays in ms |
| `hotspotFullWidth`, `hotspotHeight` | Size of the bottom-edge trigger zone |
| `hideOnLaunch` | Hide the dock after activating an item |
| `showWhenEmpty` | Still reveal when there are no items |

Item keys: `exec`, `desktop`, `glyph`, `icon`, `label`, `iconScale`, `tint`,
`appId`, `spacer`, and `when` (a shell command; the item only shows when it
exits 0).

### How windows are matched to items

The running state keys on the Wayland appId (Hyprland "class"), resolved
per item as: explicit `appId` (string or array — wins outright), else the
desktop entry's `StartupWMClass`, else the desktop id itself.
Case-insensitive, tolerant of reverse-DNS tails.

**Known limitation:** two launchers for the same binary — e.g. chromium
profiles — open windows with the same appId, and the compositor cannot
tell them apart. Fix it at the launcher: add `--class=chromium-work` to
the work profile's `Exec` and set that as the item's `appId`.

### Programmatic CLI

The GUI, pin badge, and drag all persist through `omarchy-dock-config`
subcommands — one validated writer for shell.json (indices 0-based):

```
omarchy-dock-config pin <appId> [index]
omarchy-dock-config unpin <index>
omarchy-dock-config move <from> <to>
omarchy-dock-config set-item <index> <json>
omarchy-dock-config add <json> [index]
omarchy-dock-config set <key> <json>     # dock-level; null unsets
```

## Development

```bash
./scripts/dev-watch.sh
```

Leave that running while you edit `plugin/Dock.qml` and the dock reloads on
save. It exists because the shell watches `~/.config/omarchy/plugins` with
`inotifywait -r`, which does not traverse symlinks — so with the plugin
directory linked here, the shell's own watcher never sees your edits and the
dock silently keeps serving the code it started with. The script watches the
real files and calls `omarchy-shell shell rescanPlugins`, which clears Qt's
component cache and reloads the QML from disk.

Without the watcher, apply changes by hand:

```bash
omarchy-shell shell rescanPlugins      # or: omarchy restart shell
```

Edits to `shell.json` need none of this — the shell hot-reloads that on save.

## Layout

```
plugin/     the shell plugin itself (manifest.json + Dock.qml)
bin/        omarchy-dock-config, the interactive configurator
hypr/       dock.lua — blur and layer rules for Hyprland
config/     shell.dock.json — the starter dock entry for shell.json
scripts/    dev-watch.sh — reload the shell while editing
```

## Uninstall

```bash
./uninstall.sh                 # keeps your dock settings in shell.json
./uninstall.sh --purge-config  # drops them too
```

It only removes symlinks that point back into this checkout, so anything you
installed another way is left alone.
