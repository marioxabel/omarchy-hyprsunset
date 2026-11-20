// Temperatures below the identity point count as night light. Keep the
// threshold in sync with omarchy.nightlight / omarchy-toggle-nightlight.
var IDENTITY_TEMPERATURE = 6000
var DAY_TEMPERATURE = 6500
var MIN_TEMPERATURE = 2000
var MAX_NIGHT_TEMPERATURE = 5500
var DEFAULT_NIGHT_TEMPERATURE = 4000
var STEP = 100

function toNumber(value) {
  if (value === null || value === undefined || value === "") return null
  var n = Number(value)
  return isFinite(n) ? n : null
}

function temperatureFromOutput(output) {
  var match = String(output === undefined || output === null ? "" : output).match(/[0-9]+/)
  return match ? Number(match[0]) : null
}

function isNightlight(temperature) {
  var n = toNumber(temperature)
  return n !== null && n < IDENTITY_TEMPERATURE
}

function roundToStep(value, step) {
  var size = step > 0 ? step : STEP
  return Math.round(Number(value) / size) * size
}

function clamp(value, min, max) {
  var n = toNumber(value)
  if (n === null) return min
  return Math.max(min, Math.min(max, n))
}

function clampNight(temperature) {
  return clamp(roundToStep(temperature, STEP), MIN_TEMPERATURE, MAX_NIGHT_TEMPERATURE)
}

function clampTemperature(temperature) {
  return clamp(roundToStep(temperature, STEP), MIN_TEMPERATURE, DAY_TEMPERATURE)
}

function nightOrDefault(temperature) {
  return isNightlight(temperature) ? clampNight(temperature) : DEFAULT_NIGHT_TEMPERATURE
}

function temperatureName(temperature, enabled) {
  if (!enabled) return "Daylight"
  var n = toNumber(temperature)
  if (n === null) return "Unknown"
  if (n <= 2200) return "Ember"
  if (n <= 2700) return "Candle"
  if (n <= 3200) return "Hearth"
  if (n <= 3700) return "Sunset"
  if (n <= 4200) return "Warm"
  if (n <= 4800) return "Soft white"
  return "Neutral"
}

// Warmer color (lower Kelvin) fills more of the OSD bar.
function nightPercent(temperature) {
  var n = clampNight(temperature)
  var span = MAX_NIGHT_TEMPERATURE - MIN_TEMPERATURE
  if (span <= 0) return 0
  return Math.round(((MAX_NIGHT_TEMPERATURE - n) / span) * 100)
}

function nextTemperature(temperature, steps) {
  return clampNight((toNumber(temperature) || DEFAULT_NIGHT_TEMPERATURE) + (steps * STEP))
}

// Hyprland connector names. Reject anything that could be mistaken for a flag
// or a second argument.
function isOutputName(name) {
  return /^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$/.test(String(name === undefined || name === null ? "" : name))
}

function isBuiltinOutput(name) {
  return /^eDP/i.test(String(name || ""))
}

function monitorLabel(monitor) {
  if (!monitor) return ""
  if (isBuiltinOutput(monitor.name)) return "Built-in"
  var model = String(monitor.model || "").trim()
  if (model && !/^0x[0-9a-f]+$/i.test(model)) return model
  var description = String(monitor.description || "").trim()
  if (description) return description
  return String(monitor.name || "")
}

function parseMonitors(raw) {
  var list = []
  try {
    list = raw ? JSON.parse(String(raw)) : []
  } catch (e) {
    list = []
  }
  if (!Array.isArray(list)) return []
  var out = []
  for (var i = 0; i < list.length; i++) {
    var monitor = list[i]
    if (!monitor || monitor.disabled) continue
    var name = String(monitor.name || "")
    if (!isOutputName(name)) continue
    out.push({
      name: name,
      model: String(monitor.model || ""),
      description: String(monitor.description || ""),
      focused: monitor.focused === true
    })
  }
  return out
}

function parseLiveOutputs(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!parsed || !Array.isArray(parsed.outputs)) return null
  var map = {}
  for (var i = 0; i < parsed.outputs.length; i++) {
    var output = parsed.outputs[i]
    if (!output || !isOutputName(output.name)) continue
    var kelvin = toNumber(output.kelvin)
    map[output.name] = {
      kelvin: kelvin === null ? DAY_TEMPERATURE : kelvin,
      identity: output.identity === true
    }
  }
  return map
}

function savedTemperature(savedByName, name, fallback) {
  var saved = savedByName && savedByName[name]
  if (saved && typeof saved === "object") return clampNight(saved.temperature)
  return clampNight(saved !== undefined ? saved : fallback)
}

