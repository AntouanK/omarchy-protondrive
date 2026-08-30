import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "antouank.protondrive"
  ipcTarget: "antouank.protondrive"
  manageIpc: false

  // Two cursor targets now: the sign-in/sign-out row ("account"), and the
  // file browser list ("files"). There's still no connect/disconnect switch
  // like Tailscale/ProtonVPN: Proton Drive's CLI is command-driven file
  // access, not a background daemon with an on/off state.
  property bool cursorActive: false
  property string focusSection: "account"
  property int fileIndex: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // The glyph itself carries the signed-out state now (Icon.qml fades its
  // body to a single alpha-derived dim tone), so these stay on the plain
  // foreground. The old Qt.darker() dimming was actively wrong on light
  // themes, where darkening a dark foreground *raises* contrast rather than
  // lowering it; alpha dims correctly whichever way the theme runs.
  readonly property color iconColor: foreground
  readonly property color barIconColor: barForeground
  readonly property string authLabel: drive.authenticated ? "Sign out of Proton Drive" : "Sign in to Proton Drive"
  readonly property string authDetail: drive.authenticated ? "Signed in on this device" : "Opens a browser to sign in"
  readonly property string breadcrumbText: Model.breadcrumb(drive.currentPath)
  // Exposed as a real property (rather than referencing the `drive` id
  // directly) because the inline `component FileRow: ...` below can only
  // see properties/functions actually defined on `root` — QML inline
  // components can't resolve sibling ids from the enclosing document.
  readonly property bool driveBusy: drive.busy

  function activateAuth() {
    if (drive.authenticated) drive.logout()
    else drive.login()
  }

  // Synthetic ".." entry prepended whenever we're not at the top, so "go
  // back up" is just another navigable row — no extra keybinding to learn.
  function navItems() {
    var items = []
    if (drive.currentPath !== "/") items.push({ kind: "up", name: "Up one level" })
    return items.concat(drive.entries)
  }

  function ensureCursor() {
    if (!drive.authenticated) {
      focusSection = "account"
      fileIndex = 0
      return
    }
    if (focusSection === "files") {
      var items = navItems()
      if (items.length === 0) { focusSection = "account"; fileIndex = 0; return }
      if (fileIndex >= items.length) fileIndex = Math.max(0, items.length - 1)
      if (fileIndex < 0) fileIndex = 0
    }
  }

  function activateItem(item) {
    if (!item) return
    if (item.kind === "up") drive.goUp()
    else if (item.kind === "folder") drive.browse(item.path)
    else if (item.kind === "file") drive.download(item)
    // "locked" (undecryptable name) entries are inert.
  }

  // Explicit per-row "open" icon: for a folder, opens that location in the
  // Proton Drive WEB APP in the browser (there is no local sync, so "the
  // browser" is the natural default way to open a remote-only folder — this
  // is deliberately different from row-click, which still just navigates
  // the panel's own list, see activateItem above); for a file, downloads a
  // fresh copy and launches it in its default app — additive to
  // activateItem's silent background download, not a replacement for it.
  function activateOpenIcon(item) {
    if (!item) return
    if (item.kind === "folder") drive.openInBrowser(item.path)
    else if (item.kind === "file") drive.openFile(item)
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (focusSection === "account") { activateAuth(); return }
    if (focusSection === "files") {
      var items = navItems()
      if (items.length === 0) return
      activateItem(items[Math.max(0, Math.min(fileIndex, items.length - 1))])
    }
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    // Ranger-style h/l shortcuts: left = up a folder, right = open the
    // selected folder — same destinations as the ".." row and Enter, just
    // reachable without moving the cursor there first.
    if (dx !== 0) {
      if (focusSection !== "files") return
      if (dx < 0) { drive.goUp(); return }
      var items = navItems()
      if (items.length > 0) activateItem(items[Math.max(0, Math.min(fileIndex, items.length - 1))])
      return
    }
    if (dy === 0) return
    if (focusSection === "account") {
      if (dy > 0 && navItems().length > 0) {
        focusSection = "files"
        fileIndex = 0
        scrollCursorIntoView()
      }
      return
    }
    if (focusSection === "files") {
      var count = navItems().length
      if (dy < 0 && fileIndex === 0) {
        setAccountCursor()
        return
      }
      fileIndex = Math.max(0, Math.min(count - 1, fileIndex + dy))
      scrollCursorIntoView()
    }
  }

  function setAccountCursor() {
    cursorActive = true
    focusSection = "account"
    if (panelFlick) panelFlick.contentY = 0
  }

  function setFileCursor(index) {
    cursorActive = true
    focusSection = "files"
    fileIndex = index
    scrollCursorIntoView()
  }

  function scrollItemIntoView(item) {
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var viewTop = panelFlick.contentY
      var viewBottom = viewTop + panelFlick.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < viewTop + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > viewBottom - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function scrollCursorIntoView() {
    if (focusSection === "files" && fileColumn && fileIndex >= 0 && fileIndex < fileColumn.children.length) {
      scrollItemIntoView(fileColumn.children[fileIndex])
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "account"
    fileIndex = 0
    if (panelFlick) panelFlick.contentY = 0
    drive.refresh()
    if (drive.installed) drive.browse("/")
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  onFileIndexChanged: scrollCursorIntoView()

  Service {
    id: drive
    settings: root.settings
  }

  Connections {
    target: drive
    function onAuthenticatedChanged() {
      if (drive.authenticated) drive.browse("/")
      root.ensureCursor()
    }
    function onEntriesChanged() { root.ensureCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { drive.refresh(); return "ok" }
    function login(): string { drive.login(); return "ok" }
    function logout(): string { drive.logout(); return "ok" }
    function status(): string { return drive.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        Icon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          loggedOut: !drive.authenticated
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) drive.refresh()
      else if (buttonCode === Qt.MiddleButton) root.activateAuth()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(12)

        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight

          PanelHero {
            id: hero
            width: parent.width
            title: "Proton Drive"
            meta: drive.statusText
            foreground: root.foreground
            fontFamily: root.fontFamily
            // Icon.qml already fades itself when signed out; stacking
            // PanelHero's own 0.5 on top of that would push the hero glyph
            // down to ~0.19 alpha and make it near-invisible.
            iconOpacity: 1.0
            iconComponent: Component {
              Icon {
                iconSize: Style.font.display
                color: root.iconColor
                loggedOut: !drive.authenticated
              }
            }
          }
        }

        Text {
          visible: drive.actionStatus !== "" || drive.lastError !== ""
          width: parent.width
          text: drive.actionStatus !== "" ? drive.actionStatus : drive.lastError
          color: drive.lastError !== "" && drive.actionStatus === "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        CursorSurface {
          visible: !drive.installed
          width: parent.width
          implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
          foreground: root.foreground

          Text {
            id: missingText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            text: "Proton Drive CLI is not installed or not on PATH."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
        }

        PanelSeparator {
          visible: drive.installed
          foreground: root.foreground
        }

        Column {
          visible: drive.installed
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "ACCOUNT"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          CursorSurface {
            id: authRow
            width: parent.width
            hasCursor: root.cursorActive && root.focusSection === "account"
            foreground: root.foreground
            implicitHeight: authInner.implicitHeight + Style.spacing.rowPaddingX

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: drive.busy ? Qt.ArrowCursor : Qt.PointingHandCursor
              enabled: !drive.busy
              onEntered: root.setAccountCursor()
              onClicked: root.activateAuth()
            }

            RowLayout {
              id: authInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: drive.authenticated ? "󰍃" : "󰍂"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.heading
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  text: root.authLabel
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: root.authDetail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        PanelSeparator {
          visible: drive.authenticated
          foreground: root.foreground
        }

        Column {
          visible: drive.authenticated
          width: parent.width
          spacing: Style.space(10)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "FILES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              Layout.fillWidth: true
              text: root.breadcrumbText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideMiddle
              horizontalAlignment: Text.AlignRight
            }

            PanelActionButton {
              iconText: "↑"
              tooltipText: drive.canUpload ? "Upload a file here" : "Open a folder inside My files to upload"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: drive.canUpload && !drive.busy
              onClicked: drive.pickAndUpload()
            }
          }

          Text {
            visible: drive.browsing
            width: parent.width
            text: "Loading…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Text {
            visible: !drive.browsing && drive.browseError !== ""
            width: parent.width
            text: drive.browseError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: !drive.browsing && drive.browseError === "" && root.navItems().length === 0
            width: parent.width
            text: "This folder is empty."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            id: fileColumn
            visible: !drive.browsing && root.navItems().length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.navItems()
              FileRow {
                required property var modelData
                required property int index
                width: fileColumn.width
                entry: modelData
                rowIndex: index
              }
            }
          }
        }
      }
      }
    }
  }

  component FileRow: CursorSurface {
    id: fileRow
    property var entry: null
    property int rowIndex: 0
    readonly property string kind: entry ? String(entry.kind || "file") : "file"
    readonly property string entryName: entry ? String(entry.name || "Untitled") : "Untitled"
    readonly property bool interactive: kind === "up" || kind === "folder" || kind === "file"

    hasCursor: root.cursorActive && root.focusSection === "files" && root.fileIndex === rowIndex
    foreground: root.foreground

    implicitHeight: fileContent.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: fileRow.interactive ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: fileRow.interactive
      onEntered: root.setFileCursor(fileRow.rowIndex)
      onClicked: root.activateItem(fileRow.entry)
    }

    RowLayout {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Text {
        text: fileRow.kind === "up" ? "‹" : (fileRow.kind === "folder" ? "󰉋" : (fileRow.kind === "locked" ? "󰌾" : Model.fileGlyph(fileRow.entryName)))
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        id: fileContent
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          text: fileRow.entryName
          color: fileRow.kind === "locked" ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          Layout.fillWidth: true
          visible: text !== ""
          text: fileRow.kind === "up" ? "" : Model.entryMeta(fileRow.entry)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        visible: fileRow.kind === "folder" || fileRow.kind === "file"
        iconText: fileRow.kind === "folder" ? "→" : "↗"
        tooltipText: fileRow.kind === "folder" ? "Open folder" : "Open file"
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !root.driveBusy
        onClicked: root.activateOpenIcon(fileRow.entry)
      }
    }
  }
}
