import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The dock's settings GUI: item list on the left, editor on the right,
// dock-wide settings behind "Dock…". Follows the emojis/clipboard overlay
// idiom — fullscreen scrim, centered card, exclusive keyboard while open,
// Esc closes.
//
// Every write goes through the configurator CLI (set-item / add / unpin /
// move / set), never straight to shell.json — apply()'s staged-tempfile
// validation stays the only writer, and the config hot-reload brings each
// change back into the live dock, so edits preview instantly.
//
// Item edits buffer locally and land on Save; dock-level settings apply as
// they change (they're individually cheap and trivially reversible).
Item {
  id: root

  required property var dock

  property bool opened: false
  property int selIndex: -1
  property bool dockPage: false
  // "entries" or "glyphs" while a picker overlay is up, else "".
  property string picker: ""

  // The editing buffer: a plain copy of the selected item, mutated by the
  // form and written back wholesale on Save.
  property var buf: ({})
  property bool dirty: false

  readonly property var items: dock.items
  readonly property var selItem: (selIndex >= 0 && selIndex < items.length) ? items[selIndex] : null
  readonly property bool selIsSpacer: Util.isPlainObject(selItem) && selItem.spacer === true

  // The curated glyph list, shared with the TUI's picker via glyphs.json.
  property var glyphList: []

  function open() {
    if (items.length > 0 && selIndex < 0) select(0)
    opened = true
    dockPage = false
    picker = ""
    if (glyphList.length === 0) loadGlyphs()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    opened = false
    picker = ""
  }

  function select(i) {
    selIndex = i
    dockPage = false
    buf = (i >= 0 && i < items.length) ? JSON.parse(JSON.stringify(items[i])) : {}
    dirty = false
  }

  function setBuf(key, value) {
    var next = JSON.parse(JSON.stringify(buf))
    if (value === undefined) delete next[key]
    else next[key] = value
    buf = next
    dirty = true
  }

  function save() {
    if (!dirty || selIndex < 0) return
    cli("set-item " + selIndex + " " + Util.shellQuote(JSON.stringify(buf)))
    dirty = false
  }

  function revert() { select(selIndex) }

  function cli(args) { Util.execDetached("omarchy-dock-config " + args) }

  // Dock-level settings write straight through; the shell.json reload is
  // the preview.
  function setDock(key, value) {
    cli("set " + key + " " + Util.shellQuote(JSON.stringify(value)))
  }

  // QML's XMLHttpRequest won't read file:// without an env opt-in, so the
  // list comes through Quickshell's FileView instead. The path leans on the
  // registry stamping __sourceDir into every manifest.
  FileView {
    id: glyphsFile
    path: {
      var dir = root.dock.manifest && root.dock.manifest.__sourceDir
        ? String(root.dock.manifest.__sourceDir) : ""
      return dir !== "" ? dir + "/glyphs.json" : ""
    }
    onLoaded: {
      try { root.glyphList = JSON.parse(glyphsFile.text()) } catch (e) { root.glyphList = [] }
    }
  }

  function loadGlyphs() {
    if (glyphsFile.path !== "") glyphsFile.reload()
  }

  // Sorted desktop entries for the launch picker.
  readonly property var appEntries: {
    var out = []
    var values = (DesktopEntries.applications && DesktopEntries.applications.values) || []
    for (var i = 0; i < values.length; i++) {
      var e = values[i]
      if (!e || e.noDisplay === true) continue
      out.push(e)
    }
    out.sort(function(a, b) {
      return String(a.name || a.id).localeCompare(String(b.name || b.id))
    })
    return out
  }

  function itemTitle(item) {
    if (!Util.isPlainObject(item)) return "(item)"
    if (item.spacer === true) return "── divider ──"
    return String(item.label || item.desktop || item.appId || item.exec || "(unnamed)")
  }

  function itemGlyph(item) {
    return (Util.isPlainObject(item) && item.glyph) ? String(item.glyph) : ""
  }

  // ------------------------------------------------------------ components

  component SLabel: Text {
    color: Util.alpha(Color.popups.text, 0.6)
    font.family: Style.font.resolvedFamily
    font.pixelSize: Math.max(10, Style.font.bodySmall - 2)
    font.letterSpacing: 0.5
  }

  component SText: Text {
    color: Color.popups.text
    font.family: Style.font.resolvedFamily
    font.pixelSize: Style.font.bodySmall
  }

  component SButton: Rectangle {
    id: btn
    property string label: ""
    property bool accent: false
    property bool enabled: true
    signal clicked()
    implicitWidth: Math.round(btnText.implicitWidth + Style.spacing.xl * 2)
    implicitHeight: Math.round(Style.font.bodySmall + Style.spacing.md * 2)
    radius: Math.max(2, Math.round(Style.cornerRadius / 2))
    color: !enabled ? Util.alpha(Color.popups.text, 0.06)
         : accent ? (btnHover.hovered ? Util.alpha(Color.accent, 0.85) : Color.accent)
         : btnHover.hovered ? Util.alpha(Color.accent, 0.16) : Util.alpha(Color.popups.text, 0.08)
    border.width: 1
    border.color: accent ? "transparent" : Util.alpha(Color.popups.text, 0.25)
    opacity: enabled ? 1 : 0.5
    Text {
      id: btnText
      anchors.centerIn: parent
      text: btn.label
      color: btn.accent ? Color.popups.background : (btnHover.hovered ? Color.accent : Color.popups.text)
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.bodySmall
    }
    HoverHandler { id: btnHover; enabled: btn.enabled }
    TapHandler { enabled: btn.enabled; onTapped: btn.clicked() }
  }

  component SInput: Rectangle {
    id: field
    property alias text: input.text
    property string placeholder: ""
    signal edited(string value)
    implicitHeight: Math.round(Style.font.bodySmall + Style.spacing.md * 2 + 2)
    radius: Math.max(2, Math.round(Style.cornerRadius / 2))
    color: Util.alpha(Color.background, 0.6)
    border.width: 1
    border.color: input.activeFocus ? Color.accent : Util.alpha(Color.popups.text, 0.25)
    clip: true
    TextInput {
      id: input
      anchors.fill: parent
      anchors.leftMargin: Style.spacing.lg
      anchors.rightMargin: Style.spacing.lg
      verticalAlignment: TextInput.AlignVCenter
      color: Color.popups.text
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.bodySmall
      selectByMouse: true
      selectionColor: Util.alpha(Color.accent, 0.4)
      onTextEdited: field.edited(text)
    }
    Text {
      visible: input.text === "" && !input.activeFocus
      anchors.verticalCenter: parent.verticalCenter
      x: Style.spacing.lg
      text: field.placeholder
      color: Util.alpha(Color.popups.text, 0.35)
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component SRadio: Item {
    id: radio
    property string label: ""
    property bool on: false
    signal picked()
    implicitWidth: Math.round(ring.width + radioText.implicitWidth + Style.spacing.md)
    implicitHeight: Math.round(Style.font.bodySmall + Style.spacing.md)
    Rectangle {
      id: ring
      width: 13; height: 13; radius: 6.5
      anchors.verticalCenter: parent.verticalCenter
      color: "transparent"
      border.width: radio.on ? 4 : 1.5
      border.color: radio.on ? Color.accent : Util.alpha(Color.popups.text, 0.4)
    }
    Text {
      id: radioText
      anchors.verticalCenter: parent.verticalCenter
      x: ring.width + Style.spacing.md
      text: radio.label
      color: radio.on ? Color.accent : Color.popups.text
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.bodySmall
    }
    TapHandler { onTapped: radio.picked() }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
  }

  component SCheck: Item {
    id: check
    property string label: ""
    property bool on: false
    signal toggled(bool value)
    implicitWidth: Math.round(box.width + checkText.implicitWidth + Style.spacing.md)
    implicitHeight: Math.round(Style.font.bodySmall + Style.spacing.md)
    Rectangle {
      id: box
      width: 14; height: 14
      radius: 3
      anchors.verticalCenter: parent.verticalCenter
      color: check.on ? Color.accent : "transparent"
      border.width: 1.5
      border.color: check.on ? Color.accent : Util.alpha(Color.popups.text, 0.4)
      Text {
        visible: check.on
        anchors.centerIn: parent
        text: "✓"
        color: Color.popups.background
        font.pixelSize: 10
        font.bold: true
      }
    }
    Text {
      id: checkText
      anchors.verticalCenter: parent.verticalCenter
      x: box.width + Style.spacing.md
      text: check.label
      color: Color.popups.text
      font.family: Style.font.resolvedFamily
      font.pixelSize: Style.font.bodySmall
    }
    TapHandler { onTapped: check.toggled(!check.on) }
    HoverHandler { cursorShape: Qt.PointingHandCursor }
  }

  component SSlider: Item {
    id: slider
    property real from: 0
    property real to: 1
    property real value: 0
    property real step: 0.05
    signal moved(real value)
    implicitHeight: 20
    Rectangle {
      id: track
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width
      height: 3
      radius: 1.5
      color: Util.alpha(Color.popups.text, 0.25)
      Rectangle {
        width: handle.x + handle.width / 2
        height: parent.height
        radius: 1.5
        color: Color.accent
      }
    }
    Rectangle {
      id: handle
      width: 13; height: 13; radius: 6.5
      anchors.verticalCenter: parent.verticalCenter
      x: (slider.value - slider.from) / (slider.to - slider.from) * (parent.width - width)
      color: Color.accent
    }
    TapHandler {
      onTapped: function(eventPoint) { slider.jump(eventPoint.position.x) }
    }
    DragHandler {
      target: null
      onCentroidChanged: if (active) slider.jump(centroid.position.x)
    }
    function jump(px) {
      var f = Math.max(0, Math.min(1, (px - handle.width / 2) / (width - handle.width)))
      var v = from + f * (to - from)
      v = Math.round(v / step) * step
      v = Math.max(from, Math.min(to, v))
      if (Math.abs(v - value) > 1e-9) moved(v)
    }
  }

  // ---------------------------------------------------------------- window

  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-dock-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }

    // Scrim: click outside the card closes. The bounds check matters — a
    // TapHandler takes only a passive grab, so card-area taps reach this
    // handler too; "the card swallows clicks" is not a thing passive
    // handlers can do for us.
    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.background, 0.55)
      TapHandler {
        onTapped: function(eventPoint) {
          var p = card.mapFromItem(null, eventPoint.scenePosition.x, eventPoint.scenePosition.y)
          if (p.x < 0 || p.y < 0 || p.x > card.width || p.y > card.height) root.close()
        }
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: {
        if (root.picker !== "") root.picker = ""
        else root.close()
      }
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: Math.min(Style.space(640), panel.width - Style.space(40))
      height: Math.min(Style.space(430), panel.height - Style.space(40))
      radius: Style.cornerRadius
      color: Util.alpha(Color.popups.background, 0.99)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      readonly property int pad: Style.spacing.panelPadding
      readonly property int headerH: Math.round(Style.font.body + Style.spacing.lg * 2)
      readonly property int footerH: Math.round(Style.font.bodySmall + Style.spacing.lg * 3)
      readonly property int listW: Style.space(210)

      // A picker sheet drawn over these panes does NOT stop their tap
      // handlers receiving the same clicks — passive grabs deliver to
      // every handler under the point, stacking order be damned. That
      // was a glyph pick also selecting whichever list row sat beneath
      // the pointer. visible:false is what actually removes an item from
      // input delivery, so the panes vanish while a picker is up.

      // ------------------------------------------------------------ header
      Item {
        id: header
        visible: root.picker === ""
        x: card.pad; y: Style.spacing.md
        width: card.width - card.pad * 2
        height: card.headerH

        SText {
          anchors.verticalCenter: parent.verticalCenter
          text: "󰒓  Dock — Settings"
          font.pixelSize: Style.font.body
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: "󰅖"
          color: closeHover.hovered ? Color.accent : Util.alpha(Color.popups.text, 0.5)
          font.family: Style.font.resolvedFamily
          font.pixelSize: Style.font.body
          HoverHandler { id: closeHover }
          TapHandler { onTapped: root.close() }
        }
      }

      Rectangle {
        x: card.pad; y: header.y + header.height
        width: card.width - card.pad * 2; height: 1
        color: Util.alpha(Color.popups.text, 0.15)
      }

      // ------------------------------------------------------- item list
      Item {
        id: listPane
        visible: root.picker === ""
        x: card.pad
        y: header.y + header.height + Style.spacing.md
        width: card.listW
        height: card.height - y - card.footerH - Style.spacing.md

        ListView {
          id: itemList
          anchors.fill: parent
          anchors.bottomMargin: listToolbar.height + Style.spacing.md
          clip: true
          model: root.items
          spacing: 2

          delegate: Rectangle {
            id: listRow
            required property var modelData
            required property int index
            readonly property bool sel: index === root.selIndex && !root.dockPage
            width: itemList.width
            height: Math.round(Style.font.bodySmall + Style.spacing.lg * 2)
            radius: Math.max(2, Math.round(Style.cornerRadius / 2))
            color: sel ? Util.alpha(Color.accent, 0.16)
                 : rowHover.hovered ? Util.alpha(Color.popups.text, 0.06) : "transparent"
            border.width: sel ? 1 : 0
            border.color: Util.alpha(Color.accent, 0.4)

            Text {
              id: rowGlyph
              x: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              text: root.itemGlyph(listRow.modelData)
              color: listRow.sel ? Color.accent : Color.popups.text
              font.family: Style.font.resolvedFamily
              font.pixelSize: Style.font.bodySmall
            }
            SText {
              x: rowGlyph.x + rowGlyph.width + Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x - Style.spacing.md
              text: root.itemTitle(listRow.modelData)
              elide: Text.ElideRight
              color: listRow.sel ? Color.accent
                   : listRow.modelData.spacer === true ? Util.alpha(Color.popups.text, 0.45)
                   : Color.popups.text
            }
            HoverHandler { id: rowHover }
            TapHandler { onTapped: root.select(listRow.index) }
          }
        }

        Row {
          id: listToolbar
          anchors.bottom: parent.bottom
          spacing: Style.spacing.sm

          SButton { label: "󰐕"; onClicked: {
            root.cli("add " + Util.shellQuote(JSON.stringify({ label: "New Item", glyph: "󰛓", exec: "" })))
            Qt.callLater(function() { root.select(root.items.length - 1) })
          } }
          SButton { label: "│"; onClicked: root.cli("add " + Util.shellQuote(JSON.stringify({ spacer: true }))) }
          SButton { label: "󰍴"; enabled: root.selIndex >= 0; onClicked: {
            var i = root.selIndex
            root.cli("unpin " + i)
            root.select(Math.max(-1, i - 1))
          } }
          SButton { label: "󰜷"; enabled: root.selIndex > 0; onClicked: {
            var i = root.selIndex
            root.cli("move " + i + " " + (i - 1)); root.selIndex = i - 1
          } }
          SButton { label: "󰜮"; enabled: root.selIndex >= 0 && root.selIndex < root.items.length - 1; onClicked: {
            var i = root.selIndex
            root.cli("move " + i + " " + (i + 1)); root.selIndex = i + 1
          } }
          SButton {
            label: "Dock…"
            accent: root.dockPage
            onClicked: root.dockPage = !root.dockPage
          }
        }
      }

      Rectangle {
        x: card.pad + card.listW + Style.spacing.lg; y: listPane.y
        width: 1; height: listPane.height
        color: Util.alpha(Color.popups.text, 0.15)
      }

      // ------------------------------------------------------ editor pane
      Flickable {
        id: form
        visible: root.picker === ""
        x: card.pad + card.listW + Style.spacing.lg * 2
        y: listPane.y
        width: card.width - x - card.pad
        height: listPane.height
        clip: true
        contentHeight: root.dockPage ? dockForm.implicitHeight : itemForm.implicitHeight
        contentWidth: width
        boundsBehavior: Flickable.StopAtBounds

        // ------------------------------------------------ per-item editor
        Column {
          id: itemForm
          visible: !root.dockPage
          width: form.width
          spacing: Style.spacing.xl

          SText {
            visible: root.selItem === null
            text: "Select an item on the left."
            opacity: 0.6
          }
          SText {
            visible: root.selIsSpacer
            text: "A divider. Reorder or remove it with the list buttons."
            opacity: 0.6
          }

          Column {
            visible: root.selItem !== null && !root.selIsSpacer
            width: parent.width
            spacing: Style.spacing.xl

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              SLabel { text: "LABEL" }
              SInput {
                width: parent.width
                text: root.buf.label !== undefined ? String(root.buf.label) : ""
                placeholder: "(from the desktop entry)"
                onEdited: function(v) { root.setBuf("label", v === "" ? undefined : v) }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              SLabel { text: "LAUNCH" }
              Row {
                spacing: Style.spacing.xxl
                SRadio {
                  label: "Desktop entry"
                  on: root.buf.exec === undefined
                  onPicked: { root.setBuf("exec", undefined); root.picker = "entries" }
                }
                SRadio {
                  label: "Command / script"
                  on: root.buf.exec !== undefined
                  onPicked: if (root.buf.exec === undefined) root.setBuf("exec", "")
                }
              }
              SInput {
                visible: root.buf.exec !== undefined
                width: parent.width
                text: root.buf.exec !== undefined ? String(root.buf.exec) : ""
                placeholder: "command to run"
                onEdited: function(v) { root.setBuf("exec", v) }
              }
              Rectangle {
                visible: root.buf.exec === undefined
                width: parent.width
                height: Math.round(Style.font.bodySmall + Style.spacing.md * 2 + 2)
                radius: Math.max(2, Math.round(Style.cornerRadius / 2))
                color: Util.alpha(Color.background, 0.6)
                border.width: 1
                border.color: Util.alpha(Color.popups.text, 0.25)
                SText {
                  x: Style.spacing.lg
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.buf.desktop ? String(root.buf.desktop) : "pick an app…") + "  ▾"
                  opacity: root.buf.desktop ? 1 : 0.5
                }
                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.picker = "entries" }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              SLabel { text: "ICON" }
              Flow {
                width: parent.width
                spacing: Style.spacing.xxl
                SRadio {
                  label: "App icon"
                  on: root.buf.glyph === undefined && root.buf.icon === undefined
                  onPicked: { root.setBuf("glyph", undefined); root.setBuf("icon", undefined) }
                }
                Row {
                  spacing: Style.spacing.md
                  SRadio {
                    label: "Glyph"
                    on: root.buf.glyph !== undefined
                    onPicked: root.picker = "glyphs"
                  }
                  SText {
                    visible: root.buf.glyph !== undefined
                    text: root.buf.glyph !== undefined ? String(root.buf.glyph) : ""
                    font.pixelSize: Style.font.body
                  }
                  SButton {
                    visible: root.buf.glyph !== undefined
                    label: "Pick…"
                    onClicked: root.picker = "glyphs"
                  }
                }
                SRadio {
                  label: "SVG / PNG / icon name"
                  on: root.buf.icon !== undefined && root.buf.glyph === undefined
                  onPicked: { root.setBuf("glyph", undefined); if (root.buf.icon === undefined) root.setBuf("icon", "") }
                }
              }
              SInput {
                visible: root.buf.icon !== undefined && root.buf.glyph === undefined
                width: parent.width
                text: root.buf.icon !== undefined ? String(root.buf.icon) : ""
                placeholder: "/path/to/icon.svg or icon-theme name"
                onEdited: function(v) { root.setBuf("icon", v) }
              }
            }

            SCheck {
              label: "Tint to theme accent"
              on: root.buf.tint === true
              onToggled: function(v) { root.setBuf("tint", v ? true : undefined) }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              SLabel {
                readonly property real v: root.buf.iconScale !== undefined ? Number(root.buf.iconScale) : 1.0
                text: "ICON SCALE · " + v.toFixed(2)
              }
              SSlider {
                width: parent.width
                from: 0.5; to: 1.6; step: 0.05
                value: root.buf.iconScale !== undefined ? Number(root.buf.iconScale) : 1.0
                onMoved: function(v) { root.setBuf("iconScale", Math.abs(v - 1.0) < 0.026 ? undefined : v) }
              }
            }

            Column {
              width: parent.width
              spacing: Style.spacing.sm
              SLabel { text: "MATCH RUNNING WINDOWS BY APP-ID" }
              SInput {
                width: parent.width
                text: root.buf.appId !== undefined
                  ? (Array.isArray(root.buf.appId) ? root.buf.appId.join(", ") : String(root.buf.appId))
                  : ""
                placeholder: "(from the desktop entry)"
                onEdited: function(v) {
                  var t = v.trim()
                  if (t === "") { root.setBuf("appId", undefined); return }
                  var parts = t.split(",").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
                  root.setBuf("appId", parts.length === 1 ? parts[0] : parts)
                }
              }
            }
          }
        }

        // ------------------------------------------------ dock-wide page
        Column {
          id: dockForm
          visible: root.dockPage
          width: form.width
          spacing: Style.spacing.xl

          // Generic schema-driven controls; null resets to the built-in
          // default via `set <key> null`.
          Repeater {
            model: [
              { key: "iconSize", label: "ICON SIZE", type: "num", from: 24, to: 96, step: 2, dflt: 40 },
              { key: "spacing", label: "SPACING", type: "num", from: 0, to: 24, step: 1, dflt: 6 },
              { key: "padding", label: "PADDING", type: "num", from: 0, to: 24, step: 1, dflt: 8 },
              { key: "edgeGap", label: "EDGE GAP", type: "num", from: 0, to: 32, step: 1, dflt: 6 },
              { key: "revealDelay", label: "REVEAL DELAY (MS)", type: "num", from: 0, to: 600, step: 10, dflt: 90 },
              { key: "hideDelay", label: "HIDE DELAY (MS)", type: "num", from: 0, to: 1500, step: 25, dflt: 350 },
              { key: "hotspotHeight", label: "HOTSPOT HEIGHT", type: "num", from: 1, to: 12, step: 1, dflt: 2 },
              { key: "labels", label: "Labels on hover", type: "bool", dflt: true },
              { key: "magnify", label: "Hover magnify", type: "bool", dflt: true },
              { key: "tiles", label: "Tiles behind icons", type: "bool", dflt: false },
              { key: "border", label: "Card border", type: "bool", dflt: true },
              { key: "hideOnLaunch", label: "Hide after launching", type: "bool", dflt: true },
              { key: "showWhenEmpty", label: "Stay up on empty workspaces", type: "bool", dflt: false },
              { key: "hotspotFullWidth", label: "Full-width hotspot", type: "bool", dflt: false },
              { key: "showRunning", label: "Show running apps", type: "bool", dflt: true },
              { key: "tintIcons", label: "Tint pinned icons", type: "bool", dflt: false },
              { key: "tintRunning", label: "Tint running icons", type: "bool", dflt: true },
              { key: "runningIndicator", label: "RUNNING INDICATOR", type: "enum", options: ["dot", "line", "none"], dflt: "dot" }
            ]

            delegate: Column {
              id: ctl
              required property var modelData
              readonly property var cur: root.dock.config[modelData.key]
              width: dockForm.width
              spacing: Style.spacing.sm

              SLabel {
                visible: ctl.modelData.type !== "bool"
                text: ctl.modelData.label + (ctl.modelData.type === "num"
                  ? " · " + (ctl.cur !== undefined ? Number(ctl.cur) : ctl.modelData.dflt) : "")
              }

              SSlider {
                visible: ctl.modelData.type === "num"
                width: parent.width
                // Bool/enum rows instantiate this too (visible only gates
                // paint), so the bounds need real numbers regardless.
                from: Number(ctl.modelData.from || 0)
                to: Number(ctl.modelData.to || 1)
                step: Number(ctl.modelData.step || 0.05)
                value: ctl.cur !== undefined ? Number(ctl.cur) : Number(ctl.modelData.dflt || 0)
                onMoved: function(v) {
                  root.setDock(ctl.modelData.key, v === ctl.modelData.dflt ? null : v)
                }
              }

              SCheck {
                visible: ctl.modelData.type === "bool"
                label: ctl.modelData.label
                on: ctl.cur !== undefined ? ctl.cur === true : ctl.modelData.dflt === true
                onToggled: function(v) {
                  root.setDock(ctl.modelData.key, v === ctl.modelData.dflt ? null : v)
                }
              }

              Row {
                visible: ctl.modelData.type === "enum"
                spacing: Style.spacing.xxl
                Repeater {
                  model: ctl.modelData.type === "enum" ? ctl.modelData.options : []
                  delegate: SRadio {
                    required property var modelData
                    label: modelData
                    on: (ctl.cur !== undefined ? String(ctl.cur) : ctl.modelData.dflt) === modelData
                    onPicked: root.setDock(ctl.modelData.key, modelData === ctl.modelData.dflt ? null : modelData)
                  }
                }
              }
            }
          }
        }
      }

      // ------------------------------------------------------------ footer
      Rectangle {
        x: card.pad; y: card.height - card.footerH
        width: card.width - card.pad * 2; height: 1
        color: Util.alpha(Color.popups.text, 0.15)
      }

      Item {
        visible: root.picker === ""
        x: card.pad
        y: card.height - card.footerH + Style.spacing.md
        width: card.width - card.pad * 2
        height: card.footerH - Style.spacing.md * 2

        SLabel {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - buttons.width - Style.spacing.xl
          elide: Text.ElideRight
          text: root.dockPage
            ? "Changes apply live via omarchy-dock-config set"
            : "Saved via omarchy-dock-config set-item — validated before it touches shell.json"
        }

        Row {
          id: buttons
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md
          visible: !root.dockPage
          SButton { label: "Revert"; enabled: root.dirty; onClicked: root.revert() }
          SButton { label: "Save"; accent: true; enabled: root.dirty; onClicked: root.save() }
        }
      }

      // ----------------------------------------------------- picker sheets
      Rectangle {
        visible: root.picker !== ""
        anchors.fill: parent
        radius: card.radius
        color: Util.alpha(Color.popups.background, 0.98)

        TapHandler { }

        SText {
          id: pickerTitle
          x: card.pad; y: Style.spacing.lg
          text: root.picker === "entries" ? "Pick an app" : "Pick a glyph"
          font.pixelSize: Style.font.body
        }
        SButton {
          anchors.right: parent.right
          anchors.rightMargin: card.pad
          y: Style.spacing.lg
          label: "Back"
          onClicked: root.picker = ""
        }

        // App list
        ListView {
          visible: root.picker === "entries"
          x: card.pad; y: pickerTitle.y + pickerTitle.height + Style.spacing.lg
          width: parent.width - card.pad * 2
          height: parent.height - y - card.pad
          clip: true
          model: root.picker === "entries" ? root.appEntries : []
          delegate: Rectangle {
            required property var modelData
            width: parent ? parent.width : 0
            height: Math.round(Style.font.bodySmall + Style.spacing.lg * 2)
            radius: Math.max(2, Math.round(Style.cornerRadius / 2))
            color: entryHover.hovered ? Util.alpha(Color.accent, 0.16) : "transparent"
            Image {
              id: entryIcon
              x: Style.spacing.md
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(18); height: Style.space(18)
              source: modelData.icon ? Quickshell.iconPath(String(modelData.icon), true) : ""
              sourceSize.width: 36; sourceSize.height: 36
              fillMode: Image.PreserveAspectFit
              asynchronous: true
            }
            SText {
              x: entryIcon.x + entryIcon.width + Style.spacing.lg
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x - Style.spacing.md
              elide: Text.ElideRight
              text: String(modelData.name || modelData.id)
            }
            HoverHandler { id: entryHover }
            TapHandler {
              onTapped: {
                root.setBuf("desktop", String(modelData.id).replace(/\.desktop$/, ""))
                root.setBuf("exec", undefined)
                root.picker = ""
              }
            }
          }
        }

        // Glyph grid
        GridView {
          visible: root.picker === "glyphs"
          x: card.pad; y: pickerTitle.y + pickerTitle.height + Style.spacing.lg
          width: parent.width - card.pad * 2
          height: parent.height - y - card.pad
          clip: true
          cellWidth: Style.space(52)
          cellHeight: Style.space(52)
          model: root.picker === "glyphs" ? root.glyphList : []
          delegate: Rectangle {
            required property var modelData
            width: Style.space(48); height: Style.space(48)
            radius: Math.max(2, Math.round(Style.cornerRadius / 2))
            color: glyphHover.hovered ? Util.alpha(Color.accent, 0.16) : "transparent"
            border.width: 1
            border.color: Util.alpha(Color.popups.text, glyphHover.hovered ? 0.4 : 0.15)
            Text {
              anchors.centerIn: parent
              text: String(modelData.glyph || "")
              color: glyphHover.hovered ? Color.accent : Color.popups.text
              font.family: Style.font.resolvedFamily
              font.pixelSize: Style.font.title
            }
            HoverHandler { id: glyphHover }
            TapHandler {
              onTapped: {
                root.setBuf("glyph", String(modelData.glyph || ""))
                root.setBuf("icon", undefined)
                root.picker = ""
              }
            }
          }
        }
      }
    }
  }
}
