import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The window stack: hover-dwell on a running icon opens a vertical run of
// live previews above the tile — one ScreencopyView per window, streaming
// only while the stack is open, with the window title beneath. Click
// focuses that window; the corner badge closes it. `hoverActivate` makes
// row-hover focus it macOS-style; it defaults off, because hover-focus
// steals focus from wherever you were typing.
//
// This is a hover popup in the shell's PopupCard sense: no focus grab, the
// owner drives it. It follows the pointer along the dock (Dock.onIconHovered
// re-anchors it to whichever running icon is under the pointer and folds it
// on a launch-only one) and closes once the pointer has left both it and
// the dock for a beat.
PopupWindow {
  id: stack

  required property var dock

  property var item: null
  property var anchorCell: null
  property bool open: false

  // Live windows for the item, snapshotted by reference — see
  // Dock.sameWindows. Left as-is on close so the still-mapped popup keeps
  // its size while it unmaps rather than collapsing to an empty card.
  property var wins: []
  readonly property var liveWins: open && item ? dock.windowsFor(item) : []
  onLiveWinsChanged: {
    if (!open) return
    var next = liveWins || []
    if (dock.sameWindows(wins, next)) return
    // The last window closed under the stack: nothing left to show.
    if (next.length < 1) {
      close()
      return
    }
    wins = next.slice()
  }

  function openFor(cell) {
    var next = dock.windowsFor(cell.modelData) || []
    if (next.length < 1) {
      close()
      return
    }
    stack.item = cell.modelData
    stack.anchorCell = cell
    stack.wins = next.slice()
    if (stack.open) {
      // Following the pointer to another icon: same surface, new anchor.
      stack.anchor.updateAnchor()
      return
    }
    stack.open = true
    stack.dock.holdForPopup()
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

  // Hover-out dismissal: once the pointer has left both the stack and the
  // dock, fold after a beat.
  Timer {
    id: leaveTimer
    interval: 350
    onTriggered: if (!stackHover.hovered && stack.dock.dockHovers === 0) stack.close()
  }

  // Grows inward from a point just off the card, centred on the icon —
  // same scheme as the context menu, see Dock.popupAnchorPoint.
  anchor {
    adjustment: PopupAdjustment.Slide
    edges: Edges.Top | Edges.Left
    gravity: stack.dock.popupGravity
    window: stack.anchorCell ? stack.anchorCell.QsWindow.window : null

    onAnchoring: {
      var target = stack.anchorCell
      var window = target ? target.QsWindow.window : null
      if (!window) return
      var p = stack.dock.popupAnchorPoint(target, window, stack.implicitWidth, stack.implicitHeight)
      anchor.rect.x = p.x
      anchor.rect.y = p.y
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
              if (closeHover.hovered) return
              var w = winRow.modelData
              stack.close()
              if (w) w.activate()
              if (stack.dock.flag("hideOnLaunch", true)) stack.dock.close()
            }
          }

          // Close badge, same language as the pin badge on a running icon:
          // circle, top-right, hover-revealed. Clicking it sends a close
          // request to that window; the stack stays up unless it was the last.
          Rectangle {
            id: closeBadge
            readonly property bool shown: rowHover.hovered || closeHover.hovered
            visible: opacity > 0
            opacity: shown ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 120 } }
            z: 2

            width: Math.max(18, Math.round(stack.pad * 2.4))
            height: width
            radius: width / 2
            anchors.right: shotFrame.right
            anchors.top: shotFrame.top
            // Half-out so the chip sits on the corner, not inside the shot.
            anchors.rightMargin: Math.round(-width * 0.5)
            anchors.topMargin: Math.round(-height * 0.5)
            color: closeHover.hovered ? Color.accent : Util.alpha(Color.accent, 0.9)
            border.width: 1
            border.color: Color.popups.background

            Text {
              anchors.centerIn: parent
              text: "󰅖"
              color: Color.popups.background
              font.family: Style.font.resolvedFamily
              font.pixelSize: Math.round(parent.width * 0.62)
            }

            HoverHandler { id: closeHover; enabled: closeBadge.shown || rowHover.hovered }
            TapHandler {
              enabled: closeBadge.shown || rowHover.hovered
              onTapped: if (winRow.modelData) winRow.modelData.close()
            }
          }
        }
      }
    }
  }
}
