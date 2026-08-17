import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Auto-hiding launcher dock. The window parks just past its screen edge
// (bottom by default; `edge` picks top/left/right, `align` places it along
// that edge) and slides back in when the pointer enters a thin hotspot
// there on whichever monitor it is on.
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

  // ------------------------------------------------------------- position
  //
  // `edge` is the screen edge the dock lives on; `align` places it along
  // that edge — start/center/end read left/centre/right on a horizontal
  // edge and top/middle/bottom on a vertical one. Everything below is
  // written in terms of a *main* axis (along the edge: the flow of icons)
  // and a *cross* axis (out from the edge: card thickness, label band,
  // reveal slide), so a vertical dock is the same layout rotated rather
  // than a second one.
  readonly property string edge: {
    var e = String(config.edge || "").toLowerCase()
    return (e === "top" || e === "left" || e === "right") ? e : "bottom"
  }
  readonly property string align: {
    var a = String(config.align || "").toLowerCase()
    if (a === "left" || a === "top") return "start"
    if (a === "right" || a === "bottom") return "end"
    return (a === "start" || a === "end") ? a : "center"
  }
  readonly property bool vertical: edge === "left" || edge === "right"
  // On left/top the screen edge is at the window's origin, so the edge-gap
  // strip comes *before* the card in window coordinates.
  readonly property bool edgeFirst: edge === "left" || edge === "top"

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

  // The two popups are mutually exclusive: the menu wins (a right-click is
  // deliberate, a dwell is not), and each one's open state is the truth —
  // nothing here mirrors it.
  readonly property bool menuOpen: contextMenu.open
  readonly property int menuIndex: menuOpen && contextMenu.anchorCell ? contextMenu.anchorCell.index : -1
  readonly property bool stackOpen: windowStack.open
  readonly property bool settingsOpen: settingsLoader.item ? settingsLoader.item.opened : false
  // Anything that holds the dock revealed while it's up. Settings counts:
  // its card sits above the bar precisely so live edits show on it.
  readonly property bool popupOpen: menuOpen || stackOpen || settingsOpen

  function openStack(cell) {
    if (menuOpen || dragging) return
    windowStack.openFor(cell)
  }

  function closeStack() { windowStack.close() }

  // Right-click on the icon whose menu is already up toggles it, like the
  // bar's tray menu; on any other icon the menu moves there.
  function openMenu(cell) {
    if (!cell || cell.isRule) return
    if (menuOpen && cell.index === menuIndex) {
      contextMenu.close()
      return
    }
    windowStack.close()
    contextMenu.openFor(cell)
  }

  function closeMenu() { contextMenu.close() }

  // Icon hover while a popup is up, taskbar-style: the stack follows the
  // pointer — a running icon switches it there, a launch-only icon folds it
  // — and moving onto another icon dismisses the menu, so the pointer never
  // has to leave the dock to get out of a menu it opened by mistake.
  function onIconHovered(cell) {
    if (dragging || !cell || cell.isRule) return
    if (menuOpen) {
      if (cell.index !== menuIndex) closeMenu()
      return
    }
    if (!stackOpen) return
    if (cell.wins.length > 0) openStack(cell)
    else closeStack()
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

  function stackReleased() { releasePopup() }

  // Same references in the same order. windowsFor() builds a fresh array
  // per call, so anything that snapshots a window list compares by this
  // before adopting a new one — otherwise every unrelated model tick would
  // rebuild the popup's delegates from scratch.
  function sameWindows(a, b) {
    a = a || []; b = b || []
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
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
  function menuReleased() { releasePopup() }

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
  // Cells are positioned by cellPos rather than a Row/Column, so the layout
  // can open a live gap at the insertion point while something is dragged —
  // the other cells slide aside (Behavior on x/y in DockItem), macOS-style.
  // The card's length never changes mid-drag: the dragged cell keeps its
  // slot in the total, it just leaves the flow.
  //
  // Crossing the divider is the pin gesture: a running app dropped in the
  // pinned zone pins at the drop position; a pinned item dropped past the
  // divider unpins. Both persist through the configurator CLI and come
  // back via the config reload. The derived divider itself is not
  // draggable; spacers are items and move like anything else.
  //
  // All drag coordinates are main-axis: x on a horizontal dock, y on a
  // vertical one.

  property int dragIndex: -1
  property real dragPointer: 0
  property real dragGrabD: 0
  readonly property bool dragging: dragIndex >= 0

  // Main-axis coordinate of a scene point, in the cell's parent's space.
  function mainCoord(cell, sceneX, sceneY) {
    var p = cell.parent.mapFromItem(null, sceneX, sceneY)
    return vertical ? p.y : p.x
  }

  function beginDrag(cell, sceneX, sceneY) {
    // A click-and-hold opens the menu at 0.5s; if the hold then turns into
    // a drag, the menu was a misread — fold it and let the drag through
    // (macOS does the same). The menu's focus grab covers the dock, so the
    // pointer motion that got us here was never in doubt.
    contextMenu.close()
    windowStack.close()
    var r = mainCoord(cell, sceneX, sceneY)
    dragGrabD = r - (vertical ? cell.y : cell.x)
    dragPointer = r
    dragIndex = cell.index
    hoveredLabel = ""
  }

  function updateDrag(cell, sceneX, sceneY) {
    dragPointer = mainCoord(cell, sceneX, sceneY)
  }

  // Insertion slot among the un-dragged cells, from the dragged cell's
  // centre against the base-flow centres (base coords, not the shifted
  // ones — comparing against positions this value itself moves would
  // oscillate).
  readonly property int dropIndex: {
    if (!dragging) return -1
    var draggedCenter = dragPointer - dragGrabD + cellSize(displayItems[dragIndex]) / 2
    var x = 0
    var flow = 0
    var result = 0
    for (var i = 0; i < displayItems.length; i++) {
      if (i === dragIndex) continue
      var w = cellSize(displayItems[i])
      if (draggedCenter > x + w / 2) result = flow + 1
      x += w + gap
      flow++
    }
    return result
  }

  // Main-axis offset for every cell: cumulative flow positions, with a
  // dragged-cell-sized gap held open at dropIndex. The dragged cell's slot
  // reads 0 — its position is bound to the pointer instead.
  readonly property var cellPos: {
    var xs = new Array(displayItems.length)
    var x = 0
    var flow = 0
    var dw = dragging ? cellSize(displayItems[dragIndex]) + gap : 0
    for (var i = 0; i < displayItems.length; i++) {
      if (i === dragIndex) { xs[i] = 0; continue }
      xs[i] = x + (dragging && flow >= dropIndex ? dw : 0)
      x += cellSize(displayItems[i]) + gap
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

  // A cell's extent along the main axis.
  function cellSize(item) {
    return Util.isPlainObject(item) && (item.spacer === true || item.__divider === true)
      ? root.ruleWidth : root.slot
  }

  readonly property int contentLength: {
    var total = 0
    var list = displayItems
    for (var i = 0; i < list.length; i++) total += cellSize(list[i])
    return total + Math.max(0, list.length - 1) * gap
  }

  // Content-sized card. `cardMain` runs along the edge, `cardCross` out
  // from it; cardWidth/cardHeight are the on-screen dimensions those become
  // for the current edge. With `fullWidth` the card stretches along the
  // whole edge instead — computed per window, since monitors differ — and
  // cardMain becomes its floor.
  readonly property bool fullWidth: flag("fullWidth", false)
  readonly property int cardMain: Math.round(
    (vertical ? Border.top(dockBorder) : Border.left(dockBorder)) + pad + contentLength + pad
    + (vertical ? Border.bottom(dockBorder) : Border.right(dockBorder)))
  readonly property int cardCross: Math.round(
    (vertical ? Border.left(dockBorder) : Border.top(dockBorder)) + pad + slot + pad
    + (vertical ? Border.right(dockBorder) : Border.bottom(dockBorder)))
  readonly property int cardWidth: vertical ? cardCross : cardMain
  readonly property int cardHeight: vertical ? cardMain : cardCross

  // The label pill sits in a band on the inward side of the card. The band
  // is part of the window so tooltips are never clipped, but it stays
  // outside the input mask so it cannot swallow clicks meant for the
  // desktop. Beside a vertical dock the band has to be wide enough for the
  // text itself, not just one line tall.
  readonly property int labelHeight: Math.round(Style.font.bodySmall + Style.spacing.sm * 2 + Style.space(2))
  readonly property int labelBand: !labels ? 0
    : vertical ? Style.space(220) + Style.spacing.sm
               : labelHeight + Style.spacing.sm

  // Gap between card and screen edge. The window still reaches the edge —
  // the strip between card and edge is live hover area, so sliding the
  // pointer off the outer side of the dock does not drop the reveal. Left
  // unset it tracks the theme's edge gap; set it to 0 to sit flush.
  readonly property int edgeGap: root.config.edgeGap !== undefined
    ? Style.space(num0("edgeGap", 0))
    : Math.max(Style.gapsOut, Style.space(4))

  // Window extents. Cross: edge strip + card + label band. Main: the card
  // plus slack for a label centred on an end icon to spill into (a vertical
  // dock's labels sit beside the card, so it needs none).
  readonly property int windowCross: labelBand + cardCross + edgeGap
  readonly property int windowMain: cardMain + (labels && !vertical ? Style.space(240) : 0)
  readonly property int windowWidth: vertical ? windowCross : windowMain
  readonly property int windowHeight: vertical ? windowMain : windowCross

  // Where along the cross axis, in window coordinates, the card's edge
  // strip and the card itself begin.
  readonly property int hitCross: edgeFirst ? 0 : labelBand
  readonly property int cardCrossPos: edgeFirst ? edgeGap : labelBand
  // The inward face of the card: where popups and labels hang off.
  readonly property int cardInnerFace: edgeFirst ? edgeGap + cardCross : labelBand

  // Popups (menu, window stack) hang off the card's inward face, centred on
  // the icon along the edge. Gravity is the direction the popup grows in
  // from its 1×1 anchor point; the point sits a small gap inward of the
  // card, in the label band, and is clamped so the popup stays inside the
  // dock window along the edge (the anchor rect must lie within the parent
  // surface — Hyprland misplaces out-of-bounds anchors).
  readonly property int popupGravity: edge === "bottom" ? (Edges.Top | Edges.Right)
                                    : edge === "top"    ? (Edges.Bottom | Edges.Right)
                                    : edge === "left"   ? (Edges.Right | Edges.Bottom)
                                    :                     (Edges.Left | Edges.Bottom)

  function popupAnchorPoint(target, window, popupW, popupH) {
    var pos = window.contentItem.mapFromItem(target, 0, 0)
    var gapIn = Style.spacing.sm
    var across = edgeFirst ? cardInnerFace + gapIn : cardInnerFace - gapIn
    if (vertical) {
      var y = Math.round(pos.y + target.height / 2 - popupH / 2)
      y = Math.max(0, Math.min(y, window.height - popupH))
      return { x: across, y: y }
    }
    var x = Math.round(pos.x + target.width / 2 - popupW / 2)
    x = Math.max(0, Math.min(x, window.width - popupW))
    return { x: x, y: across }
  }

  // Main-axis offset of a card of the given length inside a window of the
  // given length, per `align`. Centre is the layer-shell default placement
  // of the window itself; start/end anchor the window to that side and put
  // the card flush with it.
  function cardMainOffset(winLen, cardLen) {
    if (align === "start") return 0
    if (align === "end") return Math.max(0, winLen - cardLen)
    return Math.round((winLen - cardLen) / 2)
  }

  // ---------------------------------------------------------- reveal state

  // Hover is tallied rather than assigned: moving between the hotspot and
  // the dock, or between monitors, can deliver the enter before the leave,
  // and a plain assignment would strand the dock closed.
  property int hotspotHovers: 0
  property int dockHovers: 0
  property string activeScreen: ""
  property bool revealed: false

  property string hoveredLabel: ""
  // Main-axis centre of the hovered icon, in window coordinates.
  property real hoveredCenter: 0
  readonly property bool wantOpen: active && (hotspotHovers > 0 || dockHovers > 0)

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

  // Settings takes over from any popup and keeps the dock revealed for as
  // long as it's up, so edits land on a bar you can see.
  function openSettings() {
    contextMenu.close()
    windowStack.close()
    settingsLoader.active = true
    if (settingsLoader.item) settingsLoader.item.open()
    holdForPopup()
    revealed = true
  }

  function settingsReleased() { releasePopup() }

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
        edge: root.edge,
        align: root.align,
        vertical: root.vertical,
        fullWidth: root.fullWidth,
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

  // The plain launch path — v1's activate — through the shell's own
  // launcher (uwsm-app + gtk-launch, with its "Launching…" feedback), so a
  // dock launch behaves exactly like one from the app menu: Terminal=
  // entries get a terminal, DBus-activatable apps get activated.
  function launchNew(item, entry) {
    if (!Util.isPlainObject(item)) return
    if (root.flag("hideOnLaunch", true)) root.close()

    if (item.exec) {
      Util.execDetached(String(item.exec))
      return
    }
    if (entry && root.shell && root.shell.appLibrary) {
      root.shell.appLibrary.launch(entry.id, entry.name)
      return
    }
    if (item.desktop) {
      var id = String(item.desktop).replace(/\.desktop$/, "")
      Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
    }
  }

  // The context menu's New Window. Activating a DBus-activatable app that
  // is already running only raises it, so an entry that ships a new-window
  // desktop action (Files, Text Editor, browsers…) runs that action's
  // command instead — the same thing a jump list does. Anything else
  // launches plainly.
  function launchNewWindow(item, entry) {
    var action = root.newWindowAction(entry)
    if (!action) {
      launchNew(item, entry)
      return
    }
    runDesktopAction(entry, action)
  }

  // Run one of an entry's Desktop Actions the way gtk-launch would run the
  // entry itself: through uwsm-app, in the entry's working directory.
  function runDesktopAction(entry, action) {
    if (!action || !action.command || action.command.length < 1) return
    if (root.flag("hideOnLaunch", true)) root.close()
    var argv = ["uwsm-app", "--"]
    for (var i = 0; i < action.command.length; i++) argv.push(String(action.command[i]))
    var spec = { command: argv }
    if (entry && entry.workingDirectory) spec.workingDirectory = String(entry.workingDirectory)
    Quickshell.execDetached(spec)
  }

  function isNewWindowAction(action) {
    var id = String(action && action.id || "").toLowerCase().replace(/_/g, "-")
    return id === "new-window" || id === "newwindow"
  }

  // The entry's runnable Desktop Actions — the freedesktop jump list
  // ("Additional applications actions"). Only for entries that can run
  // outside a terminal: actions inherit Terminal=, and gtk-launch is the
  // only path here that honours it.
  function desktopActions(entry) {
    if (!entry || entry.runInTerminal || !entry.actions) return []
    var out = []
    var list = entry.actions
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      if (!a || !a.command || a.command.length < 1) continue
      out.push(a)
    }
    return out
  }

  // The new-window action, if the entry ships one; the context menu's New
  // Window row runs it instead of a plain launch.
  function newWindowAction(entry) {
    var list = root.desktopActions(entry)
    for (var i = 0; i < list.length; i++)
      if (root.isNewWindowAction(list[i])) return list[i]
    return null
  }

  // Every other action, for the menu's app-specific section.
  function menuActions(entry) {
    return root.desktopActions(entry).filter(function (a) { return !root.isNewWindowAction(a) })
  }

  // ---------------------------------------------------------- reveal zone

  // A sliver along the dock's edge, sized to the dock by default so the
  // reveal zone is exactly where the dock will appear. Lives on the Top
  // layer; the dock itself is on Overlay, so where the two overlap the dock
  // wins the pointer and the hotspot never steals a click.
  Variants {
    model: Quickshell.screens

    delegate: PanelWindow {
      id: hotspotWindow
      required property var modelData

      screen: modelData
      visible: root.active
      color: "transparent"
      // Reserve nothing, but respect what others reserve: the bar's
      // exclusive zone pushes the zone (and the dock) off the bar, so a
      // top or vertical dock lands beside it rather than under it.
      exclusionMode: ExclusionMode.Normal
      exclusiveZone: 0
      WlrLayershell.namespace: "omarchy-dock-hotspot"
      WlrLayershell.layer: WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // A full-length dock gets a full-length trigger zone regardless of
      // the hotspot setting — a centred sliver under a monitor-wide card
      // would be a guessing game. Otherwise the zone follows the card's
      // alignment: anchored to the same side, offset by the same edge gap.
      readonly property bool span: root.hotspotFullWidth || root.fullWidth
      anchors {
        bottom: root.edge === "bottom" || (root.vertical && (span || root.align === "end"))
        top:    root.edge === "top"    || (root.vertical && (span || root.align === "start"))
        left:   root.edge === "left"   || (!root.vertical && (span || root.align === "start"))
        right:  root.edge === "right"  || (!root.vertical && (span || root.align === "end"))
      }
      margins {
        left:   (!root.vertical && !span && root.align === "start") ? root.edgeGap : 0
        right:  (!root.vertical && !span && root.align === "end")   ? root.edgeGap : 0
        top:    (root.vertical  && !span && root.align === "start") ? root.edgeGap : 0
        bottom: (root.vertical  && !span && root.align === "end")   ? root.edgeGap : 0
      }

      implicitWidth:  root.vertical ? root.hotspotHeight : (span ? 0 : root.cardMain)
      implicitHeight: root.vertical ? (span ? 0 : root.cardMain) : root.hotspotHeight

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
      // Zero exclusive zone, but not Ignore: the dock keeps out of the
      // area the bar (or any other panel) has reserved, whichever edge it
      // and the bar are on — see the hotspot above.
      exclusionMode: ExclusionMode.Normal
      exclusiveZone: 0
      WlrLayershell.namespace: "omarchy-dock"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Anchored to its edge. Along the edge, layer-shell centres a surface
      // on any axis it is not anchored to — the `center` alignment for
      // free; start/end anchor that side and offset by the edge gap so the
      // card sits as far from the corner as it does from the edge.
      // Full-length anchors both sides instead, and the card takes the
      // monitor's length minus the edge gap on either flank.
      readonly property bool anchorStart: root.fullWidth || root.align === "start"
      readonly property bool anchorEnd: root.fullWidth || root.align === "end"
      anchors.bottom: root.edge === "bottom" || (root.vertical && anchorEnd)
      anchors.top:    root.edge === "top"    || (root.vertical && anchorStart)
      anchors.left:   root.edge === "left"   || (!root.vertical && anchorStart)
      anchors.right:  root.edge === "right"  || (!root.vertical && anchorEnd)

      // Card length along the edge, and its offset within the window.
      readonly property int winMain: root.vertical ? dockWindow.height : dockWindow.width
      readonly property int cardLen: root.fullWidth
        ? Math.max(root.cardMain, winMain - root.edgeGap * 2)
        : root.cardMain
      readonly property int cardOffset: root.fullWidth
        ? Math.round((winMain - cardLen) / 2)
        : root.cardMainOffset(winMain, cardLen)

      // On-screen card size for this window.
      readonly property int cardW: root.vertical ? root.cardCross : cardLen
      readonly property int cardH: root.vertical ? cardLen : root.cardCross

      implicitWidth: root.windowWidth
      implicitHeight: root.windowHeight

      // Input is confined to the card and the strip between it and the
      // edge. The label band and the empty length either side of the card
      // stay click-through. Bound to explicit bounds rather than `item:` —
      // an item-shaped region never picked up hitArea's geometry.
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

      // Parked = pushed out past its own edge. The start/end margins keep
      // the card an edge gap away from the corner it's aligned to.
      readonly property int park: -Math.round(dockWindow.slide * (root.windowCross + Style.space(6)))
      readonly property int sideGap: (root.fullWidth || root.align === "center") ? 0 : root.edgeGap
      margins {
        bottom: root.edge === "bottom" ? park : (root.vertical  && root.align === "end"   ? sideGap : 0)
        top:    root.edge === "top"    ? park : (root.vertical  && root.align === "start" ? sideGap : 0)
        left:   root.edge === "left"   ? park : (!root.vertical && root.align === "start" ? sideGap : 0)
        right:  root.edge === "right"  ? park : (!root.vertical && root.align === "end"   ? sideGap : 0)
      }

      // The card and the strip of edge gap outside it are one subtree, so
      // the whole reveal region hovers as a unit. As siblings the card sat
      // on top of the hover area and swallowed everything aimed at it.
      Item {
        id: hitArea
        x: root.vertical ? root.hitCross : dockWindow.cardOffset
        y: root.vertical ? dockWindow.cardOffset : root.hitCross
        width:  root.vertical ? root.cardCross + root.edgeGap : dockWindow.cardW
        height: root.vertical ? dockWindow.cardH : root.cardCross + root.edgeGap

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
          // Inside the hit area the card sits away from the edge strip:
          // after it on left/top, before it on right/bottom.
          x: (root.vertical && root.edgeFirst) ? root.edgeGap : 0
          y: (!root.vertical && root.edgeFirst) ? root.edgeGap : 0
          width: dockWindow.cardW
          height: dockWindow.cardH
          radius: root.cardRadius
          // The popup surface, not the raw palette background: a theme that
          // tints its popups should tint the dock the same way.
          color: Util.alpha(Color.popups.background, root.backgroundOpacity)
          borderSpec: root.dockBorder

          opacity: dockWindow.shown ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }

          // A left click on the card is a click outside the menu: the dock
          // sits inside the menu's focus grab (so it keeps hover and taps),
          // which means the grab won't dismiss for us here. Double-clicking
          // the dock's own background opens settings.
          //
          // The default gesture policy takes only a *passive* grab, so this
          // coexists with the per-icon tap handlers rather than stealing
          // their presses. The removed right-click menu used
          // ReleaseWithinBounds, which takes an exclusive grab — the likely
          // reason right-clicking an icon did nothing while the background
          // worked.
          TapHandler {
            acceptedButtons: Qt.LeftButton

            onTapped: root.closeMenu()

            onDoubleTapped: function(eventPoint) {
              // Only the background: double-clicking an icon should launch
              // it twice, not open settings.
              if (root.hitAt(card, row, eventPoint.position.x, eventPoint.position.y) !== -2) return
              root.openSettings()
            }
          }

          // Not a Row/Column: cells place themselves from root.cellPos so
          // a drag can hold a gap open while the others slide aside.
          Item {
            id: row
            anchors.centerIn: parent
            width:  root.vertical ? root.slot : root.contentLength
            height: root.vertical ? root.contentLength : root.slot

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
        height: root.labelHeight
        width: Math.round(tipText.implicitWidth + Style.spacing.xxl * 2)
        // Centred on the hovered icon along the edge, clamped so a label
        // near either end of the dock stays inside the window; on the cross
        // axis it hangs off the card's inward face, in the label band.
        readonly property int along: Math.round(Math.max(Style.spacing.sm,
          Math.min((root.vertical ? dockWindow.height - height : dockWindow.width - width) - Style.spacing.sm,
                   root.hoveredCenter - (root.vertical ? height : width) / 2)))
        readonly property int across: root.edgeFirst
          ? root.cardInnerFace + Style.spacing.sm
          : root.labelBand - Style.spacing.sm - (root.vertical ? width : height)
        x: root.vertical ? across : along
        y: root.vertical ? along : across
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
