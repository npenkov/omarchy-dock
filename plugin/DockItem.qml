import QtQuick
import qs.Commons
import qs.Ui

// One dock slot: a spacer rule, or a tile carrying a glyph or an icon.
//
// Everything stylistic comes off the plugin root (`dock`) so the item stays
// a pure view: measure, paint, report hover, forward taps. The split from
// Dock.qml is layout-neutral — same geometry, same handlers, same paint.
Item {
  id: cell

  // The plugin root. Repeater fills modelData/index.
  required property var dock
  required property var modelData
  required property int index

  readonly property bool isSpacer: Util.isPlainObject(modelData) && modelData.spacer === true
  // The derived rule between the pinned and running sections. Drawn like a
  // spacer, slightly stronger, and just as inert.
  readonly property bool isDivider: Util.isPlainObject(modelData) && modelData.__divider === true
  readonly property bool isRule: isSpacer || isDivider
  // A synthesized running-section item (see RunningModel.extras).
  readonly property bool isRunning: Util.isPlainObject(modelData) && modelData.__running === true
  readonly property var entry: isRunning ? (modelData.__entry || null) : dock.desktopEntry(modelData)
  readonly property string label: dock.itemLabel(modelData, entry)
  // This item's live windows, MRU-first. Empty for launch-only items.
  readonly property var wins: isRule ? [] : dock.windowsFor(modelData)

  // Whether this item's icon is colorized to the theme. Per-item `tint`
  // wins; otherwise running-section items follow tintRunning and pinned
  // ones tintIcons. Glyphs are already ink-coloured and ignore all of it.
  readonly property bool tinted: {
    var t = Util.isPlainObject(modelData) ? modelData.tint : undefined
    if (typeof t === "boolean") return t
    return isRunning ? dock.tintRunning : dock.tintIcons
  }
  // A Nerd Font glyph standing in for an icon file. Plenty of worthwhile
  // dock entries — a script, an RDP session, a kill switch — have no icon
  // on disk to point at.
  readonly property string glyph: Util.isPlainObject(modelData) && modelData.glyph
    ? String(modelData.glyph) : ""

  // Optical size correction for this item, clamped so a bad value can't
  // blow an icon out of the dock.
  readonly property real iconScale: {
    var n = Util.isPlainObject(modelData) ? Number(modelData.iconScale) : NaN
    return isFinite(n) && n > 0 ? Math.max(0.5, Math.min(1.6, n)) : 1.0
  }

  // Glyph ink is measurable, unlike an icon's alpha, so glyphs normalise
  // themselves: measure the tight bounding box at a reference size, then
  // pick the size that lands the ink at the target fraction of the slot.
  TextMetrics {
    id: glyphMetrics
    font.family: Style.font.resolvedFamily
    font.pixelSize: cell.dock.slot
    text: cell.glyph
  }

  readonly property int glyphSize: {
    var ink = glyphMetrics.tightBoundingRect.height
    if (!(ink > 0)) return Math.round(dock.slot * 0.66)
    var target = dock.slot * dock.glyphInkTarget * cell.iconScale
    return Math.max(1, Math.round(dock.slot * target / ink))
  }

  // The slot is `slot` across the dock and cellSize() along it.
  width:  dock.vertical ? dock.slot : dock.cellSize(modelData)
  height: dock.vertical ? dock.cellSize(modelData) : dock.slot

  // Placed by the dock's flow layout along the main axis; while dragged,
  // glued to the pointer instead, riding above the others.
  readonly property bool dragged: dock.dragging && dock.dragIndex === cell.index
  readonly property real pos: dragged ? dock.dragPointer - dock.dragGrabD : (dock.cellPos[cell.index] || 0)
  x: dock.vertical ? 0 : pos
  y: dock.vertical ? pos : 0
  z: dragged ? 10 : 0
  Behavior on x {
    enabled: !cell.dragged
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }
  Behavior on y {
    enabled: !cell.dragged
    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
  }

  Component.onCompleted: dock.registerCell(cell)
  Component.onDestruction: {
    dock.unregisterCell(cell)
    // A config reload can rebuild cells mid-drag; drop the drag rather
    // than act on a stale index.
    if (cell.dragged) dock.cancelDrag()
  }

  Rectangle {
    visible: cell.isRule
    anchors.centerIn: parent
    width:  cell.dock.vertical ? Math.round(cell.dock.slot * 0.6) : cell.dock.ruleWidth
    height: cell.dock.vertical ? cell.dock.ruleWidth : Math.round(cell.dock.slot * 0.6)
    color: Util.alpha(Color.popups.text, cell.isDivider ? 0.4 : 0.25)
  }

  // Tile and artwork share one parent so the hover magnify scales them
  // together instead of the icon sliding around inside a stationary tile.
  Item {
    id: art
    visible: !cell.isRule
    anchors.centerIn: parent
    width: cell.dock.slot
    height: cell.dock.slot

    // Grows from its base — the side facing the screen edge — so the icon
    // lifts out of the dock rather than drifting through it. Suppressed
    // while anything is being dragged — cells sliding under the pointer
    // would pulse otherwise.
    transformOrigin: cell.dock.edge === "top"   ? Item.Top
                   : cell.dock.edge === "left"  ? Item.Left
                   : cell.dock.edge === "right" ? Item.Right
                   : Item.Bottom
    scale: (cell.dock.magnify && iconHover.hovered && !cell.dock.dragging) ? 1.18 : 1.0
    Behavior on scale {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    // The uniform container. Icons come in circles, squares and bare
    // glyphs; a tile behind every one of them is what makes a row of
    // mismatched artwork read as a single set.
    //
    // In "button" style the tile is painted with the same tokens as
    // qs.Ui.Button — [controls] normal fill/border at rest, hover-cursor
    // fill/border under the pointer — so whatever a theme does to its
    // buttons happens here too.
    BorderSurface {
      id: tile
      visible: cell.dock.tiles
      anchors.fill: parent
      radius: cell.dock.tileRadiusPx
      readonly property bool button: cell.dock.tileStyle === "button"
      readonly property bool hot: iconHover.hovered
      color: !button ? Util.alpha(Color.popups.text, cell.dock.tileOpacity)
           : hot     ? Style.hoverFillFor(Color.popups.text, Color.accent)
                     : Style.normalFillFor(Color.popups.text, Color.accent)
      borderSpec: !button ? Border.none()
                : hot     ? Border.controlSpec("hover-cursor", Color.popups.text, Color.accent)
                          : Border.controlSpec("normal", Color.popups.text, Color.accent)
      Behavior on color { ColorAnimation { duration: 120 } }
    }

    // Inside a tile the artwork sits inset; without one it uses the whole
    // slot as before.
    readonly property int box: Math.round(
      cell.dock.slot * (cell.dock.tiles ? cell.dock.tileInset : 1.0) * cell.iconScale)

    Text {
      visible: cell.glyph !== ""
      anchors.centerIn: parent
      text: cell.glyph
      color: iconHover.hovered ? Color.accent : cell.dock.glyphColor
      Behavior on color { ColorAnimation { duration: 120 } }
      opacity: cell.dock.iconOpacity
      font.family: Style.font.resolvedFamily
      font.pixelSize: cell.dock.tiles
        ? Math.round(cell.glyphSize * cell.dock.tileInset)
        : cell.glyphSize
    }

    TintedIcon {
      visible: cell.glyph === ""
      anchors.centerIn: parent
      width: art.box
      height: art.box
      opacity: cell.dock.iconOpacity
      source: (cell.isRule || cell.glyph !== "") ? "" : cell.dock.itemIcon(cell.modelData, cell.entry)
      // Oversampled so the hover scale stays crisp on raster icons.
      sourceOversample: cell.dock.slot * 2
      tinted: cell.tinted
      ink: iconHover.hovered ? Color.accent : cell.dock.glyphColor
    }
  }

  // Drag-to-reorder (and, across the divider, drag-to-pin/unpin). The
  // handler's default activation threshold is what keeps a sloppy click a
  // click. target: null — the dock's flow layout owns all positioning.
  //
  // No modifier gate: the dock's layer surface takes no keyboard focus
  // (WlrKeyboardFocus.None), so the compositor never sends it modifier
  // state and Shift/Ctrl read as unpressed here. Disambiguation from the
  // click-and-hold menu is by motion instead — see the TapHandler below.
  //
  // Once a hold has opened the menu (holdMenu), motion across the dock is
  // the sweep into the menu, not a drag: the cross axis is disabled, so
  // mostly-across motion never activates this handler, while mostly-along
  // motion still does and folds the menu as before. Past the card's inward
  // face (sweeping) the handler is off for the rest of the press — inside
  // the menu the pointer roams freely in every direction.
  DragHandler {
    id: dragHandler
    enabled: !cell.isDivider && !cell.sweeping
    target: null
    xAxis.enabled: !(cell.holdMenu && cell.dock.vertical)
    yAxis.enabled: !(cell.holdMenu && !cell.dock.vertical)

    onActiveChanged: {
      if (active) cell.dock.beginDrag(cell, centroid.scenePosition.x, centroid.scenePosition.y)
      else cell.dock.endDrag()
    }

    onCentroidChanged: if (active) cell.dock.updateDrag(cell, centroid.scenePosition.x, centroid.scenePosition.y)
  }

  // Hover dwell for the window stack: a running icon held under the
  // pointer for a beat opens the preview stack. Leaving before the dwell
  // fires cancels it; once a stack is up it follows the pointer without a
  // dwell (dock.onIconHovered), and a menu keeps it shut.
  Timer {
    id: stackDwell
    interval: 300
    onTriggered: {
      if (iconHover.hovered && cell.wins.length > 0 && !cell.dock.dragging && !cell.dock.menuOpen)
        cell.dock.openStack(cell)
    }
  }

  HoverHandler {
    id: iconHover
    enabled: !cell.isRule
    cursorShape: Qt.PointingHandCursor

    onHoveredChanged: {
      if (hovered) cell.dock.onIconHovered(cell)
      if (hovered && cell.wins.length > 0 && !cell.dock.popupOpen)
        stackDwell.restart()
      else stackDwell.stop()
      if (cell.dock.dragging) return
      if (hovered) {
        cell.dock.hoveredLabel = cell.label
        // Window coordinates for the label pill: map through whatever
        // containers sit between this cell and the window content item,
        // rather than hardcoding the chain of parents.
        var c = cell.mapToItem(null, cell.width / 2, cell.height / 2)
        cell.dock.hoveredCenter = cell.dock.vertical ? c.y : c.x
      } else if (cell.dock.hoveredLabel === cell.label) {
        cell.dock.hoveredLabel = ""
      }
    }

    Component.onDestruction: if (hovered && cell.dock.hoveredLabel === cell.label) cell.dock.hoveredLabel = ""
  }

  TapHandler {
    enabled: !cell.isRule
    // The pin badge sits inside this handler's area; a press there is the
    // badge's, not a launch. Checked by hover rather than an exclusive
    // grab — grabs are how the v1 right-click menu broke.
    onTapped: if (!pinHover.hovered) cell.dock.activate(cell.modelData, cell.entry)

    // Click-and-hold is the trackpad-friendly route to the context menu
    // (macOS dock behaviour). Qt suppresses `tapped` on the release that
    // follows a long press, so holding never also launches. Hold vs drag
    // is settled by motion alone: moving past the drag threshold before
    // 0.5s cancels this handler (DragHandler's exclusive grab), and moving
    // after the menu is up folds it again (dock.beginDrag) — so a hold
    // that turns into a drag never leaves a menu behind.
    longPressThreshold: 0.5
    onLongPressed: {
      if (pinHover.hovered || cell.dock.dragging) return
      stackDwell.stop()
      cell.dock.openMenu(cell)
      // A hold on the icon whose menu is already up toggles it shut; only a
      // hold that actually opened it can sweep into it.
      cell.holdMenu = cell.dock.menuOpen && cell.dock.menuIndex === cell.index
    }
  }

  // Click-and-hold, continued: with the menu up and the button still down,
  // the pointer can travel into the menu, highlight a row and release on it
  // to run it — the same as clicking it. Releasing anywhere else leaves the
  // menu exactly as a stationary hold does.
  //
  // The press is the dock surface's: the compositor's implicit grab routes
  // every move and the release back here even once the pointer is over
  // the popup, and the popup itself never sees them. PointHandler is the
  // handler that keeps reporting a pressed point after it strays outside
  // the item, and being passive it coexists with the tap and drag handlers.
  property bool holdMenu: false   // this press opened the menu
  property bool sweeping: false   // and the pointer has crossed into menu territory

  PointHandler {
    id: holdPoint
    enabled: !cell.isRule
    acceptedButtons: Qt.LeftButton

    onPointChanged: {
      if (!active || !cell.holdMenu || cell.dock.dragging) return
      var win = cell.QsWindow.window
      if (!win) return
      var p = win.contentItem.mapFromItem(null, point.scenePosition.x, point.scenePosition.y)
      if (cell.dock.menuSweep(cell, win, p.x, p.y)) cell.sweeping = true
    }

    onActiveChanged: {
      if (active) return
      if (cell.holdMenu) cell.dock.menuSweepRelease(cell)
      cell.holdMenu = false
      cell.sweeping = false
    }
  }

  // Pin badge: running-section items only, revealed by hover. One click
  // writes the item into items[] through the configurator CLI, and the
  // config reload moves the icon left of the divider — where it now stays.
  Rectangle {
    id: pinBadge
    readonly property bool shown: cell.isRunning && iconHover.hovered && !cell.dock.dragging
    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    width: Math.max(15, Math.round(cell.dock.slot * 0.4))
    height: width
    radius: width / 2
    anchors.right: art.right
    anchors.top: art.top
    anchors.rightMargin: Math.round(-width * 0.2)
    anchors.topMargin: Math.round(-height * 0.2)
    color: pinHover.hovered ? Color.accent : Util.alpha(Color.accent, 0.9)
    // A hairline of the card colour so the badge reads as sitting on top
    // of the artwork rather than fused to it.
    border.width: 1
    border.color: Color.popups.background

    Text {
      anchors.centerIn: parent
      text: "󰐃"
      color: Color.popups.background
      font.family: Style.font.resolvedFamily
      font.pixelSize: Math.round(parent.width * 0.62)
    }

    HoverHandler { id: pinHover; enabled: pinBadge.shown }
    TapHandler {
      enabled: pinBadge.shown
      onTapped: cell.dock.requestPin(cell.modelData)
    }
  }

  // Separate handler, left at the default (passive) gesture policy — the
  // v1 right-click menu died because ReleaseWithinBounds takes an
  // exclusive grab and starved the per-icon tap handlers.
  TapHandler {
    enabled: !cell.isRule
    acceptedButtons: Qt.RightButton
    onTapped: {
      stackDwell.stop()
      cell.dock.openMenu(cell)
    }
  }

  // The running indicator: lit for any item with a live window — pinned or
  // not — in the theme accent. "dot" and "line" are the two shapes; "none"
  // turns it off. It sits inside the slot, on the side facing the screen
  // edge, so lighting up never reflows the dock.
  Rectangle {
    readonly property bool line: cell.dock.runningIndicator === "line"
    readonly property int along: line ? Math.round(cell.dock.slot * 0.38) : 5
    readonly property int across: line ? 2 : 5
    visible: !cell.isRule && cell.dock.runningIndicator !== "none" && cell.wins.length > 0
    // Explicit geometry rather than anchors: swapping anchor sets when the
    // edge changes left one stale, and a verticalCenter+bottom pair
    // stretched the indicator over the whole tile.
    x: cell.dock.vertical
      ? (cell.dock.edge === "left" ? 2 : parent.width - width - 2)
      : Math.round((parent.width - width) / 2)
    y: cell.dock.vertical
      ? Math.round((parent.height - height) / 2)
      : (cell.dock.edge === "top" ? 2 : parent.height - height - 2)
    width:  cell.dock.vertical ? across : along
    height: cell.dock.vertical ? along : across
    radius: line ? 1 : 2.5
    color: Color.accent
  }

  // Count badge on grouped icons. It shares the top-right corner with the
  // pin badge, which only exists on hover — so the count yields to it then.
  Rectangle {
    readonly property bool shown: !cell.isRule && cell.wins.length > 1 && !pinBadge.shown
    visible: opacity > 0
    opacity: shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 120 } }

    height: Math.max(14, Math.round(cell.dock.slot * 0.32))
    width: Math.max(height, Math.round(countText.implicitWidth + height * 0.45))
    radius: height / 2
    anchors.right: art.right
    anchors.top: art.top
    anchors.rightMargin: Math.round(-height * 0.2)
    anchors.topMargin: Math.round(-height * 0.2)
    color: Color.accent
    border.width: 1
    border.color: Color.popups.background

    Text {
      id: countText
      anchors.centerIn: parent
      text: cell.wins.length
      color: Color.popups.background
      font.family: Style.font.resolvedFamily
      font.pixelSize: Math.round(parent.height * 0.68)
      font.bold: true
    }
  }
}
