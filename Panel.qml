import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.marioxabel.hyprsunset"
  ipcTarget: "io.github.marioxabel.hyprsunset"
  manageIpc: false

  property real wheelAccumulator: 0
  property string focusSection: "header"
  property bool cursorActive: false
  property int fallbackTemperature: Model.DAY_TEMPERATURE
  property bool fallbackLoaded: false
  property bool hasPendingTemperature: false
  property int pendingTemperature: 0
  property int lastNightTemperature: Model.DEFAULT_NIGHT_TEMPERATURE

  readonly property var nightlight: bar?.shell?.firstPartyServiceFor("omarchy.nightlight")
  readonly property bool usingService: !!(nightlight && typeof nightlight.applyTemperature === "function")
  readonly property int liveTemperature: {
    if (usingService && nightlight.temperature !== null && nightlight.temperature !== undefined)
      return Number(nightlight.temperature)
    return fallbackTemperature
  }
  readonly property bool enabled: usingService
    ? nightlight.enabled === true
    : (fallbackLoaded && Model.isNightlight(fallbackTemperature))
  readonly property int rememberedNight: Model.clampNight(setting("nightTemperature", lastNightTemperature))
  readonly property int sliderTemperature: enabled ? Model.clampNight(liveTemperature) : rememberedNight
  readonly property string moodName: Model.temperatureName(
    tempSlider.dragging ? tempSlider.liveValue : sliderTemperature,
    enabled || tempSlider.dragging
  )
  readonly property string toggleHint: enabled ? "Turn off" : "Turn on"
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property bool sliderHasCursor: cursorActive && focusSection === "slider"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    if (usingService) {
      nightlight.refresh()
      return
    }
    if (!statusProbe.running) statusProbe.running = true
  }

  function persistNightTemperature(temp) {
    var night = Model.clampNight(temp)
    root.lastNightTemperature = night
    if (Number(setting("nightTemperature", 0)) === night) return

    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.nightTemperature = night
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function applyTemperature(temp) {
    var next = Model.clampTemperature(temp)
    if (Model.isNightlight(next)) {
      root.lastNightTemperature = Model.clampNight(next)
      persistTimer.restart()
    }

    if (usingService) {
      nightlight.applyTemperature(next)
      return
    }

    root.fallbackTemperature = next
    root.fallbackLoaded = true
    if (applyProcess.running) {
      root.pendingTemperature = next
      root.hasPendingTemperature = true
      return
    }
    runApply(next)
  }

  function runApply(temp) {
    applyProcess.command = ["bash", "-lc",
      "pgrep -x hyprsunset >/dev/null || { setsid uwsm-app -- hyprsunset >/dev/null 2>&1 & sleep 1; }; " +
      "hyprctl hyprsunset temperature " + Number(temp)]
    applyProcess.running = true
  }

  function setEnabled(on) {
    if (on) applyTemperature(root.rememberedNight)
    else applyTemperature(Model.DAY_TEMPERATURE)
  }

  function toggleNightlight() {
    setEnabled(!enabled)
  }

  function nudgeTemperature(steps) {
    if (steps === 0) return
    var base = enabled ? sliderTemperature : rememberedNight
    applyTemperature(Model.nextTemperature(base, steps))
    showTemperatureOsd()
  }

  function showTemperatureOsd() {
    if (!bar || !bar.shell) return
    var temp = enabled ? Model.clampNight(liveTemperature) : rememberedNight
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "󰔎",
      value: Model.nightPercent(temp),
      max: 100,
      progressText: temp + "K"
    }))
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
  }

  function setSliderCursor() {
    cursorActive = true
    focusSection = "slider"
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    if (dy !== 0) {
      focusSection = dy > 0 ? "slider" : "header"
      return
    }
    if (dx !== 0) nudgeTemperature(dx)
  }

  function activateCursor() {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    toggleNightlight()
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      focusSection = "header"
      cursorActive = false
    }
  }

  onBarChanged: refresh()

  Component.onCompleted: {
    root.lastNightTemperature = Model.clampNight(setting("nightTemperature", Model.DEFAULT_NIGHT_TEMPERATURE))
    refresh()
  }

  Timer {
    id: persistTimer
    interval: 400
    repeat: false
    onTriggered: root.persistNightTemperature(root.lastNightTemperature)
  }

  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProbe
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var temp = Model.temperatureFromOutput(text)
        if (temp !== null) root.fallbackTemperature = temp
        root.fallbackLoaded = true
        if (Model.isNightlight(temp)) root.lastNightTemperature = Model.clampNight(temp)
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.fallbackLoaded = true
    }
  }

  Process {
    id: applyProcess
    onExited: function() {
      if (root.hasPendingTemperature) {
        root.hasPendingTemperature = false
        root.runApply(root.pendingTemperature)
        return
      }
      root.refresh()
    }
  }

  IpcHandler {
    target: "io.github.marioxabel.hyprsunset"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }

    function enable(): string {
      root.setEnabled(true)
      return "enabled"
    }

    function disable(): string {
      root.setEnabled(false)
      return "disabled"
    }

    function toggleNightlight(): string {
      var enabling = !root.enabled
      root.setEnabled(enabling)
      return enabling ? "enabled" : "disabled"
    }

    function setTemperature(value: string): string {
      var next = Model.clampNight(value)
      root.applyTemperature(next)
      root.persistNightTemperature(next)
      return String(next)
    }

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        temperature: root.liveTemperature,
        nightTemperature: root.rememberedNight
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔎"
    active: root.enabled
    tooltipText: root.enabled
      ? ("Night Light " + root.sliderTemperature + "K")
      : "Night Light off"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleNightlight()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.nudgeTemperature(wheel.steps)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "m" || t === "M") root.toggleNightlight()
      }

      Column {
        id: panelColumn
        width: parent.width
        spacing: Style.space(14)

        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight
          readonly property bool ringVisible: root.headerHasCursor
          function focusHero() { root.setHeaderCursor() }

          PanelHero {
            id: hero
            width: parent.width
            title: "Night Light"
            meta: root.moodName
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.enabled ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰔎"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                checked: root.enabled
                hasCursor: header.ringVisible
                foreground: hero.foreground
                onHovered: function(on) { if (on) header.focusHero() }
                onToggled: root.toggleNightlight()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.toggleHint
                  fontFamily: hero.fontFamily
                }
              }
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            implicitHeight: Math.max(tempHeader.implicitHeight, tempValue.implicitHeight)

            PanelSectionHeader {
              id: tempHeader
              text: "TEMPERATURE"
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: tempValue
              text: Math.round(tempSlider.dragging ? tempSlider.liveValue : root.sliderTemperature) + "K"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              opacity: root.enabled || tempSlider.dragging ? 1.0 : 0.5
            }
          }

          CursorSurface {
            id: sliderRow
            width: parent.width
            height: tempSlider.implicitHeight + Style.spacing.controlGap
            hasCursor: root.sliderHasCursor
            foreground: root.foreground
            outline: true

            PanelSlider {
              id: tempSlider
              bar: root.bar
              anchors.fill: parent
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              minimum: Model.MIN_TEMPERATURE
              maximum: Model.MAX_NIGHT_TEMPERATURE
              step: Model.STEP
              integer: true
              value: root.sliderTemperature
              opacity: root.enabled || dragging ? 1.0 : 0.55
              onMoved: function(v) {
                if (!dragging) return
                root.applyTemperature(v)
              }
              onReleased: function(v) {
                persistTimer.stop()
                root.persistNightTemperature(v)
              }
              onRightClicked: root.toggleNightlight()
            }

            HoverHandler {
              onHoveredChanged: if (hovered) root.setSliderCursor()
            }
          }
        }
      }
    }
  }
}
