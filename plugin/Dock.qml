import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Auto-hiding launcher dock. The window parks just past the bottom edge and
// slides back in when the pointer enters a thin hotspot at the bottom centre
// of whichever monitor it is on.
//
// Parking rather than unmapping mirrors the bar: keeping the layer surface
// and its scene graph alive makes a reveal a margin change instead of a
// surface rebuild.
//
// Every color, radius, font, and spacing value comes from the shell's
// Color/Style singletons, so the dock re-themes with `omarchy theme set`
// with no restart and no generated stylesheet.
//
// Configuration is this plugin's own entry in ~/.config/omarchy/shell.json,
// which the shell re-reads on save, so edits apply live:
//
//   { "id": "rdf.dock", "iconSize": 40, "items": [ ... ] }
//
// Item forms:
//   { "desktop": "chromium" }                     launch a desktop entry
//   { "exec": "omarchy launch terminal",          run any command via bash -lc
//     "icon": "utilities-terminal",
//     "label": "Terminal" }
//   { "exec": "pkill -9 xfreerdp",                a Nerd Font glyph instead
//     "glyph": "󰅖", "label": "Kill RDP" }         of an icon file
//   { "spacer": true }                            divider rule
//
// Any item may carry `"when": "<command>"`, and then holds a slot only while
// that command exits 0 — so a kill switch can be absent until there is
// something to kill.
//
// `exec` wins when an item carries both. `icon` accepts an icon-theme name
// or an absolute path, and overrides the desktop entry's own icon; `glyph`
// in turn wins over `icon`, for entries with no icon on disk to point at —
// or, paired with `desktop`, to launch an app while drawing a Nerd Font
// glyph in the shell's text colour instead of its full-colour icon.
//
// Look: `tiles` (bool) draws a container behind each slot. `tileStyle` is
// "button" (default — painted with the theme's [controls] tokens, with a
// hover state) or "flat" (a wash of the text colour at `tileOpacity`).
// `glyphColor` is "text" (default) or "accent". Corner radii follow the
// shell (`Style.cornerRadius`) unless `cornerRadius` / `tileRadius` are set.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: manifest && manifest.id ? String(manifest.id) : "rdf.dock"

  // This plugin's entry in shell.json plugins[]. Reading shell.shellConfig
  // here is what makes the binding re-evaluate on every shell.json save.
  readonly property var config: {
    var list = shell && shell.shellConfig && Array.isArray(shell.shellConfig.plugins)
      ? shell.shellConfig.plugins
      : []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (Util.isPlainObject(entry) && String(entry.id || "") === root.pluginId) return entry
    }
    return ({})
  }

  function num(key, fallback) {
    var n = Number(root.config[key])
    return isFinite(n) && n > 0 ? n : fallback
  }

  function flag(key, fallback) {
    var v = root.config[key]
    return typeof v === "boolean" ? v : fallback
  }

  // Like num(), but zero is a legitimate value — icons packed edge to edge
  // is a real choice, so spacing and padding accept it.
  function num0(key, fallback) {
    var n = Number(root.config[key])
    return isFinite(n) && n >= 0 ? n : fallback
  }

  // A 0–1 fraction, but anything above 1 is read as a percentage. "90" is a
  // far more natural thing to type into an opacity prompt than "0.9", and
  // there is no ambiguity: no opacity above 1 is meaningful.
  function fraction(key, fallback) {
    var n = Number(root.config[key])
    if (!isFinite(n) || n < 0) return fallback
    if (n > 1) n = n / 100
    return Math.min(1, n)
  }

  // ------------------------------------------------------------- geometry

  readonly property var items: Array.isArray(config.items) ? config.items : []

  // -------------------------------------------------------------- running
  //
  // The v2 half of the dock: which items have live windows, and which live
  // windows belong to no item. See RunningModel.qml for the matching rules.

  readonly property bool showRunning: flag("showRunning", true)
  readonly property string runningIndicator:
    (config.runningIndicator === "line" || config.runningIndicator === "none")
      ? String(config.runningIndicator) : "dot"

  // Icon tinting defaults. Pinned icons stay full-colour unless asked —
  // they're curated. Running-section icons tint by default, because an
  // arbitrary app landing in the dock shouldn't get to break the theme.
  // A per-item `tint` overrides either.
  readonly property bool tintIcons: flag("tintIcons", false)
  readonly property bool tintRunning: flag("tintRunning", true)

  RunningModel {
    id: running
    dock: root
    pinnedItems: root.items
  }

  ContextMenu {
    id: contextMenu
    dock: root
  }

  // Hovering a running icon focuses nothing by default — the stack opens
  // and a click picks the window. hoverActivate:true focuses on row-hover
  // instead, the full macOS behaviour, off because hover-focus steals
  // focus from wherever you were typing.
  readonly property bool hoverActivate: flag("hoverActivate", false)

  WindowStack {
    id: windowStack
    dock: root
  }

  readonly property bool menuOpen: contextMenu.open
  readonly property var menuCell: contextMenu.anchorCell
  property int menuIndex: -1
  readonly property bool stackOpen: windowStack.open
  readonly property bool popupOpen: contextMenu.open || windowStack.open

  property int stackIndex: -1

  function openStack(cell) {
    if (contextMenu.open || dragging) return
    stackIndex = cell.index
    windowStack.openFor(cell)
  }

  function closeStack() { windowStack.close() }

  function openMenu(cell) {
    windowStack.close()
    menuIndex = cell.index
    contextMenu.openFor(cell)
  }

  function closeMenu() { contextMenu.close() }

  function monitorOrigin(screen) {
    var name = screen ? String(screen.name || "") : ""
    var mons = Hyprland.monitors.values || []
    for (var i = 0; i < mons.length; i++) {
      if (String(mons[i].name || "") === name)
        return ({ x: Number(mons[i].x) || 0, y: Number(mons[i].y) || 0 })
    }
    return ({ x: 0, y: 0 })
  }

  function iconIndexAtScreen(sx, sy, screen, cell) {
    var dockWin = cell && cell.QsWindow ? cell.QsWindow.window : null
    if (!dockWin) return -1
    var sw = screen ? screen.width : 0
    var sh = screen ? screen.height : 0
    if (!(sw > 0 && sh > 0)) return -1
    var sl = Math.round((sw - dockWin.width) / 2)
    var st = sh - dockWin.height
    var lx = sx - sl
    var ly = sy - st
    var hitX = Math.round((dockWin.width - cardWidth) / 2)
    var hitY = labelBand
    if (lx < hitX || lx >= hitX + cardWidth) return -1
    if (ly < hitY || ly >= hitY + cardHeight + edgeGap) return -1
    var rowLeft = (cardWidth - contentWidth) / 2
    var x = (lx - hitX) - rowLeft
    var items = displayItems
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      if (Util.isPlainObject(it) && (it.spacer === true || it.__divider === true)) continue
      var cx = cellXs[i] || 0
      var cw = cellWidth(it)
      if (x >= cx && x < cx + cw) return i
    }
    return -1
  }

  // Win11 taskbar hover: thumbnails follow the icon under the pointer.
  // A running icon switches (or opens) the preview; a launch-only icon
  // dismisses it. A right-click menu is left alone — hover must not spawn
  // an empty menu over another tile.
  function onIconHovered(cell) {
    if (dragging || !cell || cell.isRule) return
    if (menuOpen && cell.index !== menuIndex) {
      closeMenu()
      return
    }
    if (menuOpen) return
    if (cell.wins.length > 0) {
      if (stackOpen) openStack(cell)
    } else if (stackOpen) {
      windowStack.close()
    }
  }

  // A popup holds the dock open the same way IPC show() does. Releasing
  // one popup must not drop that hold while the other is still up, and a
  // pointer re-entering the card must not either (onWantOpenChanged would
  // otherwise clear held and the next leave hides the dock).
  function holdForPopup() {
    held = true
    hideTimer.stop()
  }

  function releasePopup() {
    if (popupOpen) return
    held = false
    if (!wantOpen) hideTimer.restart()
  }

  function stackReleased() {
    stackIndex = -1
    releasePopup()
  }

  // Live DockItem instances, for IPC-driven actions (a keybinding or a
  // test opening the menu without a pointer). Mutated in place — nothing
  // binds to it.
  property var cells: []
  function registerCell(cell) { cells.push(cell) }
  function unregisterCell(cell) {
    var i = cells.indexOf(cell)
    if (i >= 0) cells.splice(i, 1)
  }

  function cellAt(index) {
    var match = null
    for (var i = 0; i < cells.length; i++) {
      if (cells[i].index !== index) continue
      match = cells[i]
      // Prefer the copy on the dock's current target screen.
      var w = cells[i].QsWindow.window
      if (w && String(w.screen ? w.screen.name : "") === root.targetScreen) return cells[i]
    }
    return match
  }

  // Called by the menu when it closes: hand the reveal state back to the
  // pointer. If it already left, start the normal hide countdown.
  function menuReleased() {
    menuIndex = -1
    releasePopup()
  }

  // Pin/unpin route through the configurator CLI — the one validated
  // shell.json writer — and the config hot-reload brings the change back.
  function requestPin(item) {
    if (!Util.isPlainObject(item) || !item.appId) return
    Util.execDetached("omarchy-dock-config pin " + Util.shellQuote(String(item.appId)))
  }

  function requestUnpin(item) {
    var idx = items.indexOf(item)
    if (idx < 0) return
    Util.execDetached("omarchy-dock-config unpin " + idx)
  }

  function windowsFor(item) { return running.windowsFor(item) }

  // What the dock actually renders: the pinned items, then — while anything
  // unpinned is running — a divider and the running section. The divider is
  // derived exactly like the section is; neither is ever saved.
  readonly property var displayItems: {
    var out = shownItems.slice()
    if (showRunning) {
      var ex = running.extras
      if (ex.length > 0) {
        out.push({ __divider: true })
        out = out.concat(ex)
      }
    }
    return out
  }

  // ----------------------------------------------------------------- drag
  //
  // Cells are positioned by cellXs rather than a Row, so the layout can
  // open a live gap at the insertion point while something is dragged —
  // the other cells slide aside (Behavior on x in DockItem), macOS-style.
  // The card's width never changes mid-drag: the dragged cell keeps its
  // slot in the total, it just leaves the flow.
  //
  // Crossing the divider is the pin gesture: a running app dropped in the
  // pinned zone pins at the drop position; a pinned item dropped past the
  // divider unpins. Both persist through the configurator CLI and come
  // back via the config reload. The derived divider itself is not
  // draggable; spacers are items and move like anything else.

  property int dragIndex: -1
  property real dragPointerX: 0
  property real dragGrabDX: 0
  readonly property bool dragging: dragIndex >= 0

  function beginDrag(cell, sceneX) {
    var rx = cell.parent.mapFromItem(null, sceneX, 0).x
    dragGrabDX = rx - cell.x
    dragPointerX = rx
    dragIndex = cell.index
    hoveredLabel = ""
  }

  function updateDrag(cell, sceneX) {
    dragPointerX = cell.parent.mapFromItem(null, sceneX, 0).x
  }

  // Insertion slot among the un-dragged cells, from the dragged cell's
  // centre against the base-flow centres (base coords, not the shifted
  // ones — comparing against positions this value itself moves would
  // oscillate).
  readonly property int dropIndex: {
    if (!dragging) return -1
    var draggedCenter = dragPointerX - dragGrabDX + cellWidth(displayItems[dragIndex]) / 2
    var x = 0
    var flow = 0
    var result = 0
    for (var i = 0; i < displayItems.length; i++) {
      if (i === dragIndex) continue
      var w = cellWidth(displayItems[i])
      if (draggedCenter > x + w / 2) result = flow + 1
      x += w + gap
      flow++
    }
    return result
  }

  // x for every cell: cumulative flow positions, with a dragged-cell-sized
  // gap held open at dropIndex. The dragged cell's slot reads 0 — its x is
  // bound to the pointer instead.
  readonly property var cellXs: {
    var xs = new Array(displayItems.length)
    var x = 0
    var flow = 0
    var dw = dragging ? cellWidth(displayItems[dragIndex]) + gap : 0
    for (var i = 0; i < displayItems.length; i++) {
      if (i === dragIndex) { xs[i] = 0; continue }
      xs[i] = x + (dragging && flow >= dropIndex ? dw : 0)
      x += cellWidth(displayItems[i]) + gap
      flow++
    }
    return xs
  }

  function endDrag() {
    if (!dragging) return
    var s = dragIndex
    var t = dropIndex
    dragIndex = -1

    var item = displayItems[s]
    if (!Util.isPlainObject(item)) return

    // Zone boundary: how many un-dragged cells are pinned items. An
    // insertion at exactly that slot is "end of the pinned section";
    // anything past it is the running zone.
    var pinnedFlow = 0
    for (var i = 0; i < displayItems.length; i++) {
      if (i === s) continue
      if (items.indexOf(displayItems[i]) >= 0) pinnedFlow++
    }

    // The items[] index the insertion slot corresponds to: the pinned cell
    // occupying flow slot t, or the end of items[] when t lands on the
    // divider or beyond.
    var insertAt = items.length
    var flow = 0
    for (var j = 0; j < displayItems.length; j++) {
      if (j === s) continue
      if (flow === t) {
        var idx = items.indexOf(displayItems[j])
        if (idx >= 0) insertAt = idx
        break
      }
      flow++
    }

    var from = items.indexOf(item)
    if (from >= 0) {
      if (t > pinnedFlow) {
        // Dropped past the divider: unpin.
        Util.execDetached("omarchy-dock-config unpin " + from)
      } else {
        var to = insertAt > from ? insertAt - 1 : insertAt
        if (to !== from)
          Util.execDetached("omarchy-dock-config move " + from + " " + to)
      }
    } else if (item.__running === true && t <= pinnedFlow) {
      // A running app dropped in the pinned zone pins at that position.
      Util.execDetached("omarchy-dock-config pin "
        + Util.shellQuote(String(item.appId)) + " " + insertAt)
    }
  }

  function cancelDrag() { dragIndex = -1 }

  // ------------------------------------------------------ conditional items
  //
  // An item may carry a `when` command; it occupies a slot only while that
  // command exits 0. A kill switch is clutter for the 99% of the time there
  // is nothing to kill, but exactly what you want for the other 1%.
  //
  // Every condition is evaluated in a single batched subprocess, one line of
  // output per condition, rather than one process each.

  // Indices of items carrying a condition, in item order.
  readonly property var conditionIndices: {
    var out = []
    for (var i = 0; i < items.length; i++) {
      var it = items[i]
      if (Util.isPlainObject(it) && typeof it.when === "string" && it.when.trim() !== "") out.push(i)
    }
    return out
  }

  // index -> bool. Absent means "not yet evaluated", which shows the item:
  // a slow probe should not make the dock flicker on every reveal.
  property var conditionResults: ({})

  function conditionMet(index) {
    var v = conditionResults[index]
    return v === undefined ? true : v === true
  }

  readonly property var shownItems: {
    if (conditionIndices.length === 0) return items
    var out = []
    for (var i = 0; i < items.length; i++) if (conditionMet(i)) out.push(items[i])
    return out
  }

  readonly property bool active: displayItems.length > 0

  function evaluateConditions() {
    if (conditionIndices.length === 0) return
    var lines = []
    for (var i = 0; i < conditionIndices.length; i++) {
      var cmd = String(items[conditionIndices[i]].when)
      // Each condition is wrapped so its own exit status is all that escapes.
      lines.push("if { " + cmd + " ; } >/dev/null 2>&1; then echo 1; else echo 0; fi")
    }
    conditionProc.command = ["bash", "-lc", lines.join("\n")]
    conditionProc.running = true
  }

  onConditionIndicesChanged: evaluateConditions()

  Process {
    id: conditionProc
    property var pending: []

    onRunningChanged: if (running) pending = []

    stdout: SplitParser {
      onRead: function(line) {
        conditionProc.pending.push(String(line).trim() === "1")
      }
    }

    onExited: {
      var next = ({})
      for (var i = 0; i < root.conditionIndices.length; i++) {
        var v = conditionProc.pending[i]
        if (v !== undefined) next[root.conditionIndices[i]] = v
      }
      root.conditionResults = next
    }
  }

  // Cheap enough to poll: one bash invocation on a handful of conditions.
  // Re-checked on reveal too, so an item is never stale by the time it is
  // actually looked at.
  Timer {
    running: root.conditionIndices.length > 0
    interval: 5000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.evaluateConditions()
  }

  // Sizes go through Style.space() so a theme's [spacing] scale moves the
  // dock with the rest of the shell instead of leaving it at a fixed size.
  readonly property int slot: Style.space(num("iconSize", 40))
  // Defaults match Style.spacing.lg / .md, so an unconfigured dock looks
  // exactly as it did before these became tunable.
  readonly property int pad: Style.space(num0("padding", 8))
  readonly property int gap: Style.space(num0("spacing", 6))
  readonly property int ruleWidth: Math.max(1, Style.space(1))

  // Icons are drawn in identical boxes but carry wildly different amounts of
  // transparent padding, and a square logo reads far larger than a circle at
  // the same box size. A per-item `iconScale` corrects both; the TUI can
  // compute them from each icon's painted area. Glyphs are handled
  // automatically below, since their ink is measurable at runtime.
  // `glyphScale` is the glyph's ink height as a fraction of the slot; like
  // the opacities, anything above 1 is read as a percentage.
  readonly property real glyphInkTarget: fraction("glyphScale", 0.58) > 0 ? fraction("glyphScale", 0.58) : 0.58

  // Per-icon container tiles, and the three opacities.
  readonly property bool tiles: flag("tiles", false)
  // Tiles come in two styles. "button" (the default) paints each slot like a
  // shell Button — the theme's [controls] fill and border tokens at rest,
  // the hover-cursor tokens under the pointer — so the dock reads as one
  // more piece of the shell kit. "flat" is the older look: a plain wash of
  // the popup text colour at `tileOpacity`, no border, no hover state.
  // Setting `tileOpacity` at all selects "flat", so existing configs keep
  // their appearance.
  readonly property string tileStyle: (root.config.tileStyle === "flat" || root.config.tileOpacity !== undefined)
    ? "flat" : "button"
  readonly property real tileOpacity: fraction("tileOpacity", 0.16)
  readonly property real tileInset: fraction("tileInset", 0.76)
  readonly property real backgroundOpacity: fraction("backgroundOpacity", 1.0)
  readonly property real iconOpacity: fraction("iconOpacity", 1.0)

  // Glyph ink at rest: "text" (popup text colour) or "accent". Under the
  // pointer a glyph always takes the accent, matching how a hovered control
  // lights up elsewhere in the shell.
  readonly property color glyphColor: root.config.glyphColor === "accent" ? Color.accent : Color.popups.text

  // Left unset the dock matches Hyprland's window rounding, like the rest of
  // the shell. Set it to round the card independently — worth doing when the
  // tiles are on, since a square card around rounded tiles reads as a
  // mistake. Concentric corners want outer = inner + padding.
  readonly property int cardRadius: root.config.cornerRadius !== undefined
    ? Style.space(num0("cornerRadius", 0))
    : Style.cornerRadius

  // Tile rounding. Left unset it follows the shell's corner radius exactly
  // like every Button does, so a square theme gets square tiles. Set
  // `tileRadius` (a fraction of the slot) to round them independently.
  readonly property int tileRadiusPx: root.config.tileRadius !== undefined
    ? Math.round(root.slot * fraction("tileRadius", 0.23))
    : Style.cornerRadius

  // The radius that would sit concentric with the tiles, for the TUI to offer.
  readonly property int concentricRadius: root.tileRadiusPx + root.pad

  readonly property bool labels: flag("labels", true)
  readonly property bool magnify: flag("magnify", true)
  // Stay up on a monitor whose active workspace holds no windows — there is
  // nothing to hide from, and it makes an empty workspace a launcher.
  readonly property bool showWhenEmpty: flag("showWhenEmpty", false)
  readonly property bool hotspotFullWidth: flag("hotspotFullWidth", false)
  readonly property int hotspotHeight: Math.max(1, Style.space(num("hotspotHeight", 2)))
  readonly property int revealDelay: Math.round(num("revealDelay", 90))
  readonly property int hideDelay: Math.round(num("hideDelay", 350))

  // Turning the border off has to go through the spec rather than just
  // hiding it: the card's width and height are measured from the border
  // widths, so a hidden-but-present border would leave a gap where it was.
  readonly property var dockBorder: flag("border", true)
    ? Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    : Border.none()
  readonly property var tipBorder: Border.surfaceSpec("tooltip", "border", Color.tooltip.border, Math.max(1, Style.space(1)))

  function cellWidth(item) {
    return Util.isPlainObject(item) && (item.spacer === true || item.__divider === true)
      ? root.ruleWidth : root.slot
  }

  readonly property int contentWidth: {
    var total = 0
    var list = displayItems
    for (var i = 0; i < list.length; i++) total += cellWidth(list[i])
    return total + Math.max(0, list.length - 1) * gap
  }

  // Content-sized card width. With `fullWidth` the card stretches to the
  // monitor instead — computed per window, since monitors differ — and
  // this value becomes its floor.
  readonly property bool fullWidth: flag("fullWidth", false)
  readonly property int cardWidth: Math.round(Border.left(dockBorder) + pad + contentWidth + pad + Border.right(dockBorder))
  readonly property int cardHeight: Math.round(Border.top(dockBorder) + pad + slot + pad + Border.bottom(dockBorder))

  // The label pill sits in a band above the card. The band is part of the
  // window so tooltips are never clipped, but it stays outside the input
  // mask so it cannot swallow clicks meant for the desktop.
  readonly property int labelHeight: Math.round(Style.font.bodySmall + Style.spacing.sm * 2 + Style.space(2))
  readonly property int labelBand: labels ? labelHeight + Style.spacing.sm : 0

  // Gap between card and screen edge. The window still reaches the edge —
  // the strip below the card is live hover area, so sliding the pointer off
  // the bottom of the dock does not drop the reveal. Left unset it tracks
  // the theme's edge gap; set it to 0 to sit flush against the edge.
  readonly property int edgeGap: root.config.edgeGap !== undefined
    ? Style.space(num0("edgeGap", 0))
    : Math.max(Style.gapsOut, Style.space(4))

  readonly property int windowHeight: labelBand + cardHeight + edgeGap
  readonly property int windowWidth: cardWidth + (labels ? Style.space(240) : 0)

  // ---------------------------------------------------------- reveal state

  // Hover is tallied rather than assigned: moving between the hotspot and
  // the dock, or between monitors, can deliver the enter before the leave,
  // and a plain assignment would strand the dock closed.
  property int hotspotHovers: 0
  property int dockHovers: 0
  property string activeScreen: ""
  property bool revealed: false

  property string hoveredLabel: ""
  property real hoveredCenterX: 0
  readonly property bool wantOpen: active && (hotspotHovers > 0 || dockHovers > 0
    || (menuOpen && contextMenu.hovered))

  // True when the named output's active workspace holds no windows.
  // `toplevels` tracks live windows, so a binding on this flips the moment
  // the last window closes or the first one opens.
  function screenEmpty(name) {
    var monitors = Hyprland.monitors.values || []
    for (var i = 0; i < monitors.length; i++) {
      if (String(monitors[i].name || "") !== name) continue
      var ws = monitors[i].activeWorkspace
      if (!ws || !ws.toplevels) return false
      return (ws.toplevels.values || []).length === 0
    }
    return false
  }

  // Which monitor the dock belongs to right now. Hovering an edge names it
  // outright; a summon over IPC has no pointer to go on, so it falls back to
  // the focused monitor.
  readonly property string targetScreen: {
    if (root.activeScreen !== "") return root.activeScreen
    var focused = Hyprland.focusedMonitor
    return focused ? String(focused.name || "") : ""
  }

  // Held open by IPC rather than by the pointer. Parking is animated, so a
  // hover-loss from a previous hide can land *after* a summon and take the
  // dock straight back down; the hold outlives that stray event.
  property bool held: false

  onWantOpenChanged: {
    if (wantOpen) {
      // A real hover supersedes an IPC hold, so moving away closes it
      // normally — but not a popup hold. Clearing that here is what hid
      // the dock the moment the pointer left the card for the menu.
      if (!root.popupOpen) held = false
      hideTimer.stop()
      revealTimer.restart()
    } else {
      revealTimer.stop()
      hideTimer.restart()
    }
  }

  onRevealedChanged: {
    if (revealed) evaluateConditions()
    else {
      hoveredLabel = ""
      // The popups anchor to the dock; a dock that hides from under them
      // (hideOnLaunch via another item, IPC hide, settings opening) would
      // leave them floating over bare desktop. Hiding closes them, on
      // every hide path, because this is the hide path.
      contextMenu.close()
      windowStack.close()
    }
  }

  Timer {
    id: revealTimer
    interval: root.revealDelay
    onTriggered: root.revealed = true
  }

  Timer {
    id: hideTimer
    interval: root.hideDelay
    onTriggered: if (!root.held) root.revealed = false
  }

  function close() {
    revealTimer.stop()
    hideTimer.stop()
    held = false
    revealed = false
  }

  // Which slot a point on the card lands on, or -2 for the dock's own
  // background — a gap between icons, a divider, or the padding.
  function hitAt(card, row, cardX, cardY) {
    var inRow = row.mapFromItem(card, cardX, cardY)
    var hit = row.childAt(inRow.x, inRow.y)
    return (hit && hit.index !== undefined && !hit.isRule) ? hit.index : -2
  }

  // The settings GUI lives behind a Loader so the dock's startup cost
  // doesn't grow — it only instantiates on first open. (It can't be a
  // second manifest entry point: the shell loads exactly one per plugin,
  // and `panel` outranks `overlay`.) The gum TUI stays available as
  // `omarchy-dock-config` in a terminal — same plumbing, SSH-friendly.
  Loader {
    id: settingsLoader
    active: false
    sourceComponent: SettingsPanel { dock: root }
  }

  function openSettings() {
    contextMenu.close()
    windowStack.close()
    settingsLoader.active = true
    if (settingsLoader.item) settingsLoader.item.open()
    // Stay revealed so live edits are visible behind/below the settings card.
    holdForPopup()
    revealed = true
  }

  function onSettingsClosed() {
    if (popupOpen) return
    held = false
    if (!wantOpen) hideTimer.restart()
  }

  function open() {
    revealTimer.stop()
    hideTimer.stop()
    held = true
    revealed = true
  }

  // Lets a keybinding summon the dock without reaching for the edge, and
  // makes the reveal state inspectable when something misbehaves.
  //   omarchy-shell rdf.dock toggle
  IpcHandler {
    target: "rdf.dock"

    function show(): string { root.open(); return "ok" }
    function hide(): string { root.close(); return "ok" }
    function toggle(): string { if (root.revealed) root.close(); else root.open(); return "ok" }
    // Fire a dock slot without the pointer, so a keybinding can reach one.
    // Slots are 1-based and count spacers, matching the items[] order.
    function launch(slot: string): string {
      var i = Math.round(Number(slot)) - 1
      if (!(i >= 0 && i < root.items.length)) return "no such slot"
      var item = root.items[i]
      root.activate(item, root.desktopEntry(item))
      return "ok"
    }

    function settings(): string { root.openSettings(); return "ok" }

    // Open the context menu on a display slot (1-based, counting rules),
    // so a test or keybinding can reach it without the pointer.
    function menu(slot: string): string {
      var i = Math.round(Number(slot)) - 1
      if (!(i >= 0 && i < root.displayItems.length)) return "no such slot"
      var cell = root.cellAt(i)
      if (!cell) return "no cell"
      root.open()
      root.openMenu(cell)
      return "ok"
    }

    function menuClose(): string { contextMenu.close(); return "ok" }

    // Same pointer-free access for the window stack.
    function stack(slot: string): string {
      var i = Math.round(Number(slot)) - 1
      if (!(i >= 0 && i < root.displayItems.length)) return "no such slot"
      var cell = root.cellAt(i)
      if (!cell) return "no cell"
      if (root.windowsFor(root.displayItems[i]).length < 1) return "not running"
      root.open()
      root.openStack(cell)
      return "ok"
    }

    function stackClose(): string { windowStack.close(); return "ok" }

    function settingsClose(): string {
      if (settingsLoader.item) settingsLoader.item.close()
      return "ok"
    }

    function settingsState(): string {
      var p = settingsLoader.item
      if (!p) return "not loaded"
      return JSON.stringify({ opened: p.opened, sel: p.selIndex, dirty: p.dirty,
                              glyphs: p.glyphList.length, apps: p.appEntries.length })
    }

    function state(): string {
      return JSON.stringify({
        active: root.active,
        items: root.items.length,
        shown: root.shownItems.length,
        display: root.displayItems.length,
        menuOpen: contextMenu.open,
        menuRows: contextMenu.rows.length,
        showRunning: root.showRunning,
        runningIndicator: root.runningIndicator,
        running: (function() {
          var out = []
          var ex = running.extras
          for (var i = 0; i < ex.length; i++)
            out.push(ex[i].appId + ":" + root.windowsFor(ex[i]).length)
          return out
        })(),
        pinnedRunning: (function() {
          var out = []
          for (var i = 0; i < root.items.length; i++) {
            var n = root.windowsFor(root.items[i]).length
            if (n > 0) out.push(root.itemLabel(root.items[i], root.desktopEntry(root.items[i])) + ":" + n)
          }
          return out
        })(),
        conditions: root.conditionResults,
        revealed: root.revealed,
        hotspotHovers: root.hotspotHovers,
        dockHovers: root.dockHovers,
        activeScreen: root.activeScreen,
        targetScreen: root.targetScreen,
        showWhenEmpty: root.showWhenEmpty,
        border: root.flag("border", true),
        edgeGap: root.edgeGap,
        cardWidth: root.cardWidth,
        cardHeight: root.cardHeight,
        tiles: root.tiles,
        tileStyle: root.tileStyle,
        tileOpacity: root.tileOpacity,
        tileRadius: root.tileRadiusPx,
        cardRadius: root.cardRadius,
        concentricRadius: root.concentricRadius,
        backgroundOpacity: root.backgroundOpacity,
        iconOpacity: root.iconOpacity,
        emptyScreens: (function() {
          var out = []
          var screens = Quickshell.screens || []
          for (var i = 0; i < screens.length; i++) {
            var n = String(screens[i].name || "")
            if (root.screenEmpty(n)) out.push(n)
          }
          return out
        })()
      })
    }
  }

  // ------------------------------------------------------------ item model

  function desktopEntry(item) {
    if (!Util.isPlainObject(item)) return null
    var want = String(item.desktop || "").replace(/\.desktop$/, "")
    if (!want) return null
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry && String(entry.id || "").replace(/\.desktop$/, "") === want) return entry
    }
    return null
  }

  function itemLabel(item, entry) {
    if (!Util.isPlainObject(item)) return ""
    if (item.label) return String(item.label)
    if (entry && entry.name) return String(entry.name)
    if (item.desktop) return String(item.desktop)
    return ""
  }

  function itemIcon(item, entry) {
    var name = Util.isPlainObject(item) && item.icon
      ? String(item.icon)
      : (entry && entry.icon ? String(entry.icon) : "")
    // AppLibrary's lookup indexes app/device icons by name and re-scans as
    // packages land, so it resolves names Qt's themed lookup misses.
    var library = root.shell ? root.shell.appLibrary : null
    if (library) return library.iconSource(name)
    if (name.charAt(0) === "/") return Util.fileUrl(name)
    return Quickshell.iconPath(name || "application-x-executable", true)
  }

  function activate(item, entry) {
    if (!Util.isPlainObject(item)) return

    // Anything with a live window focuses it — most-recently-used first,
    // wherever its workspace is — rather than launching a duplicate. A
    // second copy is one right-click away; a lost window never is.
    var wins = root.windowsFor(item)
    if (wins.length > 0) {
      if (root.flag("hideOnLaunch", true)) root.close()
      wins[0].activate()
      return
    }

    launchNew(item, entry)
  }

  // Desktop action named new-window / new_window, if the entry has one.
  // gtk-launch + DBusActivatable (Nautilus, etc.) only Activate()s the
  // existing instance; the action's Exec is what actually opens another.
  function newWindowAction(entry) {
    if (!entry || !entry.actions) return null
    var list = entry.actions
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      if (!a) continue
      var id = String(a.id || "").toLowerCase().replace(/_/g, "-")
      if (id === "new-window" || id === "newwindow") return a
    }
    return null
  }

  function runDesktopCommand(command, cwd) {
    if (!command || command.length < 1) return false
    var argv = ["uwsm-app", "--"]
    for (var i = 0; i < command.length; i++) argv.push(String(command[i]))
    var spec = { command: argv }
    if (cwd) spec.workingDirectory = String(cwd)
    Quickshell.execDetached(spec)
    return true
  }

  // The plain launch path — v1's activate. Also what the context menu's
  // New Window uses, which is why it ignores live windows.
  function launchNew(item, entry) {
    if (!Util.isPlainObject(item)) return
    if (root.flag("hideOnLaunch", true)) root.close()

    var action = root.newWindowAction(entry)
    if (action && root.runDesktopCommand(action.command, entry.workingDirectory))
      return

    if (item.exec) {
      Util.execDetached(String(item.exec))
      return
    }
    // Prefer the desktop Exec over gtk-launch: DBus-activated apps
    // treat a second launch as "focus me", which is the opposite of
    // New Window. Nautilus's Exec is already `nautilus --new-window`.
    if (entry && root.runDesktopCommand(entry.command, entry.workingDirectory))
      return
    if (item.desktop) {
      var id = String(item.desktop).replace(/\.desktop$/, "")
      Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
    }
  }

  // ---------------------------------------------------------- reveal zone

  // A sliver at the bottom edge, sized to the dock by default so the reveal
  // zone is exactly where the dock will appear. Lives on the Top layer; the
  // dock itself is on Overlay, so where the two overlap the dock wins the
  // pointer and the hotspot never steals a click.
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: hotspotWindow
      required property var modelData

      screen: modelData
      visible: root.active
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-dock-hotspot"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      anchors {
        bottom: true
        // A full-width dock gets a full-width trigger zone regardless of
        // the hotspot setting — a centred sliver under a monitor-wide
        // card would be a guessing game.
        left: root.hotspotFullWidth || root.fullWidth
        right: root.hotspotFullWidth || root.fullWidth
      }

      implicitWidth: (root.hotspotFullWidth || root.fullWidth) ? 0 : root.cardWidth
      implicitHeight: root.hotspotHeight

      // The handler needs an Item to attach to; a pointer handler parented
      // straight to the window never receives anything.
      Item {
        anchors.fill: parent

        HoverHandler {
          id: hotspotHover
          property bool counted: false

          onHoveredChanged: {
            if (hovered === counted) return
            counted = hovered
            root.hotspotHovers += hovered ? 1 : -1
            if (hovered) root.activeScreen = String(hotspotWindow.modelData.name || "")
          }

          // Unplugging a monitor destroys its hotspot without a leave event,
          // which would strand the tally and hold the dock open for good.
          Component.onDestruction: if (counted) root.hotspotHovers -= 1
        }
      }
    }
  }

  // ---------------------------------------------------------------- dock

  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: dockWindow
      required property var modelData

      readonly property string screenName: String(modelData.name || "")

      // Asks about the workspace on *this* output, not the focused one.
      readonly property bool pinnedOpen: root.showWhenEmpty && root.screenEmpty(screenName)

      // With several monitors the dock appears only on the one being asked
      // for; the empty-target case means we could not tell, so show it here
      // rather than nowhere.
      readonly property bool shown: pinnedOpen
        || (root.revealed && (root.targetScreen === "" || root.targetScreen === screenName))

      screen: modelData
      visible: root.active
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "omarchy-dock"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Bottom only: layer-shell centres a surface on any axis it is not
      // anchored to, which is exactly the placement we want. Full-width
      // anchors both sides instead, and the card takes the monitor's
      // width minus the edge gap on either flank.
      anchors.bottom: true
      anchors.left: root.fullWidth
      anchors.right: root.fullWidth

      readonly property int cardW: root.fullWidth
        ? Math.max(root.cardWidth, dockWindow.width - root.edgeGap * 2)
        : root.cardWidth

      implicitWidth: root.windowWidth
      implicitHeight: root.windowHeight

      // Input is confined to the card and the strip beneath it. The label
      // band and the empty width either side of it stay click-through.
      // Bound to explicit bounds rather than `item:` — an item-shaped region
      // never picked up hitArea's geometry.
      mask: Region {
        x: hitArea.x
        y: hitArea.y
        width: hitArea.width
        height: hitArea.height
      }

      // 0 = docked, 1 = parked off-screen.
      property real slide: dockWindow.shown ? 0 : 1
      Behavior on slide {
        NumberAnimation { duration: 190; easing.type: Easing.OutCubic }
      }

      margins {
        bottom: -Math.round(dockWindow.slide * (root.windowHeight + Style.space(6)))
      }

      // The card and the strip of edge gap below it are one subtree, so the
      // whole reveal region hovers as a unit. As siblings the card sat on
      // top of the hover area and swallowed everything aimed at it.
      Item {
        id: hitArea
        x: Math.round((dockWindow.width - dockWindow.cardW) / 2)
        y: root.labelBand
        width: dockWindow.cardW
        height: root.cardHeight + root.edgeGap

        HoverHandler {
          id: dockHover
          property bool counted: false

          onHoveredChanged: {
            if (hovered === counted) return
            counted = hovered
            root.dockHovers += hovered ? 1 : -1
            if (hovered) root.activeScreen = dockWindow.screenName
          }

          Component.onDestruction: if (counted) root.dockHovers -= 1
        }

        BorderSurface {
          id: card
          x: 0
          y: 0
          width: dockWindow.cardW
          height: root.cardHeight
          radius: root.cardRadius
          // The popup surface, not the raw palette background: a theme that
          // tints its popups should tint the dock the same way.
          color: Util.alpha(Color.popups.background, root.backgroundOpacity)
          borderSpec: root.dockBorder

          opacity: dockWindow.shown ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }

          // Double-clicking the dock's own background opens the settings TUI.
          //
          // The default gesture policy takes only a *passive* grab, so this
          // coexists with the per-icon tap handlers rather than stealing
          // their presses. The removed right-click menu used
          // ReleaseWithinBounds, which takes an exclusive grab — the likely
          // reason right-clicking an icon did nothing while the background
          // worked.
          HoverHandler {
            enabled: root.menuOpen
            onPointChanged: {
              if (!root.menuOpen) return
              var idx = root.hitAt(card, row, point.position.x, point.position.y)
              if (idx !== root.menuIndex) root.closeMenu()
            }
          }

          TapHandler {
            acceptedButtons: Qt.LeftButton

            onTapped: function(eventPoint) {
              if (root.menuOpen) root.closeMenu()
            }

            onDoubleTapped: function(eventPoint) {
              // Only the background: double-clicking an icon should launch
              // it twice, not open settings.
              if (root.hitAt(card, row, eventPoint.position.x, eventPoint.position.y) !== -2) return
              root.openSettings()
            }
          }

          // Not a Row: cells place themselves from root.cellXs so a drag
          // can hold a gap open while the others slide aside.
          Item {
            id: row
            anchors.centerIn: parent
            width: root.contentWidth
            height: root.slot

            Repeater {
              model: root.displayItems

              // The slot itself lives in DockItem.qml; Repeater fills
              // modelData/index, the root comes along explicitly.
              delegate: DockItem { dock: root }
            }
          }
        }
      }

      BorderSurface {
        id: tip
        visible: root.labels && dockWindow.shown && root.hoveredLabel !== "" && !root.dragging
        y: 0
        height: root.labelHeight
        width: Math.round(tipText.implicitWidth + Style.spacing.xxl * 2)
        // Centred on the hovered icon, clamped so a label near either end of
        // a wide dock stays inside the window.
        x: Math.round(Math.max(Style.spacing.sm,
             Math.min(dockWindow.width - width - Style.spacing.sm,
                      root.hoveredCenterX - width / 2)))
        // The tooltip picks up the card's rounding so the two read as one
        // component, capped since a small pill can't take a large radius.
        radius: Math.min(root.cardRadius, Math.round(root.labelHeight / 2))
        color: Util.alpha(Color.background, 0.97)
        borderSpec: root.tipBorder

        Text {
          id: tipText
          anchors.centerIn: parent
          text: root.hoveredLabel
          color: Color.tooltip.text
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
