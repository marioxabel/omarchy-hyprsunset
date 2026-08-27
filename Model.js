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
    nextTemperature: nextTemperature
  }
}
