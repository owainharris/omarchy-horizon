pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "SpanModel.js" as SpanModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateRoot: home + "/.local/state/omarchy/span-wallpaper"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir).replace(/\/$/, "") : ""
  readonly property var helperEnvironment: ({
    "HOME": home,
    "PATH": "/usr/bin",
    "LANG": Quickshell.env("LANG") || "C.UTF-8",
    "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR"),
    "WAYLAND_DISPLAY": Quickshell.env("WAYLAND_DISPLAY"),
    "DISPLAY": Quickshell.env("DISPLAY"),
    "DBUS_SESSION_BUS_ADDRESS": Quickshell.env("DBUS_SESSION_BUS_ADDRESS"),
    "XDG_CURRENT_DESKTOP": Quickshell.env("XDG_CURRENT_DESKTOP"),
    "XDG_DATA_DIRS": "/usr/local/share:/usr/share",
    "GDK_BACKEND": "wayland,x11"
  })

  property bool opened: false
  property bool initialized: false
  property bool pickingFile: false
  property bool filePickerWasCancelled: false
  property bool sourceDirty: false
  property string sourcePath: ""
  property string scaleMode: "fill"
  property string statusText: ""
  property string errorText: ""
  property string filePickerResult: ""
  property var screenData: []
  property string screenSignature: ""
  property var selectedNames: ({})
  property int selectionRevision: 0
  property var stateData: SpanModel.emptyState()
  property int stateRevision: 0
  property var pendingCropJob: null
  property bool clearRequested: false
  property bool dismissAfterClear: false

  readonly property int selectedCount: countSelected(selectionRevision)
  readonly property bool busy: cropProcess.running || clearProcess.running || clearRequested || importProcess.running
  readonly property bool hasActiveSpan: stateData.source !== "" && stateData.monitors.length > 0

  function pluginPath(name) {
    return pluginDir ? pluginDir + "/" + name : ""
  }

  function helperCommand(action, arguments) {
    return ["/usr/bin/python3", "-I", pluginPath("helper.py"), action].concat(arguments || [])
  }

  function processError(process, fallback) {
    var message = String(process.stderrText || "").trim()
    if (message.length > 512) message = message.substring(0, 512)
    return message || fallback
  }

  function parseResponse(raw) {
    var text = String(raw || "").trim()
    if (!text || text.length > 65536) return null
    try { return JSON.parse(text) } catch (error) { return null }
  }

  function readState(dismissAfter) {
    stateReadProcess.dismissAfterRead = dismissAfter === true
    if (!stateReadProcess.running)
      stateReadProcess.begin(helperCommand("read"))
  }

  function initialize() {
    if (initialized || !pluginDir) return
    Qt.callLater(function() {
      if (root.initialized || !root.pluginDir) return
      root.initialized = true
      initProcess.begin(root.helperCommand("init"))
    })
  }

  function snapshotScreens() {
    var screens = Quickshell.screens || []
    var snapshot = []
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (!screen) continue
      snapshot.push({
        name: String(screen.name || ""),
        x: Number(screen.x || 0),
        y: Number(screen.y || 0),
        width: Number(screen.width || 0),
        height: Number(screen.height || 0)
      })
    }
    return SpanModel.normalizeMonitors(snapshot)
  }

  function refreshScreens(allowRelayout) {
    var next = snapshotScreens()
    var nextSignature = SpanModel.signature(next)
    if (nextSignature === screenSignature) return

    screenData = next
    screenSignature = nextSignature
    selectionRevision += 1

    if (allowRelayout === true && next.length > 0)
      maybeRelayout()
  }

  function selectedGeometry() {
    return SpanModel.selectByNames(screenData, selectedNames)
  }

  function countSelected(revision) {
    revision = revision
    return selectedGeometry().length
  }

  function isSelected(name, revision) {
    revision = revision
    return selectedNames[String(name)] === true
  }

  function toggleScreen(name) {
    var next = ({})
    for (var key in selectedNames) next[key] = selectedNames[key]
    var screenName = String(name)
    if (next[screenName] === true) delete next[screenName]
    else next[screenName] = true
    selectedNames = next
    selectionRevision += 1
  }

  function selectAllScreens() {
    var next = ({})
    for (var i = 0; i < screenData.length; i++) next[screenData[i].name] = true
    selectedNames = next
    selectionRevision += 1
  }

  function selectStateScreens() {
    var next = ({})
    for (var i = 0; i < stateData.monitors.length; i++)
      next[String(stateData.monitors[i].name)] = true
    selectedNames = next
    selectionRevision += 1
  }

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }

  function shortPath(path) {
    var value = String(path || "")
    if (!value) return "No image selected"
    var parts = value.split("/")
    return parts[parts.length - 1] || value
  }

  function setSource(path) {
    var value = String(path || "").trim()
    if (!value) return
    sourcePath = value
    sourceDirty = true
    statusText = "Ready to apply"
    errorText = ""
  }

  function importSource(path) {
    var value = String(path || "")
    if (!value || value.length > 4096 || importProcess.running) {
      if (value.length > 4096) errorText = "The selected image path is too long"
      return
    }
    importProcess.begin(helperCommand("import", [value]))
    statusText = "Checking image…"
    errorText = ""
  }

  function setScaleMode(mode) {
    var value = String(mode || "")
    if (["fill", "fit", "stretch"].indexOf(value) < 0 || value === scaleMode) return
    scaleMode = value
    sourceDirty = true
    errorText = ""

    var geometry = selectedGeometry()
    if (hasActiveSpan && sourcePath && geometry.length > 0) {
      queueCrop(sourcePath, geometry, false, value)
      statusText = "Previewing " + scaleModeLabel(value) + "…"
    } else {
      statusText = "Ready to apply"
    }
  }

  function scaleModeLabel(mode) {
    if (mode === "fit") return "Show whole"
    if (mode === "stretch") return "Stretch"
    return "Fill"
  }

  function scaleModeDescription(mode) {
    if (mode === "fit") return "Shows every part of the image; unused space becomes black bars"
    if (mode === "stretch") return "Uses the whole image with no bars; proportions may distort"
    return "Preserves proportions and fills every pixel; overflow is cropped"
  }

  function loadState(raw) {
    var parsed = SpanModel.parseState(raw)
    stateData = parsed.state
    stateRevision += 1
    if (parsed.error) errorText = parsed.error
    if (!sourceDirty && stateData.source) sourcePath = stateData.source
    if (!sourceDirty) scaleMode = stateData.scaleMode || "fill"
    if (opened && stateData.source && stateData.monitors.length > 0) selectStateScreens()
    Qt.callLater(function() { root.maybeRelayout() })
  }

  function cropPathForScreen(name, revision) {
    revision = revision
    return SpanModel.cropPathFor(stateData, name)
  }

  function maybeRelayout() {
    if (clearRequested || clearProcess.running) return
    if (!stateData.source || stateData.monitors.length === 0 || screenData.length === 0) return

    var wanted = ({})
    for (var i = 0; i < stateData.monitors.length; i++)
      wanted[String(stateData.monitors[i].name)] = true
    var current = SpanModel.selectByNames(screenData, wanted)

    if (current.length === 0) {
      clearSpan(false)
      return
    }
    if (SpanModel.signature(current) !== SpanModel.signature(stateData.monitors))
      queueCrop(stateData.source, current, false, stateData.scaleMode)
  }

  function queueCrop(source, geometry, interactive, requestedScaleMode) {
    if (clearRequested || clearProcess.running) return
    var mode = String(requestedScaleMode || scaleMode)
    if (["fill", "fit", "stretch"].indexOf(mode) < 0) mode = "fill"
    var job = {
      source: String(source || ""),
      geometry: SpanModel.normalizeMonitors(geometry),
      interactive: interactive === true,
      scaleMode: mode
    }
    if (!job.source || job.geometry.length === 0) return
    if (cropProcess.running) {
      pendingCropJob = job
      return
    }

    errorText = ""
    statusText = job.interactive ? "Preparing wallpaper…" : "Updating for display layout…"
    cropProcess.interactive = job.interactive
    cropProcess.begin(helperCommand("crop", [job.source, JSON.stringify(job.geometry), job.scaleMode]))
  }

  function applySpan() {
    var geometry = selectedGeometry()
    if (!sourcePath) {
      errorText = "Choose an image first"
      return
    }
    if (geometry.length === 0) {
      errorText = "Select at least one monitor"
      return
    }
    queueCrop(sourcePath, geometry, true, scaleMode)
  }

  function clearSpan(dismissAfter) {
    if (clearRequested || clearProcess.running) return
    clearRequested = true
    dismissAfterClear = dismissAfter === true
    pendingCropJob = null
    statusText = "Clearing span…"
    errorText = ""
    if (stateReadProcess.running) stateReadProcess.cancel()
    if (cropProcess.running) cropProcess.cancel()
    finishClear()
  }

  function finishClear() {
    if (!clearRequested || cropProcess.running || stateReadProcess.running || clearProcess.running) return
    clearProcess.dismissAfter = dismissAfterClear
    clearProcess.begin(helperCommand("clear"))
  }

  function chooseThemeImage() {
    chooseImage(true)
  }

  function chooseFile() {
    chooseImage(false)
  }

  function chooseImage(themeOnly) {
    if (filePickerProcess.running) return
    filePickerResult = ""
    filePickerWasCancelled = false
    pickingFile = true
    errorText = ""
    statusText = "Choose an image in the file dialog…"
    filePickerProcess.begin(helperCommand("pick", [sourcePath, themeOnly ? "theme" : "any"]))
  }

  function open(payloadJson) {
    var payload = ({})
    var encodedPayload = String(payloadJson || "{}")
    if (encodedPayload.length <= 8192) {
      try { payload = JSON.parse(encodedPayload) || ({}) } catch (error) {}
    }
    refreshScreens(false)
    if (payload.source) importSource(String(payload.source))
    else {
      sourceDirty = false
      sourcePath = stateData.source || sourcePath
    }

    if (hasActiveSpan) selectStateScreens()
    else selectAllScreens()
    statusText = hasActiveSpan ? "Span is active" : "Select monitors and an image"
    errorText = ""
    opened = true
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    opened = false
    if (filePickerProcess.running) {
      filePickerWasCancelled = true
      pickingFile = false
      filePickerProcess.cancel()
    }
    if (importProcess.running) importProcess.cancel()
  }

  function dismiss() {
    close()
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "kudos.span-wallpaper")
  }

  ManagedProcess {
    id: initProcess
    supervisorPath: root.pluginPath("supervisor.py")
    safeEnvironment: root.helperEnvironment
    timeoutMs: 5000
    stdoutLimit: 0
    onExited: function(exitCode) {
      if (exitCode === 0) root.readState(false)
      else root.errorText = root.processError(initProcess, "Could not initialize wallpaper state")
    }
  }

  ManagedProcess {
    id: cropProcess
    property bool interactive: false
    supervisorPath: root.pluginPath("supervisor.py")
    safeEnvironment: root.helperEnvironment
    timeoutMs: 150000
    stdoutLimit: 0

    onExited: function(exitCode) {
      var wasInteractive = interactive
      Qt.callLater(function() {
        if (root.clearRequested) {
          root.finishClear()
          return
        }
        if (exitCode === 0) {
          root.sourceDirty = false
          root.statusText = "Span applied"
          root.readState(wasInteractive)
        } else {
          root.errorText = root.processError(cropProcess, "Could not create the monitor crops")
          root.statusText = ""
          if (wasInteractive) root.opened = true
        }

        var next = root.pendingCropJob
        root.pendingCropJob = null
        if (next) root.queueCrop(next.source, next.geometry, next.interactive, next.scaleMode)
      })
    }
  }

  ManagedProcess {
    id: clearProcess
    property bool dismissAfter: false
    supervisorPath: root.pluginPath("supervisor.py")
    safeEnvironment: root.helperEnvironment
    timeoutMs: 5000
    stdoutLimit: 0
    onExited: function(exitCode) {
      root.clearRequested = false
      if (exitCode === 0) {
        root.stateData = SpanModel.emptyState()
        root.stateRevision += 1
        root.sourceDirty = false
        root.statusText = "Span cleared"
        if (dismissAfter) root.dismiss()
      } else {
        root.errorText = root.processError(clearProcess, "Could not clear the span")
      }
    }
  }

  ManagedProcess {
    id: filePickerProcess
    supervisorPath: root.pluginPath("supervisor.py")
    safeEnvironment: root.helperEnvironment
    timeoutMs: 120000
    stdoutLimit: 8192
    onExited: function(exitCode) {
      root.pickingFile = false
      if (root.filePickerWasCancelled) return
      var response = root.parseResponse(stdoutText)
      if (exitCode === 0 && response && response.path) {
        root.importSource(String(response.path))
      } else if (exitCode !== 0) {
        root.errorText = root.processError(filePickerProcess, "Could not open the image chooser")
        root.statusText = ""
      } else {
        root.statusText = root.sourcePath ? "Selection unchanged" : "No image selected"
      }
      root.opened = true
      Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
    }
  }

  ManagedProcess {
    id: importProcess
    supervisorPath: root.pluginPath("supervisor.py")
    safeEnvironment: root.helperEnvironment
    timeoutMs: 30000
    stdoutLimit: 8192
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var response = root.parseResponse(stdoutText)
        if (response && response.path) root.setSource(String(response.path))
        else root.errorText = "Image validation returned an invalid response"
      } else {
        root.errorText = root.processError(importProcess, "Could not validate the selected image")
        root.statusText = ""
      }
    }
  }

  ManagedProcess {
    id: stateReadProcess
    property bool dismissAfterRead: false
    supervisorPath: root.pluginPath("supervisor.py")
    safeEnvironment: root.helperEnvironment
    timeoutMs: 5000
    stdoutLimit: 65536
    onExited: function(exitCode) {
      if (root.clearRequested) {
        dismissAfterRead = false
        Qt.callLater(function() { root.finishClear() })
        return
      }
      if (exitCode === 0) {
        root.loadState(stdoutText)
        if (dismissAfterRead) root.dismiss()
      } else {
        root.errorText = root.processError(stateReadProcess, "Could not read wallpaper state")
      }
      dismissAfterRead = false
    }
  }

  Timer {
    interval: 1500
    repeat: true
    running: true
    onTriggered: root.refreshScreens(true)
  }

  IpcHandler {
    target: "kudos.span-wallpaper"

    function clear(): void {
      root.clearSpan(false)
    }

    function refresh(): void {
      root.refreshScreens(true)
      root.readState(false)
    }
  }

  onPluginDirChanged: initialize()

  Component.onCompleted: {
    refreshScreens(false)
    initialize()
  }

  Component.onDestruction: {
    initProcess.cancel()
    cropProcess.cancel()
    clearProcess.cancel()
    filePickerProcess.cancel()
    importProcess.cancel()
    stateReadProcess.cancel()
  }

  // Cropped images are placed on the Bottom layer: above Omarchy's stock
  // Background layer, but below normal windows, the bar, and overlays.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: wallpaperWindow
      required property var modelData

      readonly property string cropPath: root.cropPathForScreen(modelData.name, root.stateRevision)

      screen: modelData
      visible: cropPath !== "" && !remapGuard.remapping
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      updatesEnabled: true

      ScreenMoveRemap {
        id: remapGuard
        window: wallpaperWindow
      }

      WlrLayershell.namespace: "kudos-span-wallpaper"
      WlrLayershell.layer: WlrLayer.Bottom
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Image {
        anchors.fill: parent
        source: Util.fileUrl(wallpaperWindow.cropPath)
        fillMode: Image.Stretch
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
      }
    }
  }

  PanelWindow {
    id: overlayWindow
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "kudos-span-wallpaper-picker"
    // While the out-of-process chooser is active, keep this window mounted but
    // move it below regular windows and release keyboard focus. This preserves
    // the user's monitor selection without covering or blocking the chooser.
    WlrLayershell.layer: root.pickingFile ? WlrLayer.Bottom : WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && !root.pickingFile
      ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.dismiss()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(860), overlayWindow.width - Style.gapsOut * 4)
      height: Math.min(Style.space(650), overlayWindow.height - Style.gapsOut * 4)
      anchors.centerIn: parent
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, Math.max(1, Style.normalBorderWidth))
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      ColumnLayout {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.spacing.md

        RowLayout {
          Layout.fillWidth: true

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xs

            Text {
              textFormat: Text.PlainText
              text: "Horizon"
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
              textFormat: Text.PlainText
              text: "Choose the displays that should share one continuous image"
              color: Util.alpha(Color.menu.text, 0.62)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }
          }

          Button {
            text: "Select all"
            foreground: Color.menu.text
            onClicked: root.selectAllScreens()
          }
        }

        Rectangle {
          id: monitorPreview
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.minimumHeight: Style.space(230)
          color: Util.alpha(Color.menu.text, 0.035)
          radius: Style.cornerRadius
          border.width: Math.max(1, Style.normalBorderWidth)
          border.color: Util.alpha(Color.menu.text, 0.14)

          readonly property var mapLayout: SpanModel.fitLayout(root.screenData, width, height, Style.space(30))

          Text {
            textFormat: Text.PlainText
            anchors.centerIn: parent
            visible: root.screenData.length === 0
            text: "No displays detected"
            color: Util.alpha(Color.menu.text, 0.62)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body
          }

          Repeater {
            model: monitorPreview.mapLayout.rects

            delegate: Rectangle {
              id: monitorRectangle
              required property var modelData
              readonly property bool selected: root.isSelected(modelData.name, root.selectionRevision)

              x: modelData.x
              y: modelData.y
              width: Math.max(2, modelData.width)
              height: Math.max(2, modelData.height)
              radius: Math.min(Style.cornerRadius, Math.min(width, height) / 10)
              color: selected ? Color.menu.selectedBackground : Util.alpha(Color.menu.text, 0.055)
              border.width: selected ? Math.max(2, Style.normalBorderWidth) : Math.max(1, Style.normalBorderWidth)
              border.color: selected ? Color.menu.selectedText : Util.alpha(Color.menu.text, 0.28)

              Column {
                anchors.centerIn: parent
                width: Math.max(0, parent.width - Style.spacing.sm * 2)
                spacing: Style.spacing.xs

                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: monitorRectangle.modelData.name
                  textFormat: Text.PlainText
                  color: monitorRectangle.selected ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Math.min(Style.font.heading, Math.max(Style.font.caption, monitorRectangle.height / 7))
                  font.weight: Font.DemiBold
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  visible: monitorRectangle.height > Style.space(70)
                  text: Math.round(monitorRectangle.modelData.width / monitorPreview.mapLayout.scale)
                    + " × " + Math.round(monitorRectangle.modelData.height / monitorPreview.mapLayout.scale)
                  color: Util.alpha(Color.menu.text, 0.58)
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleScreen(monitorRectangle.modelData.name)
              }
            }
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md

          Rectangle {
            Layout.preferredWidth: Style.space(112)
            Layout.preferredHeight: Style.space(74)
            color: Util.alpha(Color.menu.text, 0.04)
            radius: Style.cornerRadius
            border.width: Math.max(1, Style.normalBorderWidth)
            border.color: Util.alpha(Color.menu.text, 0.14)
            clip: true

            Image {
              anchors.fill: parent
              source: root.sourcePath ? Util.fileUrl(root.sourcePath) : ""
              fillMode: Image.PreserveAspectCrop
              // Decode only enough pixels for this preview. Without a source
              // size, Qt expands large panoramas at full resolution inside the
              // long-running shell process.
              sourceSize.width: Style.space(224)
              sourceSize.height: Style.space(148)
              asynchronous: true
              cache: false
            }

            Text {
              textFormat: Text.PlainText
              anchors.centerIn: parent
              visible: !root.sourcePath
              text: "󰋩"
              color: Util.alpha(Color.menu.text, 0.55)
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.spacing.xs

            Text {
              Layout.fillWidth: true
              text: root.shortPath(root.sourcePath)
              textFormat: Text.PlainText
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideMiddle
            }
            Text {
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: root.selectedCount + (root.selectedCount === 1 ? " display selected" : " displays selected")
              color: Util.alpha(Color.menu.text, 0.58)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
            }
          }

          Button {
            text: "Theme images"
            foreground: Color.menu.text
            enabled: !root.busy
            onClicked: root.chooseThemeImage()
          }
          Button {
            text: "Choose file…"
            foreground: Color.menu.text
            enabled: !root.busy
            onClicked: root.chooseFile()
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              textFormat: Text.PlainText
              text: "Scaling"
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.weight: Font.DemiBold
            }
            Text {
              textFormat: Text.PlainText
              Layout.maximumWidth: Style.space(360)
              text: root.scaleModeDescription(root.scaleMode)
              color: Util.alpha(Color.menu.text, 0.55)
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Button {
            text: "Fill (crop)"
            foreground: Color.menu.text
            active: root.scaleMode === "fill"
            enabled: !root.busy
            onClicked: root.setScaleMode("fill")
          }
          Button {
            text: "Show whole"
            foreground: Color.menu.text
            active: root.scaleMode === "fit"
            enabled: !root.busy
            onClicked: root.setScaleMode("fit")
          }
          Button {
            text: "Stretch"
            foreground: Color.menu.text
            active: root.scaleMode === "stretch"
            enabled: !root.busy
            onClicked: root.setScaleMode("stretch")
          }
        }

        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(statusLabel.implicitHeight, Style.space(24))

          Text {
            id: statusLabel
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.errorText || root.statusText
            textFormat: Text.PlainText
            color: root.errorText ? Color.urgent : Util.alpha(Color.menu.text, 0.62)
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.sm

          Button {
            text: "Clear span"
            foreground: Color.urgent
            enabled: root.hasActiveSpan && !root.busy
            onClicked: root.clearSpan(true)
          }

          Item { Layout.fillWidth: true }

          Button {
            text: "Cancel"
            foreground: Color.menu.text
            enabled: !root.busy
            onClicked: root.dismiss()
          }
          Button {
            text: root.busy ? "Working…" : "Apply"
            foreground: Color.menu.selectedText
            active: true
            enabled: !root.busy && root.sourcePath !== "" && root.selectedCount > 0
            onClicked: root.applySpan()
          }
        }
      }
    }
  }
}
