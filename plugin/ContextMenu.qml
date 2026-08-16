import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Right-click menu for a dock item, anchored above its tile.
//
// Dismissal is the shell's own PopupCard scheme: a HyprlandFocusGrab routes
// input to the menu and the dock while open, so a click anywhere else
// clears the grab and the menu closes. Every action closes it too — the
// menu never persists. The dock is held open (`dock.held`) for as long as
// the menu is up, and released on close so auto-hide resumes.
PopupWindow {
  id: menu

  required property var dock

  // Set by openFor(): the item under the pointer and its cell.
  property var item: null
  property var entry: null
  property var anchorCell: null
  property bool open: false

  // Live windows for the item — re-evaluated while the menu is up, so a
  // window closing underneath us drops out of the list immediately.
  readonly property var wins: open && item ? dock.windowsFor(item) : []

  // Launchable = the click-when-not-running path exists. Synthesized
  // running items without a desktop entry have windows but no way to open
  // another; they get no New Window row.
  readonly property bool launchable: Util.isPlainObject(item)
    && (item.exec !== undefined || item.desktop !== undefined || entry !== null)

  readonly property bool isRunningItem: Util.isPlainObject(item) && item.__running === true

  function openFor(cell) {
    menu.item = cell.modelData
    menu.entry = cell.entry
    menu.anchorCell = cell
    menu.open = true
    menu.dock.held = true
  }

  function close() {
    if (!menu.open) return
    menu.open = false
    menu.dock.menuReleased()
  }

  // The row model. Rebuilt on every open and whenever the window list
  // moves under an open menu.
  readonly property var rows: {
    if (!open) return []
    var out = []
    if (launchable)
      out.push({ kind: "action", glyph: "󰐕", label: "New Window", act: "launch" })
    if (isRunningItem)
      out.push({ kind: "action", glyph: "󰐃", label: "Pin to Dock", act: "pin" })
    else if (!isRunningItem && launchable)
      out.push({ kind: "action", glyph: "󰐃", label: "Unpin", act: "unpin" })
    if (wins.length > 1) {
      out.push({ kind: "sep" })
      for (var i = 0; i < wins.length; i++)
        out.push({ kind: "window", glyph: "󱂬", label: String(wins[i].title || wins[i].appId || "window"), winIndex: i })
    }
    if (wins.length > 0) {
      out.push({ kind: "sep" })
      out.push({ kind: "action", glyph: "󰅖",
                 label: wins.length > 1 ? "Close All Windows" : "Close Window", act: "close-wins" })
    }
    out.push({ kind: "sep" })
    out.push({ kind: "action", glyph: "󰒓", label: "Dock Settings…", act: "settings", dim: true })
    return out
  }

  function run(row) {
    // Snapshot before close() clears the context.
    var theItem = menu.item
    var theEntry = menu.entry
    var theWins = menu.wins.slice()
    menu.close()

    if (row.act === "launch") menu.dock.launchNew(theItem, theEntry)
    else if (row.act === "pin") menu.dock.requestPin(theItem)
    else if (row.act === "unpin") menu.dock.requestUnpin(theItem)
    else if (row.act === "close-wins") { for (var i = 0; i < theWins.length; i++) theWins[i].close() }
    else if (row.act === "settings") menu.dock.openSettings()
    else if (row.kind === "window" && theWins[row.winIndex]) theWins[row.winIndex].activate()
  }

  visible: open
  color: "transparent"

  readonly property int pad: Style.spacing.sm
  readonly property var menuBorder: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  FontMetrics {
    id: fm
    font.family: Style.font.resolvedFamily
    font.pixelSize: Style.font.bodySmall
  }

  // Row width, measured from the model rather than the delegates. Sizing a
  // row off the Column (or the Column off row widths it set itself) is a
  // layout cycle that quietly resolves at zero — positioners take implicit
  // size from children's actual geometry.
  readonly property int glyphColumn: Style.space(22)
  readonly property int rowWidth: {
    var w = Style.space(150)
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "sep") continue
      w = Math.max(w, fm.advanceWidth(String(rows[i].label || "")))
    }
    return Math.min(Math.round(w), Style.space(300)) + glyphColumn + Style.spacing.lg * 2
  }

  implicitWidth: Math.round(column.implicitWidth + pad * 2 + Border.left(menuBorder) + Border.right(menuBorder))
  implicitHeight: Math.round(column.implicitHeight + pad * 2 + Border.top(menuBorder) + Border.bottom(menuBorder))

  HyprlandFocusGrab {
    active: menu.open
    windows: {
      var out = [menu]
      var w = menu.anchorCell ? menu.anchorCell.QsWindow.window : null
      if (w) out.push(w)
      return out
    }
    onCleared: menu.close()
  }

  // The anchor rect must sit inside the parent surface — the xdg-popup
  // spec leaves out-of-bounds rects undefined, and Hyprland does indeed
  // place them somewhere surprising. So: a 1x1 point just above the card's
  // top edge, with gravity Top, and the popup grows upward from it.
  anchor {
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Top | Edges.Right
    window: menu.anchorCell ? menu.anchorCell.QsWindow.window : null

    onAnchoring: {
      var target = menu.anchorCell
      var window = target ? target.QsWindow.window : null
      if (!window) return
      var pos = window.contentItem.mapFromItem(target, 0, 0)
      var x = Math.round(pos.x + target.width / 2 - menu.implicitWidth / 2)
      // Keep the menu on-screen for cells near either end of the dock.
      x = Math.max(0, Math.min(x, window.width - menu.implicitWidth))
      anchor.rect.x = x
      anchor.rect.y = Math.round(window.height - menu.dock.cardHeight - menu.dock.edgeGap
                                 - Style.spacing.sm)
      anchor.rect.width = 1
      anchor.rect.height = 1
    }
  }

  BorderSurface {
    anchors.fill: parent
    radius: Math.min(menu.dock.cardRadius, Style.cornerRadius)
    color: Util.alpha(Color.popups.background, 0.97)
    borderSpec: menu.menuBorder

    // Esc closes when the popup grab gives us the keyboard; the focus grab
    // still covers dismissal when it doesn't.
    focus: true
    Keys.onEscapePressed: menu.close()

    Column {
      id: column
      x: Border.left(menu.menuBorder) + menu.pad
      y: Border.top(menu.menuBorder) + menu.pad

      Repeater {
        model: menu.rows

        delegate: Item {
          id: row
          required property var modelData

          readonly property bool isSep: modelData.kind === "sep"
          readonly property bool hot: rowHover.hovered && !isSep

          implicitHeight: isSep ? Style.spacing.sm * 2 + 1
                                : Math.round(Style.font.bodySmall + Style.spacing.md * 2 + Style.spacing.xs * 2)
          width: menu.rowWidth

          Rectangle {
            visible: row.isSep
            anchors.verticalCenter: parent.verticalCenter
            x: Style.spacing.md
            width: parent.width - Style.spacing.md * 2
            height: 1
            color: Util.alpha(Color.popups.text, 0.2)
          }

          Rectangle {
            visible: row.hot
            anchors.fill: parent
            radius: Math.max(2, Math.round(Style.cornerRadius / 2))
            color: Util.alpha(Color.accent, 0.16)
          }

          Text {
            id: rowGlyph
            visible: !row.isSep
            x: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.glyph || ""
            color: row.hot ? Color.accent : Util.alpha(Color.popups.text, row.modelData.dim ? 0.6 : 1)
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: rowText
            visible: !row.isSep
            x: Style.spacing.lg + menu.glyphColumn
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.label || ""
            color: row.hot ? Color.accent : Util.alpha(Color.popups.text, row.modelData.dim ? 0.6 : 1)
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            // Window titles can be arbitrarily long; rowWidth caps them and
            // the elide keeps the overflow readable.
            width: menu.rowWidth - x - Style.spacing.lg
          }

          HoverHandler { id: rowHover; enabled: !row.isSep }
          TapHandler { enabled: !row.isSep; onTapped: menu.run(row.modelData) }
        }
      }
    }
  }
}
