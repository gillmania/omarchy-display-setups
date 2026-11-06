import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button for Display Setups, and the host for its panel.
//
// Left click opens the arrangement panel. Right click re-applies the profile
// saved for the setup that is connected right now.
//
// With `"workspaces": true` in its shell.json entry the widget also lists the
// workspaces, grouped by the display they belong to, so it can stand in for
// the built-in workspace switcher.
BarWidget {
  id: root
  moduleName: "io.github.gillmania.display-setups"

  // The service is this plugin's own headless half. It can finish loading
  // after the widget does, so it is looked up until it is there.
  property var service: null

  function resolveService() {
    if (root.service) return
    var shell = root.bar && root.bar.shell ? root.bar.shell : null
    if (!shell || typeof shell.serviceFor !== "function") return
    var found = shell.serviceFor(root.moduleName)
    if (found) {
      root.service = found
      root.injectPanel()
    }
  }

  readonly property string statusText: {
    if (!service || !service.ready) return "Display Setups"
    if (!service.activeProfile) return "Display Setups: this setup is not saved"
    var more = service.setupProfiles && service.setupProfiles.length > 1 ? " (scroll to switch)" : ""
    return "Display Setups: " + service.activeProfile.name + more
      + (screenNumber > 0 ? "\nThis is screen " + screenNumber + ": press Super + Shift + a number twice to send a window to that screen" : "")
  }

  // This bar's screen number, the one Identify shows and the double press of
  // Super + Shift + n sends windows to. Only on Omarchy 4.5 and later, where
  // that binding exists, and only with more than one screen.
  readonly property int screenNumber: {
    if (!service || service.perMonitor !== true) return 0
    var value = setting("screenNumber", true)
    if (value === false || value === "false") return 0
    var monitors = service.monitors || []
    var desktops = 0
    for (var i = 0; i < monitors.length; i++) if (Model.hasDesktop(monitors[i])) desktops++
    var window = root.QsWindow.window
    return desktops > 1 && window && window.screen ? Model.displayNumber(monitors, String(window.screen.name || "")) : 0
  }

  readonly property bool showWorkspaces: {
    var value = setting("workspaces", false)
    return value === true || value === "true"
  }

  // ---- Panel contract: Bar.findPanelWidget needs open/close/opened here.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { if (panelLoader.item) panelLoader.item.toggle() }
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = root.service
  }

  implicitWidth: content.implicitWidth
  implicitHeight: content.implicitHeight

  onBarChanged: { resolveService(); injectPanel() }
  onSettingsChanged: injectPanel()
  Component.onCompleted: resolveService()

  Timer {
    interval: 500
    repeat: true
    running: root.service === null
    onTriggered: root.resolveService()
  }

  // A layout that waits for "Keep this layout?" must not count down unseen.
  // Applying it rebuilds the bars, which closes the panel, so the panel is
  // brought back once on the screen that has the focus.
  readonly property bool confirmWaiting: service !== null && service.confirmArmed === true
  readonly property bool onFocusedScreen: {
    var window = root.QsWindow.window
    var focused = Hyprland.focusedMonitor
    return window && window.screen && focused ? window.screen.name === focused.name : false
  }
  Timer {
    interval: 400
    running: root.confirmWaiting && root.service.confirmPrompted !== true
      && root.onFocusedScreen && panelLoader.item !== null
    onTriggered: {
      // Shared through the service, so only one bar does this.
      if (root.service.confirmPrompted === true) return
      root.service.confirmPrompted = true
      if (!root.opened) root.open()
    }
  }

  // Middle click and the wheel step through the profiles saved for what is
  // connected. One step at a time: a wheel sends many events per notch.
  function cycle(step) {
    if (!root.service || cycleGate.running) return
    if (!root.service.setupProfiles || root.service.setupProfiles.length < 2) return
    cycleGate.restart()
    root.service.nextProfile(step)
  }

  Timer { id: cycleGate; interval: 500 }

  // New displays nothing is saved for, or the `choose` call: bring the panel
  // up with its quick choices. `"openOnNewDisplay": false` in the widget's
  // shell.json entry turns the automatic part off.
  readonly property bool openOnNewDisplay: {
    var value = setting("openOnNewDisplay", true)
    return value !== false && value !== "false"
  }

  Timer {
    interval: 700
    running: root.service !== null && root.service.chooserWanted === true
      && root.onFocusedScreen && panelLoader.item !== null
    onTriggered: {
      if (root.service.chooserWanted !== true) return
      var asked = root.service.chooserAsked === true
      root.service.chooserWanted = false
      root.service.chooserAsked = false
      if ((asked || root.openOnNewDisplay) && !root.opened) root.open()
    }
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  GridLayout {
    id: content
    anchors.fill: parent
    columns: root.vertical ? 1 : 2
    columnSpacing: 0
    rowSpacing: 0

    Loader {
      id: stripLoader
      // Omarchy 4.5 and later number workspaces per monitor, and their own
      // switcher shows each monitor's; this one only knows the old numbering.
      active: root.showWorkspaces && !(root.service && root.service.perMonitor)
      visible: active
      source: Qt.resolvedUrl("WorkspaceStrip.qml")
      onLoaded: {
        item.bar = Qt.binding(function() { return root.bar })
        item.service = Qt.binding(function() { return root.service })
      }
    }

    BarIconButton {
      id: button
      bar: root.bar
      // Not the two-monitor glyph: Omarchy's own Display widget uses that.
      text: "󰨇"
      tooltipText: root.statusText
      onPressed: function(b) {
        if (b === Qt.RightButton) {
          if (root.service && root.service.activeProfile)
            root.service.applyProfile(root.service.activeProfile.id)
        } else if (b === Qt.MiddleButton) {
          root.cycle(1)
        } else {
          root.toggle()
        }
      }
      onWheelMoved: function(delta) { root.cycle(delta < 0 ? 1 : -1) }

      // Small and tucked into the icon's corner, so it does not read as one
      // more workspace number.
      Text {
        visible: root.screenNumber > 0
        textFormat: Text.PlainText
        text: String(root.screenNumber)
        color: root.bar ? root.bar.barForeground : Color.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: Style.space(1)
        anchors.bottomMargin: Style.space(2)
      }
    }
  }
}
