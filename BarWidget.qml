pragma ComponentBehavior: Bound

import QtQuick
import qs.Commons
import qs.Ui as Ui
import "."

Ui.BarWidget {
  id: root

  moduleName: "kudos.span-wallpaper"

  readonly property var host: root.bar ? root.bar.shell : null
  readonly property bool opened: host !== null && host.openPanelIds !== undefined
    && host.openPanelIds[root.moduleName] === true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function toggle() {
    if (host && typeof host.toggle === "function")
      host.toggle(root.moduleName, "{}")
    else if (root.bar)
      root.bar.run("omarchy-shell shell toggle kudos.span-wallpaper")
  }

  function open() {
    if (host && typeof host.summon === "function") host.summon(root.moduleName, "{}")
  }

  function close() {
    if (host && typeof host.hide === "function") host.hide(root.moduleName)
  }

  Ui.BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // Font Awesome's image glyph, rendered with the bar's themed icon font.
    text: "\uf03e"
    active: root.opened
    tooltipText: "Horizon"
    onPressed: function(button) { root.toggle() }
  }
}
