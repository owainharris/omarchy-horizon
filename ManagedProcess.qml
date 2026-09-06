import QtQuick
import Quickshell.Io

Process {
  id: root

  required property string supervisorPath
  property var safeEnvironment: ({})
  property int timeoutMs: 10000
  property int stdoutLimit: 4096
  property int stderrLimit: 4096
  property string stdoutText: ""
  property string stderrText: ""
  property bool timedOut: false
  property bool stopping: false

  clearEnvironment: true
  environment: safeEnvironment

  function boundedAppend(current, line, limit) {
    var combined = current + String(line || "") + "\n"
    return combined.length > limit ? combined.substring(0, limit) : combined
  }

  function begin(childCommand) {
    if (running) return false
    stdoutText = ""
    stderrText = ""
    timedOut = false
    stopping = false
    command = [
      "/usr/bin/python3", supervisorPath,
      "--timeout-ms", String(timeoutMs),
      "--stdout-limit", String(stdoutLimit),
      "--stderr-limit", String(stderrLimit),
      "--"
    ].concat(childCommand)
    running = true
    deadlineTimer.restart()
    return true
  }

  function cancel() {
    deadlineTimer.stop()
    if (!running) return
    stopping = true
    signal(15)
    killTimer.restart()
  }

  stdout: SplitParser {
    onRead: function(line) {
      root.stdoutText = root.boundedAppend(root.stdoutText, line, root.stdoutLimit)
    }
  }
  stderr: SplitParser {
    onRead: function(line) {
      root.stderrText = root.boundedAppend(root.stderrText, line, root.stderrLimit)
    }
  }

  onExited: {
    deadlineTimer.stop()
    killTimer.stop()
    stopping = false
  }

  property Timer deadlineTimer: Timer {
    interval: root.timeoutMs + 2500
    repeat: false
    onTriggered: {
      root.timedOut = true
      root.cancel()
    }
  }

  property Timer killTimer: Timer {
    interval: 2500
    repeat: false
    onTriggered: {
      if (root.running) root.signal(9)
    }
  }

  Component.onDestruction: {
    if (root.running) root.signal(15)
  }
}
