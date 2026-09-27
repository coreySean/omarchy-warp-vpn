import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// WARP VPN bar panel.
//
// Clicking the bar icon opens this panel and nothing else — connecting,
// disconnecting and picking an operation mode all live in here, so the widget
// has exactly one job instead of a left-click/right-click split.
//
// Layout and chrome follow the same kit as omarchy's own panels (bluetooth,
// tailscale): a PanelHero whose trailing ToggleSwitch owns the connection
// toggle, then a section of selectable mode rows.
Panel {
  id: root
  moduleName: "coreySean.warp-vpn"
  ipcTarget: "coreySean.warp-vpn"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits — needed for the toggleWarp method below.
  manageIpc: false

  readonly property string scriptPath: Qt.resolvedUrl("warp-actions").toString().replace(/^file:\/\//, "")

  // Everything the UI shows is derived from this one record.
  property var view: ({
    state: "Unknown",
    mode: "warp",
    detail: "",
    error: "",
    available: true
  })
  property bool busy: false
  // Set while a connect/disconnect/mode change is in flight, so the poll does
  // not race the action and paint a stale state over the result.
  property bool actionPending: false
  // Result of the last action, shown under the panel: either a confirmation
  // or the reason it failed. Empty until something runs.
  property string actionStatus: ""
  property bool actionFailed: false

  // Captured process output. StdioCollector.text is read-only, so the stream
  // hands the payload over here and the matching onExited reads it. With
  // waitForEnd the stream always finishes before the process reports, so
  // these are never a run behind.
  property string statusOutput: ""
  property string statusErrorOutput: ""
  property string actionOutput: ""
  property string actionErrorOutput: ""
  // Confirmation to show if the in-flight action succeeds; "" means stay quiet.
  property string pendingSuccessMessage: ""
  // True while the DNS flush is the action in flight, so its button can say it
  // is waiting on the password prompt rather than looking stuck.
  property bool flushPending: false

  readonly property var modes: Model.MODES
  readonly property bool connected: Model.isConnected(view.state)

  // Bar icon and tooltip.
  readonly property string iconText: Model.icon(view, busy || actionPending)
  readonly property string tooltipText: Model.tooltip(view)

  // The hero's secondary sentence: an actionable install hint when warp-cli
  // is missing, then a live backend error, then the reason warp-cli gave.
  readonly property string detailText: {
    if (!view.available) return "Install cloudflare-warp to use this widget"
    if (view.error !== "") return view.error
    return Model.detailLine(view)
  }

  // The bar slot sizes itself from the loaded item's implicit dimensions, so
  // the panel must publish them or the widget collapses to nothing.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // Poll cadence, configurable per-user via `omarchy bar set
  // coreySean.warp-vpn pollIntervalSec <n>`. The bar icon is the
  // always-visible surface, so it has to reflect a connection made or dropped
  // outside this panel — hence polling rather than acting only on our own
  // actions. Clamped so a stray 0 cannot spin warp-cli.
  readonly property int pollIntervalMs: Math.max(2, Number(setting("pollIntervalSec", 4)) || 4) * 1000

  // Opt-in password prompt for the DNS flush. Off by default; see flushDns().

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.4)
  readonly property color urgentColor: Color.urgent
  readonly property color hoverFill: bar ? Style.hoverFillFor(foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(foreground, Color.accent) : "transparent"

  // --- keyboard cursor ----------------------------------------------------
  // "header" is a virtual section for the hero toggle so the connection can be
  // switched by keyboard even when no mode row is focused. The order is
  // header -> modes -> flush -> back to header.
  property string focusSection: "header"
  property int modeCursor: 0
  property bool cursorActive: false
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  function moveCursor(delta) {
    if (delta > 0) {
      if (focusSection === "header") { focusSection = "modes"; modeCursor = 0; cursorActive = true; return }
      if (focusSection === "modes") {
        if (modeCursor < modes.length - 1) { modeCursor += 1; return }
        focusSection = "flush"
        return
      }
      focusSection = "header"
      return
    }
    if (focusSection === "header") { focusSection = "modes"; modeCursor = modes.length - 1; cursorActive = true; return }
    if (focusSection === "flush") { focusSection = "modes"; modeCursor = modes.length - 1; return }
    if (modeCursor > 0) { modeCursor -= 1; return }
    focusSection = "header"
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  function setFlushCursor() {
    cursorActive = true
    focusSection = "flush"
  }

  function activateCursor() {
    if (!cursorActive) { cursorActive = true; return }
    if (focusSection === "header") { toggleConnection(); return }
    if (focusSection === "flush") { flushDns(); return }

    setMode(modes[modeCursor].id)
  }

  // --- backend ------------------------------------------------------------

  // Quickshell's Process no longer exposes stdout as a string, so every
  // process here declares a StdioCollector and the panel reads that. Without
  // it `stdout` is null and the panel can never see a result.
  function refresh() {
    if (statusProcess.running) return
    statusProcess.command = [root.scriptPath, "status"]
    statusProcess.running = true
  }

  function runAction(args, successMessage) {
    if (actionPending) return
    actionPending = true
    // The previous result is left in place until the new one lands. Blanking
    // it here would make the text flicker, and the line's slot is reserved
    // regardless, so there is no geometry benefit to clearing it.
    pendingSuccessMessage = successMessage || ""
    actionProcess.command = [root.scriptPath].concat(args)
    actionProcess.running = true
  }

  function toggleConnection() {
    if (!view.available) return
    // Ask for a direction rather than toggling blindly: the action runs
    // detached and the switch only moves once the poll catches up, so a
    // second click inside that window would re-read the old state and undo
    // the first.
    runAction([connected ? "disconnect" : "connect"],
      connected ? "Disconnected" : "Connecting…")
  }

  // Drops the DNS cache and republishes NetworkManager's per-link DNS, so a
  // tunnel change actually shows up in name resolution. Always one pkexec call
  // per click, so a password prompt is expected before anything happens.
  function flushDns() {
    flushPending = true
    runAction(["flush-dns"], "DNS cache flushed")
  }

  function setMode(id) {
    if (id === view.mode) return
    runAction(["mode", id])
  }

  // --- lifecycle ----------------------------------------------------------

  onOpenedChanged: if (opened) refresh()

  Component.onCompleted: refresh()

  // The icon is a persistent surface, so poll for changes the panel cannot
  // observe: the daemon reconnecting on its own, a mode changed from a
  // terminal, or warp-cli going away.
  Timer {
    interval: root.pollIntervalMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.statusOutput = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.statusErrorOutput = String(text || "")
    }

    onExited: function(exitCode) {
      root.busy = false
      const out = root.statusOutput
      const err = root.statusErrorOutput.trim()
      // A usage error exits non-zero with nothing on stdout; warp-cli being
      // missing is reported in-band with ok=0, so it arrives here normally.
      if (out.trim() === "") {
        if (err !== "") {
          root.actionStatus = err
          root.actionFailed = true
        }
        return
      }
      root.view = Model.parseStatus(out)
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionOutput = String(text || "")
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.actionErrorOutput = String(text || "")
    }

    onExited: function(exitCode) {
      root.actionPending = false
      root.flushPending = false
      const out = root.actionOutput
      const err = root.actionErrorOutput.trim()
      const block = Model.parseBlock(out)
      if (block.ok === "0" || out.trim() === "") {
        root.actionStatus = block.error || err || "the command did not respond"
        root.actionFailed = true
      } else {
        root.actionStatus = root.pendingSuccessMessage
        root.actionFailed = false
      }
      root.pendingSuccessMessage = ""
      // Re-read after every action so the panel reflects what actually
      // happened rather than what was asked for.
      root.refresh()
    }
  }

  IpcHandler {
    target: "coreySean.warp-vpn"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function toggleWarp() { root.toggleConnection() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.iconText
    tooltipText: root.tooltipText
    // One action only: open the panel. Connecting and mode selection are
    // panel interactions, so there is no right-click branch here.
    onPressed: function() { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "c" || t === "C") root.toggleConnection()
        if (t === "f" || t === "F") root.flushDns()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero: WARP icon · state · connect switch ----------
        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight
          // Exposed for the hero's trailingControl, whose `root` resolves to
          // PanelHero (not this Panel) — reach panel state via `header`.
          readonly property bool ringVisible: root.headerHasCursor
          function focusHero() { root.setHeaderCursor() }

          PanelHero {
            id: hero
            width: parent.width
            title: "WARP VPN"
            meta: Model.statusLine(root.view)
            foreground: root.foreground
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            iconOpacity: root.view.available ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.iconText
                color: hero.foreground
                font.family: hero.fontFamily
                font.pixelSize: Style.font.display
                opacity: root.busy || root.actionPending ? 0.5 : 1.0
              }
            }

            // The switch is the only way to connect or disconnect, by mouse
            // or keyboard, and it is the header's single cursor target.
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                visible: root.view.available
                checked: root.connected
                busy: root.actionPending
                hasCursor: header.ringVisible
                foreground: hero.foreground
                onHovered: function(on) { if (on) header.focusHero() }
                onToggled: root.toggleConnection()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.connected ? "Disconnect WARP" : "Connect WARP"
                  fontFamily: hero.fontFamily
                }
              }
            }
          }
        }

        // Secondary line: what the backend reported, or why it is unavailable.
        // Always laid out, never collapsed: KeyboardPanel centres the card on
        // the bar icon, so a line appearing or disappearing would resize the
        // panel and shove it around. Two lines of room, capped.
        Text {
          width: parent.width
          height: Style.space(32)
          textFormat: Text.PlainText
          text: root.detailText
          color: root.view.error !== "" ? root.urgentColor : root.dim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---------- Mode picker ----------
        PanelSectionHeader {
          text: "CONNECTION MODE"
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        Column {
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: root.modes

            ModeRow {
              required property var modelData
              required property int index

              width: parent.width
              label: modelData.label
              description: modelData.description
              selected: modelData.id === root.view.mode
              rowSelected: root.cursorActive && root.focusSection === "modes" && root.modeCursor === index
              onHovered: function() {
                root.cursorActive = true
                root.focusSection = "modes"
                root.modeCursor = index
              }
              onChosen: root.setMode(modelData.id)
            }
          }
        }

        // ---------- DNS ----------
        PanelSeparator {
          foreground: root.foreground
        }

        PanelSectionHeader {
          text: "DNS"
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }

        // Drops the resolved cache and republishes NetworkManager's per-link
        // DNS, which is what makes a tunnel change show up in name resolution.
        Button {
          id: flushButton
          width: parent.width
          text: root.actionPending && root.flushPending ? "Waiting for password…" : "Flush DNS cache"
          iconText: root.actionPending && root.flushPending ? "" : Model.ICON.refresh
          bordered: true
          enabled: !root.actionPending
          foreground: root.foreground
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
          hasCursor: root.cursorActive && root.focusSection === "flush"
          // Button renders its own tooltip from this, so no child is needed.
          tooltipText: "Drops the DNS cache and republishes NetworkManager DNS. Asks for your password."
          onHovered: function(on) { if (on) root.setFlushCursor() }
          onClicked: root.flushDns()
        }

        // Result of the last action: a confirmation, or why it failed. Same
        // reserved slot as the detail line above, so showing a result never
        // resizes the panel.
        Text {
          width: parent.width
          height: Style.space(32)
          textFormat: Text.PlainText
          text: root.actionStatus
          color: root.actionFailed ? root.urgentColor : root.dim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 2
          elide: Text.ElideRight
        }
      }
    }
  }

  // One selectable operation mode. Rendered with CursorSurface so the keyboard
  // cursor and the mouse highlight are the same visuals the other panels use.
  component ModeRow: CursorSurface {
    id: row
    signal chosen()
    signal hovered()

    property string label: ""
    property string description: ""
    property bool selected: false
    property bool rowSelected: false

    visible: enabled
    foreground: root.foreground
    hasCursor: rowSelected
    current: selected
    fill: root.hoverFill
    currentFill: root.selectedFill
    radius: Style.cornerRadius
    implicitHeight: rowContent.implicitHeight + Style.space(8)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: row.hovered()
      onClicked: row.chosen()
    }

    PanelToolTip {
      visible: rowMouse.containsMouse
      text: row.selected ? row.label + " (active)" : "Switch to " + row.label
      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    }

    RowLayout {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(10)

      Column {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.label
          color: root.foreground
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.body
          font.bold: row.selected
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: row.description
          color: root.dim
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      Text {
        text: Model.ICON.check
        visible: row.selected
        color: root.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }
    }
  }
}
