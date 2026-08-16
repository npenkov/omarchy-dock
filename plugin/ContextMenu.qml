import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Fullscreen Overlay with an invisible click-away pad (input comes from
// `mask`, not pixel alpha). Card sits on the same anchor as WindowStack.
//
// Exclusive keyboard is what made only Esc/item-click work (it swallowed
// every other surface). This window is OnDemand; Escape still works via
// forceActiveFocus. Another icon is detected by cursor polling so we do
// not depend on the dock receiving hover.
Item {
  id: menu

  required property var dock

  property var item: null
  property var entry: null
  property var anchorCell: null
  property var menuScreen: null
  property bool open: false
  property bool hovered: menuHover.hovered
  property int cardX: 0
  property int cardY: 0
  property var wins: []
  property var rows: []

  readonly property var liveWins: open && item ? dock.windowsFor(item) : []
  onLiveWinsChanged: adoptWins(open ? liveWins : [])

  function sameRefs(a, b) {
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }

  function adoptWins(next) {
    next = next || []
    if (sameRefs(wins, next)) return
    wins = next.slice()
    rebuildRows()
  }

  readonly property bool launchable: Util.isPlainObject(item)
    && (item.exec !== undefined || item.desktop !== undefined || entry !== null)

  readonly property bool isRunningItem: Util.isPlainObject(item) && item.__running === true

  function openFor(cell) {
    menu.item = cell.modelData
    menu.entry = cell.entry
    menu.anchorCell = cell
    var win = cell.QsWindow ? cell.QsWindow.window : null
    if (win && win.screen) menu.menuScreen = win.screen
    menu.open = true
    // Always rebuild rows on open. adoptWins() no-ops when both the
    // previous and new window lists are empty (launch-only icons), which
    // left rows=[] — the empty box on other icons.
    var next = dock.windowsFor(cell.modelData) || []
    menu.wins = next.slice()
    menu.rebuildRows()
    menu.dock.holdForPopup()
    menu.place()
    Qt.callLater(function() {
      if (!menu.open) return
      menu.place()
      keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    if (!menu.open) return
    menu.open = false
    menu.wins = []
    menu.rows = []
    menu.dock.menuReleased()
  }

  function place() {
    if (!open || !anchorCell) return
    var dockWin = anchorCell.QsWindow ? anchorCell.QsWindow.window : null
    if (!dockWin) return
    var sw = menuScreen ? menuScreen.width : panel.width
    var sh = menuScreen ? menuScreen.height : panel.height
    if (!(sw > 0 && sh > 0)) return
    // Same anchor as WindowStack: 1×1 point just above the dock card,
    // centered on the icon, menu growing upward.
    var pos = dockWin.contentItem.mapFromItem(anchorCell, 0, 0)
    var w = Math.max(1, card.implicitWidth)
    var h = Math.max(1, card.implicitHeight)
    var ox = Math.round((sw - dockWin.width) / 2)
    var x = Math.round(ox + pos.x + anchorCell.width / 2 - w / 2)
    x = Math.max(0, Math.min(x, sw - w))
    var anchorY = dockWin.height - menu.dock.cardHeight - menu.dock.edgeGap - Style.spacing.sm
    var y = Math.round((sh - dockWin.height) + anchorY - h)
    y = Math.max(0, Math.min(y, sh - h))
    if (cardX !== x) cardX = x
    if (cardY !== y) cardY = y
  }

  function windowLabel(i) {
    var w = wins[i]
    return String((w && (w.title || w.appId)) || "window")
  }

  function rebuildRows() {
    if (!open) { rows = []; return }
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
        out.push({ kind: "window", glyph: "󱂬", winIndex: i })
    }
    if (wins.length > 0) {
      out.push({ kind: "sep" })
      out.push({ kind: "action", glyph: "󰅖",
                 label: wins.length > 1 ? "Close All Windows" : "Close Window", act: "close-wins" })
    }
    out.push({ kind: "sep" })
    out.push({ kind: "action", glyph: "󰒓", label: "Dock Settings…", act: "settings", dim: true })
    rows = out
  }

  function run(row) {
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

  function considerCursor(gx, gy) {
    if (!open) return
    var o = dock.monitorOrigin(menuScreen)
    var sx = gx - o.x
    var sy = gy - o.y
    if (sx >= cardX && sx <= cardX + card.width && sy >= cardY && sy <= cardY + card.height)
      return
    var idx = dock.iconIndexAtScreen(sx, sy, menuScreen, anchorCell)
    if (idx === dock.menuIndex) return
    if (idx >= 0) menu.close()
  }

  readonly property int pad: Style.spacing.sm
  readonly property var menuBorder: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  FontMetrics {
    id: fm
    font.family: Style.font.resolvedFamily
    font.pixelSize: Style.font.bodySmall
  }

  readonly property int glyphColumn: Style.space(22)
  readonly property int rowWidth: {
    var w = wins.length > 0 ? Style.space(220) : Style.space(150)
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].kind === "sep" || rows[i].kind === "window") continue
      w = Math.max(w, fm.advanceWidth(String(rows[i].label || "")))
    }
    return Math.min(Math.round(w), Style.space(300)) + glyphColumn + Style.spacing.lg * 2
  }

  Timer {
    interval: 70
    running: menu.open
    repeat: true
    onTriggered: {
      cursorQuery.running = false
      cursorQuery.running = true
    }
  }

  Process {
    id: cursorQuery
    running: false
    command: ["hyprctl", "-j", "cursorpos"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var j = JSON.parse(text)
          menu.considerCursor(Number(j.x), Number(j.y))
        } catch (e) {}
      }
    }
  }

  PanelWindow {
    id: panel
    visible: menu.open && menu.rows.length > 0
    screen: menu.menuScreen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-dock-menu"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: menu.open ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { item: dismissPad }

    Item {
      id: dismissPad
      anchors.fill: parent
      TapHandler {
        onTapped: function(eventPoint) {
          var p = card.mapFromItem(null, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
          if (p.x < 0 || p.y < 0 || p.x > card.width || p.y > card.height)
            menu.close()
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: menu.open
      Keys.onEscapePressed: function(event) {
        menu.close()
        event.accepted = true
      }
    }

    BorderSurface {
      id: card
      x: menu.cardX
      y: menu.cardY
      implicitWidth: Math.round(column.implicitWidth + menu.pad * 2
                                + Border.left(menu.menuBorder) + Border.right(menu.menuBorder))
      implicitHeight: Math.round(column.implicitHeight + menu.pad * 2
                                 + Border.top(menu.menuBorder) + Border.bottom(menu.menuBorder))
      width: implicitWidth
      height: implicitHeight
      radius: Math.min(menu.dock.cardRadius, Style.cornerRadius)
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: menu.menuBorder

      onImplicitWidthChanged: menu.place()
      onImplicitHeightChanged: menu.place()

      HoverHandler {
        id: menuHover
        onHoveredChanged: if (hovered) menu.dock.holdForPopup()
      }

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
              text: row.modelData.kind === "window"
                      ? menu.windowLabel(row.modelData.winIndex)
                      : (row.modelData.label || "")
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
}
