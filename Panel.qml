import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.marioxabel.hyprsunset"
  ipcTarget: "io.github.marioxabel.hyprsunset"
  manageIpc: false

  property real wheelAccumulator: 0
  property string focusSection: "header"
  property int selectedIndex: 0
  property bool cursorActive: false
  property bool adjusting: false
  property var rows: []
  property var queue: []
  property string pendingMonitorText: ""
  property string pendingLiveText: ""
  property int refreshGen: 0

  readonly property string helper: {
    var path = Qt.resolvedUrl("bin/sunset-ctm").toString()
    if (path.indexOf("file://") === 0) path = decodeURIComponent(path.substring(7))
    return path
  }
  readonly property int defaultNight: Model.clampNight(setting("nightTemperature", Model.DEFAULT_NIGHT_TEMPERATURE))
  readonly property var savedMonitors: {
    var saved = setting("monitors", ({}))
    return saved && typeof saved === "object" ? saved : ({})
  }
  readonly property var panelSummary: Model.summary(rows)
  readonly property bool enabled: panelSummary.enabled === true
  readonly property string controlTarget: Model.normalizeTarget(String(setting("controlTarget", "all")), rows)
  readonly property bool controllingAll: rows.length > 1 && controlTarget === "all"
  readonly property int sliderTemperature: Model.sliderValue(rows, controlTarget, defaultNight)
  readonly property bool targetEnabled: {
    if (controllingAll || rows.length === 0) return enabled
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && rows[i].name === controlTarget) return rows[i].enabled === true
    }
    return false
  }
  readonly property var targetPills: {
    if (rows.length < 2) return []
    var list = [{ id: "all", label: strings.t("panel.all", "All") }]
    for (var i = 0; i < rows.length; i++) list.push({ id: rows[i].name, label: displayLabel(rows[i]) })
    return list
  }
  readonly property string moodName: {
    if (adjusting && tempSlider && tempSlider.dragging) return Model.temperatureName(tempSlider.liveValue, true)
    if (!targetEnabled) return strings.t("panel.daylight", "Daylight")
    if (controllingAll && panelSummary.mixed) return strings.t("panel.mixed", "Mixed")
    return Model.temperatureName(sliderTemperature, true)
  }
  readonly property string toggleHint: targetEnabled
    ? strings.t("panel.turnOff", "Turn off")
    : strings.t("panel.turnOn", "Turn on")
  readonly property bool headerHasCursor: cursorActive && focusSection === "header"
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations {
    id: strings
    directory: Qt.resolvedUrl("i18n")
  }

  function findRow(name) {
    for (var i = 0; i < rows.length; i++) {
      if (rows[i] && rows[i].name === name) return rows[i]
    }
    return null
  }

  function patchRow(name, changes) {
    var next = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!row || row.name !== name) {
        next.push(row)
        continue
      }
      var copy = {}
      for (var key in row) copy[key] = row[key]
      for (var change in changes) copy[change] = changes[change]
      next.push(copy)
    }
    rows = next
  }

  function patchAll(changesFor) {
    var next = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var changes = changesFor(row)
      if (!changes) {
        next.push(row)
        continue
      }
      var copy = {}
      for (var key in row) copy[key] = row[key]
      for (var change in changes) copy[change] = changes[change]
      next.push(copy)
    }
    rows = next
  }

  function helperArgs(name, action, value) {
    return Model.outputCommand(helper, name, action, value)
  }

  function enqueue(args) {
    if (!args || args.length === 0) return
    var kept = []
    for (var i = 0; i < queue.length; i++) {
      var old = queue[i]
      var sameOutput = old.length >= 4 && args.length >= 4 && old[1] === "output" && args[1] === "output" && old[2] === args[2] && old[3] === args[3]
      var sameGlobal = old.length >= 2 && args.length >= 2 && old[1] !== "output" && old[1] === args[1]
      if (sameOutput || sameGlobal) continue
      kept.push(old)
    }
    kept.push(args)
    queue = kept
    pump()
  }

  function pump() {
    if (applyProc.running || queue.length === 0) return
    var next = queue[0]
    queue = queue.slice(1)
    applyProc.command = next
    applyProc.running = true
  }

  function refresh() {
    refreshGen = refreshGen + 1
    pendingMonitorText = ""
    pendingLiveText = ""
    monitorProc.generation = refreshGen
    liveProc.generation = refreshGen
    if (!monitorProc.running) monitorProc.running = true
    if (!liveProc.running) liveProc.running = true
  }

  function finishRefresh() {
    if (pendingMonitorText === "" || pendingLiveText === "") return
    if (adjusting || queue.length > 0 || applyProc.running) return
    var monitors = Model.parseMonitors(pendingMonitorText)
    var live = Model.parseLiveOutputs(pendingLiveText)
    if (!live) live = ({})
    var merged = Model.mergeRows(monitors, live, savedMonitors, defaultNight)
    rows = merged
    adoptLive(merged)
    clampCursor()
  }

  function adoptLive(merged) {
    var saved = savedMonitors
    var monitors = {}
    var changed = false
    for (var key in saved) monitors[key] = saved[key]
    for (var i = 0; i < merged.length; i++) {
      var row = merged[i]
      if (!row.enabled) continue
      var prev = monitors[row.name]
      var prevTemp = prev && typeof prev === "object" ? Number(prev.temperature) : Number(prev)
      if (prevTemp !== row.temperature) {
        monitors[row.name] = { temperature: row.temperature }
        changed = true
      }
    }
    if (changed) writeMonitors(monitors, null)
  }

  function writeSettings(changes) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var change in changes) entry[change] = changes[change]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function writeMonitors(monitors, night) {
    var changes = { monitors: monitors }
    if (night !== null && night !== undefined) changes.nightTemperature = Model.clampNight(night)
    writeSettings(changes)
  }

  function selectTarget(id) {
    if (id !== "all" && !Model.isOutputName(id)) return
    if (id === controlTarget) return
    writeSettings({ controlTarget: id })
    for (var i = 0; i < targetPills.length; i++) {
      if (targetPills[i].id === id) selectedIndex = i
    }
  }

  function rememberMany(updates, night) {
    var monitors = {}
    var saved = savedMonitors
    var name
    for (name in saved) {
      var value = saved[name]
      var temperature = value && typeof value === "object" ? value.temperature : value
      monitors[name] = { temperature: Model.clampNight(temperature) }
    }
    for (name in updates) monitors[name] = { temperature: Model.clampNight(updates[name]) }
    writeMonitors(monitors, night)
  }

  function remember(name, temperature) {
    var updates = {}
    updates[name] = temperature
    rememberMany(updates, temperature)
  }

  function setOutputTemperature(name, temperature) {
    var night = Model.clampNight(temperature)
    var args = helperArgs(name, "temperature", night)
    if (!args) return
    patchRow(name, { enabled: true, temperature: night, remembered: night })
    remember(name, night)
    enqueue(args)
  }

  function setOutputIdentity(name) {
    var row = findRow(name)
    var args = helperArgs(name, "identity")
    if (!row || !args) return
    var keep = row.enabled ? row.temperature : row.remembered
    patchRow(name, { enabled: false, temperature: keep, remembered: keep })
    remember(name, keep)
    enqueue(args)
  }

  function setOutputEnabled(name, on) {
    if (on) {
      var row = findRow(name)
      if (!row) return
      setOutputTemperature(name, row.remembered)
    } else {
      setOutputIdentity(name)
    }
  }

  function turnAllOff() {
    var updates = {}
    patchAll(function(row) {
      var keep = row.enabled ? row.temperature : row.remembered
      updates[row.name] = keep
      return { enabled: false, temperature: keep, remembered: keep }
    })
    if (Object.keys(updates).length > 0) rememberMany(updates, null)
    enqueue([helper, "identity"])
  }

  function turnAllOn() {
    var pending = []
    for (var i = 0; i < rows.length; i++) pending.push(rows[i])
    if (pending.length === 0) {
      enqueue([helper, "temperature", String(defaultNight)])
      return
    }
    patchAll(function(row) {
      return { enabled: true, temperature: row.remembered, remembered: row.remembered }
    })
    for (var j = 0; j < pending.length; j++) {
      var args = helperArgs(pending[j].name, "temperature", pending[j].remembered)
      if (args) enqueue(args)
    }
  }

  function applySharedTemperature(night) {
    var updates = {}
    patchAll(function(row) {
      updates[row.name] = night
      return { enabled: true, temperature: night, remembered: night }
    })
    if (Object.keys(updates).length > 0) rememberMany(updates, night)
    else writeSettings({ nightTemperature: night })
    enqueue([helper, "temperature", String(night)])
  }

  function previewTarget(temperature) {
    var night = Model.clampNight(temperature)
    adjusting = true
    if (controllingAll || rows.length === 0) enqueue([helper, "temperature", String(night)])
    else {
      var args = helperArgs(controlTarget, "temperature", night)
      if (args) enqueue(args)
    }
  }

  function commitTarget(temperature) {
    var night = Model.clampNight(temperature)
    adjusting = false
    if (controllingAll || rows.length === 0) applySharedTemperature(night)
    else setOutputTemperature(controlTarget, night)
  }

  function toggleTarget() {
    if (controllingAll || rows.length === 0) {
      if (targetEnabled) turnAllOff()
      else commitTarget(sliderTemperature)
      return
    }
    setOutputEnabled(controlTarget, !targetEnabled)
  }

  function nudgeTarget(steps) {
    if (!steps) return
    var next = Model.nextTemperature(sliderTemperature, steps)
    commitTarget(next)
    showOsd(next)
  }

  function showOsd(temperature) {
    if (!bar || !bar.shell) return
    var label = strings.t("panel.all", "All")
    if (!controllingAll && rows.length > 0) {
      var row = findRow(controlTarget)
      label = row ? displayLabel(row) : ""
    }
    if (rows.length < 2) label = ""
    label = Model.plainText(label)
    var text = label ? (label + " " + temperature + "K") : (temperature + "K")
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: "󰔎",
      value: Model.nightPercent(temperature),
      max: 100,
      progressText: text
    }))
  }

  function pokeIndicator() {
    var nightlight = bar && bar.shell && bar.shell.firstPartyServiceFor
      ? bar.shell.firstPartyServiceFor("omarchy.nightlight")
      : null
    if (nightlight && typeof nightlight.refresh === "function") nightlight.refresh()
  }

  function focusSections() {
    var list = ["header"]
    if (rows.length > 1) list.push("targets")
    list.push("slider")
    return list
  }

  function clampCursor() {
    var list = focusSections()
    if (list.indexOf(focusSection) < 0) focusSection = "header"
    if (focusSection === "targets") {
      if (selectedIndex > targetPills.length - 1) selectedIndex = Math.max(0, targetPills.length - 1)
      if (selectedIndex < 0) selectedIndex = 0
    }
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    var list = focusSections()
    var idx = list.indexOf(focusSection)
    if (idx < 0) idx = 0
    if (dy > 0 && idx < list.length - 1) {
      focusSection = list[idx + 1]
      if (focusSection === "targets") selectedIndex = pillIndex()
      return
    }
    if (dy < 0 && idx > 0) {
      focusSection = list[idx - 1]
      if (focusSection === "targets") selectedIndex = pillIndex()
      return
    }
    if (dx !== 0 && focusSection === "targets") {
      var next = selectedIndex + dx
      if (next < 0) next = 0
      if (next > targetPills.length - 1) next = targetPills.length - 1
      selectedIndex = next
      if (targetPills[next]) selectTarget(targetPills[next].id)
      return
    }
    if (dx !== 0) nudgeTarget(dx)
  }

  function pillIndex() {
    for (var i = 0; i < targetPills.length; i++) {
      if (targetPills[i].id === controlTarget) return i
    }
    return 0
  }

  function activateCursor() {
    if (!cursorActive) {
      cursorActive = true
      return
    }
    if (focusSection === "targets" && targetPills[selectedIndex]) selectTarget(targetPills[selectedIndex].id)
    else toggleTarget()
  }

  function tooltipText() {
    if (!enabled) return strings.t("panel.off", "Night Light off")
    if (controllingAll && panelSummary.mixed) return strings.t("panel.mixedTip", "Night Light, per display")
    if (!controllingAll && rows.length > 1) {
      var row = findRow(controlTarget)
      return strings.t("panel.onDisplay", "%1 %2K").arg(Model.plainText(displayLabel(row))).arg(sliderTemperature)
    }
    return strings.t("panel.on", "Night Light %1K").arg(panelSummary.temperature || sliderTemperature)
  }

  function displayLabel(row) {
    if (!row) return ""
    return row.builtin ? strings.t("panel.builtIn", "Built-in") : row.label
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      focusSection = "header"
      selectedIndex = pillIndex()
      cursorActive = false
    }
  }

  onBarChanged: refresh()

  Component.onCompleted: refresh()

  Timer {
    interval: 4000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: monitorProc
    property int generation: 0
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (monitorProc.generation !== root.refreshGen) return
        root.pendingMonitorText = text
        root.finishRefresh()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && monitorProc.generation === root.refreshGen && root.pendingMonitorText === "") {
        root.pendingMonitorText = "[]"
        root.finishRefresh()
      }
    }
  }

  Process {
    id: liveProc
    property int generation: 0
    command: [root.helper, "outputs"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (liveProc.generation !== root.refreshGen) return
        root.pendingLiveText = text
        root.finishRefresh()
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && liveProc.generation === root.refreshGen && root.pendingLiveText === "") {
        root.pendingLiveText = "{\"outputs\":[]}"
        root.finishRefresh()
      }
    }
  }

  Process {
    id: applyProc
    onExited: function() {
      root.pump()
      if (root.queue.length === 0 && !applyProc.running) {
        root.pokeIndicator()
        if (!root.adjusting) root.refresh()
      }
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
      root.turnAllOn()
      return "enabled"
    }

    function disable(): string {
      root.turnAllOff()
      return "disabled"
    }

    function toggleNightlight(): string {
      var enabling = !root.targetEnabled
      root.toggleTarget()
      return enabling ? "enabled" : "disabled"
    }

    function setTemperature(value: string): string {
      var next = Model.clampNight(value)
      root.patchAll(function() { return { enabled: true, temperature: next, remembered: next } })
      for (var i = 0; i < root.rows.length; i++) root.remember(root.rows[i].name, next)
      root.enqueue([root.helper, "temperature", String(next)])
      return String(next)
    }

    function setOutputTemperature(name: string, value: string): string {
      if (!Model.isOutputName(name)) return "invalid output"
      var next = Model.clampNight(value)
      root.setOutputTemperature(name, next)
      return String(next)
    }

    function status(): string {
      return JSON.stringify({
        enabled: root.enabled,
        mixed: root.panelSummary.mixed === true,
        temperature: root.panelSummary.temperature,
        nightTemperature: root.defaultNight,
        target: root.controlTarget,
        monitors: root.rows
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰔎"
    active: root.enabled
    tooltipText: root.tooltipText()
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleTarget()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.nudgeTarget(wheel.steps)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "m" || t === "M") root.toggleTarget()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth > 0 ? scrollArea.availableWidth : parent.width
          spacing: Style.space(14)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() {
              root.cursorActive = true
              root.focusSection = "header"
            }

            PanelHero {
              id: hero
              width: parent.width
              title: strings.t("panel.title", "Night Light")
              meta: root.moodName
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.enabled ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  text: "󰔎"
                  textFormat: Text.PlainText
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: root.targetEnabled
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: root.toggleTarget()

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

          PanelSectionHeader {
            text: strings.t("panel.displays", "DISPLAYS")
            foreground: root.foreground
            fontFamily: root.fontFamily
            visible: root.rows.length > 1
          }

          Grid {
            id: targetRow
            visible: root.rows.length > 1
            width: parent.width
            columns: Math.max(1, root.targetPills.length)
            spacing: Style.spacing.xs

            readonly property real cellWidth: columns > 0
              ? (width - spacing * (columns - 1)) / columns
              : width

            Repeater {
              model: root.targetPills

              TargetPill {
                required property var modelData
                required property int index
                width: targetRow.cellWidth
                pillId: modelData.id
                pillLabel: modelData.label
                pillIndex: index
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
            visible: root.rows.length > 1
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(tempHeader.implicitHeight, tempValue.implicitHeight)

              PanelSectionHeader {
                id: tempHeader
                text: strings.t("panel.temperature", "TEMPERATURE")
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: tempValue
                textFormat: Text.PlainText
                text: Commons.I18n.formatNumber(Math.round(tempSlider.dragging ? tempSlider.liveValue : root.sliderTemperature)) + "K"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.targetEnabled || tempSlider.dragging ? 1.0 : 0.5
              }
            }

            CursorSurface {
              width: parent.width
              height: tempSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "slider"
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
                opacity: root.targetEnabled || dragging ? 1.0 : 0.55
                onMoved: function(v) {
                  if (!dragging) return
                  root.cursorActive = true
                  root.focusSection = "slider"
                  root.previewTarget(v)
                }
                onReleased: function(v) { root.commitTarget(v) }
                onRightClicked: root.toggleTarget()
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "slider"
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  component TargetPill: Button {
    id: pill
    required property string pillId
    required property string pillLabel
    required property int pillIndex

    text: pillLabel
    fontSize: Style.font.caption
    foreground: root.foreground
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.sm
    verticalPadding: Style.spacing.controlPaddingY
    bordered: true
    active: pillId === root.controlTarget
    hasCursor: root.cursorActive && root.focusSection === "targets" && root.selectedIndex === pillIndex

    onClicked: root.selectTarget(pillId)
    onHovered: function(isHovered) {
      if (!isHovered) return
      root.cursorActive = true
      root.focusSection = "targets"
      root.selectedIndex = pill.pillIndex
    }
  }
}
