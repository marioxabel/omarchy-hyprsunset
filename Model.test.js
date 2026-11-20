const Model = require("./Model.js")
const assert = require("assert")

assert.strictEqual(Model.temperatureFromOutput("The current temperature is 4000K\n"), 4000)
assert.strictEqual(Model.temperatureFromOutput(""), null)
assert.strictEqual(Model.isNightlight(4000), true)
assert.strictEqual(Model.isNightlight(6500), false)
assert.strictEqual(Model.isNightlight(6000), false)
assert.strictEqual(Model.isNightlight(null), false)
assert.strictEqual(Model.clampNight(1999), 2000)
assert.strictEqual(Model.clampNight(5600), 5500)
assert.strictEqual(Model.clampNight(4049), 4000)
assert.strictEqual(Model.clampNight(4050), 4100)
assert.strictEqual(Model.nightOrDefault(6500), 4000)
assert.strictEqual(Model.nightOrDefault(3200), 3200)
assert.strictEqual(Model.temperatureName(4000, true), "Warm")
assert.strictEqual(Model.temperatureName(4000, false), "Daylight")
assert.strictEqual(Model.nextTemperature(4000, -1), 3900)
assert.strictEqual(Model.nextTemperature(2000, -1), 2000)
assert.strictEqual(Model.nightPercent(2000), 100)
assert.strictEqual(Model.nightPercent(5500), 0)

assert.strictEqual(Model.isOutputName("eDP-1"), true)
assert.strictEqual(Model.isOutputName("HDMI-A-1"), true)
assert.strictEqual(Model.isOutputName("DP-3"), true)
assert.strictEqual(Model.isOutputName("-DP-1"), false)
assert.strictEqual(Model.isOutputName("eDP-1;rm"), false)
assert.strictEqual(Model.isOutputName("eDP 1"), false)
assert.strictEqual(Model.isOutputName(""), false)
assert.strictEqual(Model.isBuiltinOutput("eDP-1"), true)
assert.strictEqual(Model.isBuiltinOutput("DP-3"), false)
assert.strictEqual(Model.monitorLabel({ name: "eDP-1", model: "0x0804" }), "Built-in")
assert.strictEqual(Model.monitorLabel({ name: "DP-3", model: "LG ULTRAWIDE" }), "LG ULTRAWIDE")

var monitors = Model.parseMonitors(JSON.stringify([
  { name: "eDP-1", model: "0x0804", description: "BOE 0x0804", focused: false, disabled: false },
  { name: "DP-3", model: "LG ULTRAWIDE", description: "LG Electronics LG ULTRAWIDE", focused: true },
  { name: "bad;name", model: "Nope", focused: false },
  { name: "HDMI-A-1", model: "Off", disabled: true }
]))
assert.strictEqual(monitors.length, 2)
assert.strictEqual(monitors[0].name, "eDP-1")
assert.strictEqual(monitors[1].focused, true)

var live = Model.parseLiveOutputs(JSON.stringify({
  outputs: [
    { name: "eDP-1", kelvin: 3200, identity: false },
    { name: "DP-3", kelvin: 4500, identity: true },
    { name: "bad name", kelvin: 2000, identity: false }
  ]
}))
assert.strictEqual(live["eDP-1"].kelvin, 3200)
assert.strictEqual(live["DP-3"].identity, true)
assert.strictEqual(live["bad name"], undefined)
assert.strictEqual(Model.parseLiveOutputs("not json"), null)

var rows = Model.mergeRows(monitors, live, { "DP-3": { temperature: 4500 } }, 4000)
assert.strictEqual(rows[0].enabled, true)
assert.strictEqual(rows[0].temperature, 3200)
assert.strictEqual(rows[0].builtin, true)
assert.strictEqual(rows[1].enabled, false)
assert.strictEqual(rows[1].temperature, 4500)
assert.strictEqual(rows[1].label, "LG ULTRAWIDE")

var off = Model.mergeRows(monitors, { "eDP-1": { kelvin: 4000, identity: true } }, {}, 2000)
assert.strictEqual(off[0].enabled, false)
assert.strictEqual(off[0].remembered, 2000)

var mixed = Model.summary(rows)
assert.strictEqual(mixed.enabled, true)
assert.strictEqual(mixed.mixed, false)
assert.strictEqual(mixed.count, 1)
rows[1] = Object.assign({}, rows[1], { enabled: true, temperature: 4500 })
assert.strictEqual(Model.summary(rows).mixed, true)
assert.strictEqual(Model.summary(off).enabled, false)
assert.strictEqual(Model.focusedRow(rows).name, "DP-3")

assert.deepStrictEqual(
  Model.outputCommand("/bin/sunset-ctm", "eDP-1", "temperature", 3333),
  ["/bin/sunset-ctm", "output", "eDP-1", "temperature", "3300"]
)
assert.deepStrictEqual(
  Model.outputCommand("/bin/sunset-ctm", "DP-3", "identity"),
  ["/bin/sunset-ctm", "output", "DP-3", "identity"]
)
assert.strictEqual(Model.outputCommand("/bin/sunset-ctm", "eDP-1;rm", "temperature", 3000), null)
assert.strictEqual(Model.outputCommand("/bin/sunset-ctm", "eDP-1", "gamma", 1), null)

assert.strictEqual(Model.normalizeTarget("DP-3", rows), "DP-3")
assert.strictEqual(Model.normalizeTarget("eDP-1;rm", rows), "all")
assert.strictEqual(Model.normalizeTarget("missing", rows), "all")
assert.strictEqual(Model.normalizeTarget("all", rows), "all")
assert.strictEqual(Model.normalizeTarget("all", [rows[0]]), "eDP-1")
assert.strictEqual(Model.targetRows(rows, "DP-3").length, 1)
assert.strictEqual(Model.targetRows(rows, "all").length, 2)
assert.strictEqual(Model.sliderValue(rows, "eDP-1", 2000), 3200)
assert.strictEqual(Model.sliderValue(rows, "all", 2000), 3200)
assert.strictEqual(Model.plainText("LG <img src='x'>"), "LG img src='x'")
assert.strictEqual(Model.plainText("Built-in"), "Built-in")

console.log("ok")
