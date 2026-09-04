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
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateRoot: home + "/.local/state/omarchy/span-wallpaper"
  readonly property string statePath: stateRoot + "/state.json"
  readonly property string pluginDir: manifest && manifest.__sourceDir
    ? String(manifest.__sourceDir).replace(/\/$/, "") : ""

  property bool opened: false
  property bool initialized: false
  property bool pickingThemeImage: false
  property bool pickingFile: false
  property bool pickerWasCancelled: false
  property bool filePickerWasCancelled: false
  property bool sourceDirty: false
  property string sourcePath: ""
  property string scaleMode: "fill"
  property string statusText: ""
  property string errorText: ""
  property string pickerResult: ""
  property string filePickerResult: ""
  property var screenData: []
  property string screenSignature: ""
  property var selectedNames: ({})
  property int selectionRevision: 0
  property var stateData: SpanModel.emptyState()
  property int stateRevision: 0
  property var pendingCropJob: null

  readonly property int selectedCount: countSelected(selectionRevision)
  readonly property bool busy: cropProcess.running || clearProcess.running
  readonly property bool hasActiveSpan: stateData.source !== "" && stateData.monitors.length > 0

  function pluginPath(name) {
    return pluginDir ? pluginDir + "/" + name : ""
  }

  function initialize() {
    if (initialized || !pluginDir) return
    Qt.callLater(function() {
      if (root.initialized || !root.pluginDir) return
      root.initialized = true
      initProcess.command = [root.pluginPath("state.sh"), "init", root.stateRoot]
      initProcess.running = true
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
    cropProcess.stderrText = ""
    cropProcess.command = [pluginPath("crop.sh"), job.source, JSON.stringify(job.geometry), stateRoot, job.scaleMode]
    cropProcess.running = true
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
    if (clearProcess.running) return
    stateData = SpanModel.emptyState()
    stateRevision += 1
    sourceDirty = false
    statusText = "Clearing span…"
    errorText = ""
    clearProcess.dismissAfter = dismissAfter === true
    clearProcess.command = [pluginPath("state.sh"), "clear", stateRoot]
    clearProcess.running = true
  }

  function chooseThemeImage() {
    if (themePickerProcess.running) return
    pickerResult = ""
    pickerWasCancelled = false
    pickingThemeImage = true
    opened = false
    themePickerProcess.command = [pluginPath("pick-image.sh"), stateRoot, sourcePath]
    themePickerProcess.running = true
  }

  function chooseFile() {
    if (filePickerProcess.running) return
    filePickerResult = ""
    filePickerWasCancelled = false
    pickingFile = true
    errorText = ""
    statusText = "Choose an image in the file dialog…"
    filePickerProcess.command = [pluginPath("pick-file.py"), sourcePath]
    filePickerProcess.running = true
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") || ({}) } catch (error) {}
    refreshScreens(false)
    if (payload.source) setSource(String(payload.source))
    else {
      sourceDirty = false
      sourcePath = stateData.source || sourcePath
    }

    if (hasActiveSpan) selectStateScreens()
    else selectAllScreens()
    statusText = hasActiveSpan ? "Span wallpaper is active" : "Select monitors and an image"
    errorText = ""
    opened = true
    Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
  }

  function close() {
    opened = false
    if (themePickerProcess.running) {
      pickerWasCancelled = true
      pickingThemeImage = false
      if (shell && typeof shell.hide === "function") shell.hide("omarchy.image-picker")
      themePickerProcess.running = false
    }
    if (filePickerProcess.running) {
      filePickerWasCancelled = true
      pickingFile = false
      filePickerProcess.running = false
    }
  }

  function dismiss() {
    opened = false
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "kudos.span-wallpaper")
  }

  Process {
    id: initProcess
    onExited: stateFile.reload()
  }

  Process {
    id: cropProcess
    property bool interactive: false
    property string stderrText: ""

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: cropProcess.stderrText = String(text || "").trim()
    }

    onExited: function(exitCode) {
      var wasInteractive = interactive
      Qt.callLater(function() {
        if (exitCode === 0) {
          root.sourceDirty = false
          root.statusText = "Span wallpaper applied"
          stateFile.reload()
          if (wasInteractive) root.dismiss()
        } else {
          root.errorText = cropProcess.stderrText || "Could not create the monitor crops"
          root.statusText = ""
          if (wasInteractive) root.opened = true
        }

        var next = root.pendingCropJob
        root.pendingCropJob = null
        if (next) root.queueCrop(next.source, next.geometry, next.interactive, next.scaleMode)
      })
    }
  }

  Process {
    id: clearProcess
    property bool dismissAfter: false
    property string stderrText: ""
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: clearProcess.stderrText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.statusText = "Span wallpaper cleared"
        stateFile.reload()
        if (dismissAfter) root.dismiss()
      } else {
        root.errorText = stderrText || "Could not clear the span wallpaper"
      }
    }
  }

  Process {
    id: themePickerProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.pickerResult = String(text || "").trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var message = String(text || "").trim()
        if (message) root.errorText = message
      }
    }
    onExited: function(exitCode) {
      root.pickingThemeImage = false
      if (root.pickerWasCancelled) return
      if (exitCode === 0 && root.pickerResult) root.setSource(root.pickerResult)
      root.opened = true
      Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
    }
  }

  Process {
    id: filePickerProcess
    property string stderrText: ""

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.filePickerResult = String(text || "").trim()
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: filePickerProcess.stderrText = String(text || "").trim()
    }
    onExited: function(exitCode) {
      root.pickingFile = false
      if (root.filePickerWasCancelled) return
      if (exitCode === 0 && root.filePickerResult) {
        root.setSource(root.filePickerResult)
      } else if (exitCode !== 0) {
        root.errorText = filePickerProcess.stderrText || "Could not open the image chooser"
        root.statusText = ""
      } else {
        root.statusText = root.sourcePath ? "Selection unchanged" : "No image selected"
      }
      root.opened = true
      Qt.callLater(function() { if (root.opened) keyCatcher.forceActiveFocus() })
    }
  }

  FileView {
    id: stateFile
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadState(text())
    onFileChanged: reload()
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
      stateFile.reload()
    }
  }

  onPluginDirChanged: initialize()

  Component.onCompleted: {
    refreshScreens(false)
    initialize()
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
              text: "Span wallpaper"
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.title
              font.weight: Font.DemiBold
            }
            Text {
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
                  color: monitorRectangle.selected ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Math.min(Style.font.heading, Math.max(Style.font.caption, monitorRectangle.height / 7))
                  font.weight: Font.DemiBold
                  elide: Text.ElideRight
                }
                Text {
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
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideMiddle
            }
            Text {
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
              text: "Scaling"
              color: Color.menu.text
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              font.weight: Font.DemiBold
            }
            Text {
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