// Live temperature wins while a display is warmed. The saved value is what the
// slider shows, and what comes back, when that display is at identity.
function mergeRows(monitors, liveByName, savedByName, defaultNight) {
  var rows = []
  var list = Array.isArray(monitors) ? monitors : []
  for (var i = 0; i < list.length; i++) {
    var monitor = list[i]
    if (!monitor || !isOutputName(monitor.name)) continue
    var remembered = savedTemperature(savedByName, monitor.name, defaultNight)
    var live = liveByName && liveByName[monitor.name]
    var enabled = !!(live && live.identity === false && isNightlight(live.kelvin))
    var shown = enabled ? clampNight(live.kelvin) : remembered
    rows.push({
      name: monitor.name,
      label: monitorLabel(monitor),
      builtin: isBuiltinOutput(monitor.name),
      focused: monitor.focused === true,
      enabled: enabled,
      temperature: shown,
      remembered: enabled ? shown : remembered
    })
  }
  return rows
}

function summary(rows) {
  var temps = []
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].enabled) temps.push(list[i].temperature)
  }
  if (temps.length === 0) return { enabled: false, mixed: false, temperature: null, count: 0 }
  var mixed = false
  for (var j = 1; j < temps.length; j++) {
    if (temps[j] !== temps[0]) mixed = true
  }
  return { enabled: true, mixed: mixed, temperature: temps[0], count: temps.length }
}

function focusedRow(rows) {
  var list = Array.isArray(rows) ? rows : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].focused) return list[i]
  }
  return list.length ? list[0] : null
}

// "all" drives every connected display from one slider. A connector name
// drives just that display. An unknown choice falls back to all when there
// is more than one screen, and to the only screen otherwise.
function normalizeTarget(target, rows) {
  var list = Array.isArray(rows) ? rows : []
  var name = String(target === undefined || target === null ? "" : target)
  if (name && name !== "all") {
    for (var i = 0; i < list.length; i++) {
      if (list[i] && list[i].name === name && isOutputName(name)) return name
    }
  }
  if (list.length > 1) return "all"
  if (list.length === 1 && list[0] && isOutputName(list[0].name)) return list[0].name
  return "all"
}

function targetRows(rows, target) {
  var list = Array.isArray(rows) ? rows : []
  var id = normalizeTarget(target, list)
  if (id === "all") return list.slice()
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].name === id) out.push(list[i])
  }
  return out
}

// One number for the shared slider. Matching displays show that number.
// A mixed group shows the first display that is actually on.
function sliderValue(rows, target, fallback) {
  var selected = targetRows(rows, target)
  if (selected.length === 0) return clampNight(fallback)
  var same = true
  for (var i = 1; i < selected.length; i++) {
    if (selected[i].temperature !== selected[0].temperature) same = false
  }
  if (same) return selected[0].temperature
  for (var j = 0; j < selected.length; j++) {
    if (selected[j].enabled) return selected[j].temperature
  }
  return selected[0].temperature
}

function plainText(value) {
  return String(value === undefined || value === null ? "" : value).replace(/[<>&]/g, "").slice(0, 80)
}

function outputCommand(bin, name, action, value) {
  if (!bin || !isOutputName(name)) return null
  if (action === "identity") return [bin, "output", name, "identity"]
  if (action === "temperature") return [bin, "output", name, "temperature", String(clampNight(value))]
  return null
}

if (typeof module !== "undefined") {
  module.exports = {
    IDENTITY_TEMPERATURE: IDENTITY_TEMPERATURE,
    DAY_TEMPERATURE: DAY_TEMPERATURE,
    MIN_TEMPERATURE: MIN_TEMPERATURE,
    MAX_NIGHT_TEMPERATURE: MAX_NIGHT_TEMPERATURE,
    DEFAULT_NIGHT_TEMPERATURE: DEFAULT_NIGHT_TEMPERATURE,
    STEP: STEP,
    temperatureFromOutput: temperatureFromOutput,
    isNightlight: isNightlight,
    clampNight: clampNight,
    clampTemperature: clampTemperature,
    nightOrDefault: nightOrDefault,
    temperatureName: temperatureName,
    nightPercent: nightPercent,
    nextTemperature: nextTemperature,
    isOutputName: isOutputName,
    isBuiltinOutput: isBuiltinOutput,
    monitorLabel: monitorLabel,
    parseMonitors: parseMonitors,
    parseLiveOutputs: parseLiveOutputs,
    mergeRows: mergeRows,
    summary: summary,
    focusedRow: focusedRow,
    normalizeTarget: normalizeTarget,
    targetRows: targetRows,
    sliderValue: sliderValue,
    plainText: plainText,
    outputCommand: outputCommand
  }
}
