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

  width: dock.cellWidth(modelData)
  height: dock.slot

  Component.onCompleted: dock.registerCell(cell)
  Component.onDestruction: dock.unregisterCell(cell)

  Rectangle {
    visible: cell.isRule
    anchors.centerIn: parent
    width: cell.dock.ruleWidth
    height: Math.round(cell.dock.slot * 0.6)
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

    // Grows from its base so the icon lifts out of the dock rather than
    // drifting through it.
    transformOrigin: Item.Bottom
    scale: (cell.dock.magnify && iconHover.hovered) ? 1.18 : 1.0
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

  HoverHandler {
    id: iconHover
    enabled: !cell.isRule
    cursorShape: Qt.PointingHandCursor

    onHoveredChanged: {
      if (hovered) {
        cell.dock.hoveredLabel = cell.label
        // Window coordinates for the label pill: map through whatever
        // containers sit between this cell and the window content item,
        // rather than hardcoding the chain of parents.
        cell.dock.hoveredCenterX = cell.mapToItem(null, cell.width / 2, 0).x
      } else if (cell.dock.hoveredLabel === cell.label) {
        cell.dock.hoveredLabel = ""
      }
    }

    Component.onDestruction: if (hovered && cell.dock.hoveredLabel === cell.label) cell.dock.hoveredLabel = ""
  }

  TapHandler {
    enabled: !cell.isRule
    onTapped: cell.dock.activate(cell.modelData, cell.entry)
  }

  // Separate handler, left at the default (passive) gesture policy — the
  // v1 right-click menu died because ReleaseWithinBounds takes an
  // exclusive grab and starved the per-icon tap handlers.
  TapHandler {
    enabled: !cell.isRule
    acceptedButtons: Qt.RightButton
    onTapped: cell.dock.openMenu(cell)
  }

  // The running indicator: lit for any item with a live window — pinned or
  // not — in the theme accent. "dot" and "line" are the two shapes; "none"
  // turns it off. It sits inside the slot so lighting up never reflows the
  // dock.
  Rectangle {
    visible: !cell.isRule && cell.dock.runningIndicator !== "none" && cell.wins.length > 0
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.bottom: parent.bottom
    anchors.bottomMargin: 2
    width: cell.dock.runningIndicator === "line" ? Math.round(cell.dock.slot * 0.38) : 5
    height: cell.dock.runningIndicator === "line" ? 2 : 5
    radius: cell.dock.runningIndicator === "line" ? 1 : 2.5
    color: Color.accent
  }
}
