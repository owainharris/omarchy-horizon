#!/usr/bin/env node

const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

// Exercise the actual controller functions without creating desktop windows.
const qml = fs.readFileSync(path.join(__dirname, "..", "Overlay.qml"), "utf8")
const context = {
  clearRequested: false,
  pendingCropJob: { source: "pending" },
  stateData: { source: "active" },
  stateReadProcess: { running: true, cancel() { this.cancelled = true } },
  cropProcess: { running: true, cancel() { this.cancelled = true } },
  clearProcess: { running: false, begin() { this.running = true; this.starts++ }, starts: 0 },
  helperCommand(action) { return [action] },
}
context.root = context
vm.createContext(context)
for (const name of ["clearSpan", "finishClear", "queueCrop", "maybeRelayout", "close", "dismiss"]) {
  const match = qml.match(new RegExp(`^  function ${name}\\([^]*?^  }`, "m"))
  assert.ok(match, `missing controller function ${name}`)
  vm.runInContext(match[0], context)
}

context.clearSpan(true)
assert.equal(context.clearRequested, true)
assert.equal(context.pendingCropJob, null)
assert.equal(context.cropProcess.cancelled, true)
assert.equal(context.stateReadProcess.cancelled, true)
assert.equal(context.clearProcess.starts, 0, "clear must wait for the old writer and reader")
assert.equal(context.stateData.source, "active", "keep the displayed span until clear succeeds")
context.queueCrop("new", [], false, "fill")
assert.equal(context.pendingCropJob, null, "ignore new crops while clearing")
context.cropProcess.running = false
context.finishClear()
assert.equal(context.clearProcess.starts, 0, "the stale read must finish first")
context.stateReadProcess.running = false
context.finishClear()
assert.equal(context.clearProcess.starts, 1)
assert.equal(context.clearProcess.dismissAfter, true)
context.clearSpan(false)
assert.equal(context.clearProcess.starts, 1, "repeated clear must not start another writer")

context.opened = true
context.filePickerProcess = { running: true, cancel() { this.cancelled = true } }
context.importProcess = { running: true, cancel() { this.cancelled = true } }
context.shell = null
context.dismiss()
assert.equal(context.opened, false)
assert.equal(context.filePickerWasCancelled, true)
assert.equal(context.filePickerProcess.cancelled, true)
assert.equal(context.importProcess.cancelled, true)
console.log("Overlay controller tests passed")
