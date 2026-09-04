#!/usr/bin/env node

const fs = require("fs")
const path = require("path")
const vm = require("vm")

const modelPath = path.join(__dirname, "..", "SpanModel.js")
const source = fs.readFileSync(modelPath, "utf8").replace(/^\.pragma library\s*/, "")
const model = {}
vm.createContext(model)
vm.runInContext(source, model, { filename: modelPath })

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

const monitors = [
  { name: "RIGHT", x: 2560, y: 360, width: 1920, height: 1080 },
  { name: "LEFT", x: 0, y: 0, width: 2560, height: 1440 }
]

const bounds = model.unionBounds(monitors)
assert(bounds.x === 0 && bounds.y === 0, "union origin is wrong")
assert(bounds.width === 4480 && bounds.height === 1440, "union size is wrong")

const crops = model.cropRects(monitors)
assert(crops.monitors[0].name === "LEFT", "monitors should be position-sorted")
assert(crops.monitors[1].cropX === 2560, "right crop x is wrong")
assert(crops.monitors[1].cropY === 360, "right crop y is wrong")

const selected = model.selectByNames(monitors, { RIGHT: true })
assert(selected.length === 1 && selected[0].name === "RIGHT", "selection failed")

const signature = model.signature(monitors)
assert(signature === "LEFT:0:0:2560:1440|RIGHT:2560:360:1920:1080", "signature is unstable")

const parsed = model.parseState(JSON.stringify({
  source: "/source.jpg",
  monitors: [
    { name: "LEFT", x: 0, y: 0, width: 10, height: 20, file: "/left.png" }
  ]
}))
assert(parsed.error === "", "valid state did not parse")
assert(parsed.state.scaleMode === "fill", "legacy state should default to fill")
assert(model.cropPathFor(parsed.state, "LEFT") === "/left.png", "crop lookup failed")
assert(model.parseState("not json").error !== "", "invalid state was accepted")

console.log("SpanModel tests passed")
