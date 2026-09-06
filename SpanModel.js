.pragma library

function finiteNumber(value, fallback) {
  var number = Number(value)
  return isFinite(number) ? number : fallback
}

function validText(value, maximum) {
  var text = String(value || "")
  if (!text || text.length > maximum) return false
  for (var i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) < 32) return false
  }
  return true
}

function normalizeMonitors(monitors) {
  var source = Array.isArray(monitors) ? monitors.slice(0, 32) : []
  var result = []

  for (var i = 0; i < source.length; i++) {
    var monitor = source[i] || {}
    var name = String(monitor.name || "").trim()
    var width = Math.round(finiteNumber(monitor.width, 0))
    var height = Math.round(finiteNumber(monitor.height, 0))
    var x = Math.round(finiteNumber(monitor.x, 0))
    var y = Math.round(finiteNumber(monitor.y, 0))
    if (!validText(name, 128) || width <= 0 || height <= 0
        || width > 32768 || height > 32768
        || Math.abs(x) > 1000000 || Math.abs(y) > 1000000) continue

    result.push({
      name: name,
      x: x,
      y: y,
      width: width,
      height: height
    })
  }

  result.sort(function(left, right) {
    if (left.x !== right.x) return left.x - right.x
    if (left.y !== right.y) return left.y - right.y
    return left.name < right.name ? -1 : (left.name > right.name ? 1 : 0)
  })
  return result
}

function unionBounds(monitors) {
  var items = normalizeMonitors(monitors)
  if (items.length === 0)
    return { x: 0, y: 0, width: 0, height: 0 }

  var minX = items[0].x
  var minY = items[0].y
  var maxX = items[0].x + items[0].width
  var maxY = items[0].y + items[0].height

  for (var i = 1; i < items.length; i++) {
    minX = Math.min(minX, items[i].x)
    minY = Math.min(minY, items[i].y)
    maxX = Math.max(maxX, items[i].x + items[i].width)
    maxY = Math.max(maxY, items[i].y + items[i].height)
  }

  return { x: minX, y: minY, width: maxX - minX, height: maxY - minY }
}

function cropRects(monitors) {
  var items = normalizeMonitors(monitors)
  var bounds = unionBounds(items)
  var result = []

  for (var i = 0; i < items.length; i++) {
    result.push({
      name: items[i].name,
      x: items[i].x,
      y: items[i].y,
      width: items[i].width,
      height: items[i].height,
      cropX: items[i].x - bounds.x,
      cropY: items[i].y - bounds.y
    })
  }
  return { bounds: bounds, monitors: result }
}

function fitLayout(monitors, availableWidth, availableHeight, padding) {
  var items = normalizeMonitors(monitors)
  var bounds = unionBounds(items)
  var pad = Math.max(0, finiteNumber(padding, 0))
  var innerWidth = Math.max(1, finiteNumber(availableWidth, 1) - pad * 2)
  var innerHeight = Math.max(1, finiteNumber(availableHeight, 1) - pad * 2)
  var scale = bounds.width > 0 && bounds.height > 0
    ? Math.min(innerWidth / bounds.width, innerHeight / bounds.height)
    : 1
  var usedWidth = bounds.width * scale
  var usedHeight = bounds.height * scale
  var originX = (finiteNumber(availableWidth, 1) - usedWidth) / 2
  var originY = (finiteNumber(availableHeight, 1) - usedHeight) / 2
  var rects = []

  for (var i = 0; i < items.length; i++) {
    rects.push({
      name: items[i].name,
      x: originX + (items[i].x - bounds.x) * scale,
      y: originY + (items[i].y - bounds.y) * scale,
      width: items[i].width * scale,
      height: items[i].height * scale
    })
  }
  return { bounds: bounds, scale: scale, rects: rects }
}

function selectByNames(monitors, selectedNames) {
  var items = normalizeMonitors(monitors)
  var selected = selectedNames || {}
  var result = []
  for (var i = 0; i < items.length; i++) {
    if (selected[items[i].name] === true) result.push(items[i])
  }
  return result
}

function signature(monitors) {
  var items = normalizeMonitors(monitors)
  var parts = []
  for (var i = 0; i < items.length; i++) {
    var monitor = items[i]
    parts.push([monitor.name, monitor.x, monitor.y, monitor.width, monitor.height].join(":"))
  }
  return parts.join("|")
}

function emptyState() {
  return {
    version: 1,
    source: "",
    createdAt: "",
    scaleMode: "fill",
    bounds: { x: 0, y: 0, width: 0, height: 0 },
    monitors: []
  }
}

function parseState(raw) {
  var encoded = String(raw || "")
  if (encoded.length === 0 || encoded.length > 65536)
    return { state: emptyState(), error: "Saved span wallpaper state exceeds its size limit" }
  var state
  try {
    state = JSON.parse(encoded)
  } catch (error) {
    return { state: emptyState(), error: "Could not parse saved span wallpaper state" }
  }

  if (!state || typeof state !== "object" || state.version !== 1
      || !Array.isArray(state.monitors) || state.monitors.length > 32)
    return { state: emptyState(), error: "Saved span wallpaper state is invalid" }

  var source = String(state.source || "")
  var createdAt = String(state.createdAt || "")
  if ((source && !validText(source, 4096)) || createdAt.length > 64)
    return { state: emptyState(), error: "Saved span wallpaper state is invalid" }

  var monitors = []
  var names = ({})
  for (var i = 0; i < state.monitors.length; i++) {
    var item = state.monitors[i] || {}
    var normalized = normalizeMonitors([item])
    var file = String(item.file || "")
    if (normalized.length !== 1 || !validText(file, 4096) || names[normalized[0].name] === true)
      return { state: emptyState(), error: "Saved span wallpaper state is invalid" }
    names[normalized[0].name] = true
    normalized[0].file = file
    monitors.push(normalized[0])
  }

  var bounds = unionBounds(monitors)
  if (bounds.width > 32768 || bounds.height > 32768
      || bounds.width * bounds.height > 40000000)
    return { state: emptyState(), error: "Saved span wallpaper state is invalid" }

  return {
    state: {
      version: 1,
      source: source,
      createdAt: createdAt,
      scaleMode: ["fill", "fit", "stretch"].indexOf(String(state.scaleMode || "")) >= 0
        ? String(state.scaleMode) : "fill",
      bounds: bounds,
      monitors: monitors
    },
    error: ""
  }
}

function cropPathFor(state, screenName) {
  var monitors = state && Array.isArray(state.monitors) ? state.monitors : []
  var wanted = String(screenName || "")
  for (var i = 0; i < monitors.length; i++) {
    if (String(monitors[i].name || "") === wanted)
      return String(monitors[i].file || "")
  }
  return ""
}
