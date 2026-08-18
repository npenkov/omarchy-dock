import QtQuick
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Right-click menu for a dock item, anchored above its tile.
//
// Dismissal is the shell's own PopupCard scheme: a HyprlandFocusGrab routes
// input to the menu and the dock while open, so a click anywhere else
// clears the grab and the menu closes. Because the dock stays inside the
// grab it keeps its own hover and taps: right-clicking another icon moves
// the menu there, right-clicking the same icon toggles it, a left click on
// any icon dismisses it and activates as usual, and hovering another icon
// dismisses it (Dock.onIconHovered). Every action closes it too — the menu
// never persists. The dock is held open for as long as the menu is up and
// released on close so auto-hide resumes.
PopupWindow {
  id: menu

  required property var dock

  // Set by openFor(): the item under the pointer and its cell.
  property var item: null
  property var entry: null
  property var anchorCell: null
  property bool open: false

  // Live windows for the item, snapshotted by reference. windowsFor()
  // allocates a fresh array on every evaluation, and binding rows straight
  // to it rebuilt the Repeater — and dropped the hovered row's highlight —
  // on every unrelated model tick.
  property var wins: []
  readonly property var liveWins: open && item ? dock.windowsFor(item) : []
  onLiveWinsChanged: adoptWins(liveWins)

  function adoptWins(next) {
    next = next || []
    if (dock.sameWindows(wins, next)) return
    wins = next.slice()
  }

  // Launchable = the click-when-not-running path exists. Synthesized
  // running items without a desktop entry have windows but no way to open
  // another; they get no New Window row.
  readonly property bool launchable: Util.isPlainObject(item)
    && (item.exec !== undefined || item.desktop !== undefined || entry !== null)

  readonly property bool isRunningItem: Util.isPlainObject(item) && item.__running === true

  // A pinned desktop-entry item with a jump list can name one of its
  // actions as what a plain click runs (`"action"` in shell.json). Only
  // pinned items have a slot to write to; exec items have no jump list.
  readonly property bool canChooseClick: Util.isPlainObject(item) && !isRunningItem
    && item.exec === undefined && entry !== null
    && dock.menuActions(entry).length > 0 && dock.items.indexOf(item) >= 0

  // The action a click currently runs, or null for the plain launch.
  readonly property var clickAction: open ? dock.defaultAction(item, entry) : null

  // While true the menu shows the click-default picker instead of its rows.
  property bool choosing: false

  function openFor(cell) {
    // The Repeater hands each cell a *converted copy* of its item, so
    // cell.modelData never satisfies dock.items.indexOf(). Anything that
    // writes back by slot (Unpin, Click Opens…) needs the canonical object,
    // which is what dock.displayItems holds at the cell's index.
    var canonical = dock.displayItems[cell.index]
    menu.item = canonical !== undefined ? canonical : cell.modelData
    menu.entry = cell.entry
    menu.anchorCell = cell
    menu.choosing = false
    menu.adoptWins(dock.windowsFor(cell.modelData))
    if (menu.open) {
      // Switching icons under an open menu: same surface, new anchor.
      menu.anchor.updateAnchor()
      return
    }
    menu.open = true
    menu.dock.holdForPopup()
  }

  function close() {
    if (!menu.open) return
    menu.open = false
    menu.choosing = false
    menu.dock.menuReleased()
  }

  // Swap between the menu and the click-default picker in place. The row
  // count changes, so the popup re-anchors once its new size has settled.
  function setChoosing(on) {
    menu.choosing = on
    Qt.callLater(function() { if (menu.open) menu.anchor.updateAnchor() })
  }

  // The row model. Rebuilt on every open and whenever the window list
  // moves under an open menu.
  readonly property var rows: {
    if (!open) return []
    var out = []
    var acts = dock.menuActions(entry)
    var cur = clickAction
    var curId = cur ? String(cur.id || "") : ""

    if (choosing) {
      // The picker: the plain launch, then every action; the marked row is
      // what a click runs now. Picking writes and closes; Back returns.
      out.push({ kind: "action", glyph: curId === "" ? "󰄴" : "󰄰",
                 label: "Open " + (dock.appLabel(item, entry) || "the app"),
                 act: "click-action", actionId: "" })
      for (var c = 0; c < acts.length; c++) {
        var cid = String(acts[c].id || "")
        out.push({ kind: "action", glyph: cid === curId ? "󰄴" : "󰄰",
                   label: String(acts[c].name || acts[c].id || "Action"),
                   act: "click-action", actionId: cid })
      }
      out.push({ kind: "sep" })
      out.push({ kind: "action", glyph: "󰁍", label: "Back", act: "back", dim: true })
      return out
    }

    // The app's own Desktop Actions first — its jump list (a browser's
    // private window, an RDP manager's saved hosts…) is the reason to
    // right-click an icon; the dock's own rows follow. The action a plain
    // click runs, if one is set, wears the pointer glyph.
    if (acts.length > 0) {
      for (var a = 0; a < acts.length; a++) {
        var isClick = curId !== "" && String(acts[a].id || "") === curId
        out.push({ kind: "action", glyph: isClick ? "󰍽" : "󰅂",
                   label: String(acts[a].name || acts[a].id || "Action"),
                   act: "desktop-action", actionIndex: a })
      }
      out.push({ kind: "sep" })
    }
    if (launchable)
      out.push({ kind: "action", glyph: "󰐕", label: "New Window", act: "launch" })
    if (isRunningItem)
      out.push({ kind: "action", glyph: "󰐃", label: "Pin to Dock", act: "pin" })
    else if (launchable)
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
    if (canChooseClick)
      out.push({ kind: "action", glyph: "󰍽", label: "Click Opens…", act: "choose-click", dim: true })
    out.push({ kind: "action", glyph: "󰒓", label: "Dock Settings…", act: "settings", dim: true })
    return out
  }

  function run(row) {
    // The picker swaps rows in place; everything else closes the menu.
    if (row.act === "choose-click") { menu.setChoosing(true); return }
    if (row.act === "back") { menu.setChoosing(false); return }

    // Snapshot before close() clears the context.
    var theItem = menu.item
    var theEntry = menu.entry
    var theWins = menu.wins.slice()
    menu.close()

    if (row.act === "desktop-action") {
      var acts = menu.dock.menuActions(theEntry)
      if (acts[row.actionIndex]) menu.dock.runDesktopAction(theEntry, acts[row.actionIndex])
    }
    else if (row.act === "click-action") menu.dock.requestClickAction(theItem, row.actionId)
    else if (row.act === "launch") menu.dock.launchNewWindow(theItem, theEntry)
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
  // size from children's actual geometry. Window titles are elided rather
  // than measured, so a long title widens the menu to the cap, not beyond.
  readonly property int glyphColumn: Style.space(22)
  readonly property int rowWidth: {
    var w = wins.length > 0 ? Style.space(220) : Style.space(150)
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind !== "action") continue
      w = Math.max(w, fm.advanceWidth(String(rows[i].label || "")))
    }
    return Math.min(Math.round(w), Style.space(300)) + glyphColumn + Style.spacing.lg * 2
  }

  implicitWidth: Math.round(column.implicitWidth + pad * 2 + Border.left(menuBorder) + Border.right(menuBorder))
  implicitHeight: Math.round(column.implicitHeight + pad * 2 + Border.top(menuBorder) + Border.bottom(menuBorder))

  // Outside-click dismissal, exactly as PopupCard does it: while active,
  // input is routed only to the menu and the dock; a click anywhere else
  // clears the grab and we close.
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

  // The popup grows inward from a 1×1 anchor point just off the dock card,
  // centred on the icon — see Dock.popupAnchorPoint for the geometry and
  // why it's a point rather than a rect beyond the dock.
  anchor {
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: menu.dock.popupGravity
    window: menu.anchorCell ? menu.anchorCell.QsWindow.window : null

    onAnchoring: {
      var target = menu.anchorCell
      var window = target ? target.QsWindow.window : null
      if (!window) return
      var p = menu.dock.popupAnchorPoint(target, window, menu.implicitWidth, menu.implicitHeight)
      anchor.rect.x = p.x
      anchor.rect.y = p.y
      anchor.rect.width = 1
      anchor.rect.height = 1
    }
  }

  BorderSurface {
    id: card
    anchors.fill: parent
    radius: Math.min(menu.dock.cardRadius, Style.cornerRadius)
    color: Util.alpha(Color.popups.background, 0.97)
    borderSpec: menu.menuBorder

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
            visible: !row.isSep
            x: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.glyph || ""
            color: row.hot ? Color.accent : Util.alpha(Color.popups.text, row.modelData.dim ? 0.6 : 1)
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            visible: !row.isSep
            x: Style.spacing.lg + menu.glyphColumn
            anchors.verticalCenter: parent.verticalCenter
            text: row.modelData.label || ""
            color: row.hot ? Color.accent : Util.alpha(Color.popups.text, row.modelData.dim ? 0.6 : 1)
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            width: menu.rowWidth - x - Style.spacing.lg
          }

          HoverHandler { id: rowHover; enabled: !row.isSep }
          TapHandler { enabled: !row.isSep; onTapped: menu.run(row.modelData) }
        }
      }
    }
  }
}
