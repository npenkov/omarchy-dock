import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The window stack: hover-dwell on a grouped icon (more than one window of
// one app) opens a vertical run of live previews above the tile — one
// ScreencopyView per window, streaming only while the stack is open, with
// the window title beneath. Click focuses that window. `hoverActivate`
// makes row-hover focus it macOS-style; it defaults off, because
// hover-focus steals focus from wherever you were typing.
//
// Same anchoring and grab scheme as the context menu, plus hover-out: the
// stack also closes when the pointer has left both it and the dock for a
// beat.
PopupWindow {
  id: stack

  required property var dock

  property var item: null
  property var anchorCell: null
  property bool open: false

  // Re-evaluated live so a window closing under the stack drops its row.
  readonly property var wins: open && item ? dock.windowsFor(item) : []

  // A window closing can collapse the group to one — nothing left to
  // stack, so fold.
  onWinsChanged: if (open && wins.length < 2) close()

  function openFor(cell) {
    stack.item = cell.modelData
    stack.anchorCell = cell
    stack.open = true
    stack.dock.held = true
  }

  function close() {
    if (!stack.open) return
    stack.open = false
    stack.dock.stackReleased()
  }

  visible: open
  color: "transparent"

  readonly property int pad: Style.spacing.sm
  readonly property var stackBorder: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  readonly property int shotW: Style.space(230)
  readonly property int shotH: Math.round(shotW * 0.6)
  readonly property int rowH: shotH + Math.round(Style.font.bodySmall + Style.spacing.md * 2)

  implicitWidth: Math.round(shotW + pad * 4 + Border.left(stackBorder) + Border.right(stackBorder))
  implicitHeight: Math.round(wins.length * (rowH + pad * 2) + Math.max(0, wins.length - 1) * Style.spacing.sm
                             + pad * 2 + Border.top(stackBorder) + Border.bottom(stackBorder))

  HyprlandFocusGrab {
    active: stack.open
    windows: {
      var out = [stack]
      var w = stack.anchorCell ? stack.anchorCell.QsWindow.window : null
      if (w) out.push(w)
      return out
    }
    onCleared: stack.close()
  }

  // Hover-out dismissal: once the pointer has left both the stack and the
  // dock, fold after a beat. The grab covers clicks; this covers drifting
  // away.
  Timer {
    id: leaveTimer
    interval: 350
    onTriggered: if (!stackHover.hovered && stack.dock.dockHovers === 0) stack.close()
  }

  anchor {
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: Edges.Top | Edges.Right
    window: stack.anchorCell ? stack.anchorCell.QsWindow.window : null

    onAnchoring: {
      var target = stack.anchorCell
      var window = target ? target.QsWindow.window : null
      if (!window) return
      var pos = window.contentItem.mapFromItem(target, 0, 0)
      var x = Math.round(pos.x + target.width / 2 - stack.implicitWidth / 2)
      x = Math.max(0, Math.min(x, window.width - stack.implicitWidth))
      anchor.rect.x = x
      anchor.rect.y = Math.round(window.height - stack.dock.cardHeight - stack.dock.edgeGap
                                 - Style.spacing.sm)
      anchor.rect.width = 1
      anchor.rect.height = 1
    }
  }

  BorderSurface {
    anchors.fill: parent
    radius: Math.min(stack.dock.cardRadius, Style.cornerRadius)
    color: Util.alpha(Color.popups.background, 0.97)
    borderSpec: stack.stackBorder

    HoverHandler {
      id: stackHover
      onHoveredChanged: if (!hovered) leaveTimer.restart()
    }

    Column {
      x: Border.left(stack.stackBorder) + stack.pad
      y: Border.top(stack.stackBorder) + stack.pad
      spacing: Style.spacing.sm

      Repeater {
        model: stack.wins

        delegate: Rectangle {
          id: winRow
          required property var modelData
          readonly property bool hot: rowHover.hovered

          width: stack.shotW + stack.pad * 2
          height: stack.rowH + stack.pad * 2
          radius: Math.max(2, Math.round(Style.cornerRadius / 2))
          color: hot ? Util.alpha(Color.accent, 0.10) : "transparent"
          border.width: 1
          border.color: hot ? Color.accent : Util.alpha(Color.popups.text, 0.2)

          Rectangle {
            id: shotFrame
            x: stack.pad
            y: stack.pad
            width: stack.shotW
            height: stack.shotH
            color: Util.alpha(Color.background, 0.6)
            border.width: 1
            border.color: Util.alpha(Color.popups.text, 0.12)
            clip: true

            ScreencopyView {
              anchors.fill: parent
              anchors.margins: 1
              captureSource: winRow.modelData
              // Streaming costs a copy per frame per window; only pay it
              // while the stack is actually on screen.
              live: stack.open
            }
          }

          Text {
            x: stack.pad
            y: shotFrame.y + shotFrame.height + Style.spacing.md
            width: stack.shotW
            text: String(winRow.modelData.title || winRow.modelData.appId || "window")
            color: winRow.hot ? Color.accent : Color.popups.text
            font.family: Style.font.resolvedFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          HoverHandler {
            id: rowHover
            onHoveredChanged: {
              if (hovered && stack.dock.hoverActivate && winRow.modelData)
                winRow.modelData.activate()
            }
          }

          TapHandler {
            onTapped: {
              var w = winRow.modelData
              stack.close()
              if (w) w.activate()
              if (stack.dock.flag("hideOnLaunch", true)) stack.dock.close()
            }
          }
        }
      }
    }
  }
}
