import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "VaultModel.js" as VaultModel

// BW Vault — a Bitwarden vault overlay for Omarchy, backed by the `bw` CLI.
//
// Summon with:
//   omarchy-shell shell toggle com.aktivesolutions.bw-vault
//
// Screens: unlock (email + password) → searchable item list → item detail
// with copy-username / copy-password / reveal / lock.
//
// Session handling mirrors bw-tui: the session token is read from the OS
// keyring (secret-tool) on open, verified against `bw`, and re-stored after
// unlock so the master password is asked for once per machine. The master
// password only ever travels through the child process environment
// (bw --passwordenv), never argv or a QML property that outlives the flow.

Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  // -- lifecycle -------------------------------------------------------------

  property bool opened: false
  // "unlock" | "list" | "detail"
  property string screen: "unlock"
  // "checking" | "unauthenticated" | "locked" | "unlocked"
  property string status: "checking"

  property string heldSession: ""
  property string email: ""
  property string masterPassword: ""

  property var items: []
  property var filteredItems: []
  property string filterText: ""
  property int selectedIndex: 0

  property var detail: null
  property string detailPassword: ""
  property bool showPass: false

  property bool loading: false
  property string error: ""
  property string flash: ""
  property bool sessionLookupHandled: false

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property color selectedBorder: Color.menu.selectedBorder
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", selectedBorder, 0)
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.menuFamily

  readonly property int contentMargin: Style.spacing.panelPadding
  readonly property int cardWidth: Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  readonly property bool emailNeeded: status === "unauthenticated"

  // -- lifecycle: open / close ----------------------------------------------

  function open(payloadJson) {
    root.opened = true
    root.screen = "unlock"
    root.status = "checking"
    root.error = ""
    root.flash = ""
    root.showPass = false
    root.detailPassword = ""
    root.detail = null
    root.filterText = ""
    root.selectedIndex = 0
    root.loading = true
    root.sessionLookupHandled = false
    emailField.text = ""
    passField.text = ""
    emailField.focus = root.emailNeeded
    passField.focus = !root.emailNeeded

    // Start the keyring lookup, then let its handler run the status chain.
    sessionLookup.running = true

    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.loading = false
    root.masterPassword = ""
    root.detailPassword = ""
    root.showPass = false
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "com.aktivesolutions.bw-vault")
    else close()
  }

  // -- status chain ----------------------------------------------------------

  // After the keyring lookup lands, verify a held session, then fall back to
  // the global bw status when there isn't one worth keeping.
  function onSessionLookup(rawSession) {
    if (root.sessionLookupHandled) return
    root.sessionLookupHandled = true
    var candidate = String(rawSession || "").trim()
    if (candidate) {
      root.heldSession = candidate
      root.status = "checking"
      statusProc.hadSession = true
      statusProc.command = VaultModel.statusCommand(candidate)
      statusProc.running = true
      return
    }
    root.heldSession = ""
    root.fetchGlobalStatus()
  }

  function fetchGlobalStatus() {
    root.status = "checking"
    statusProc.hadSession = false
    statusProc.command = VaultModel.statusCommand("")
    statusProc.running = true
  }

  function onStatusOutput(raw, hadSession) {
    var st = VaultModel.parseStatus(raw)
    if (!st) {
      root.error = "Could not read bw status"
      root.status = "unauthenticated"
      root.loading = false
      return
    }
    if (st.unlocked) {
      // A valid session (ours or bw's global one) — go straight to the list.
      root.status = "unlocked"
      root.loadItems()
      return
    }
    // Held session is dead (or absent) and bw is not globally unlocked.
    if (hadSession) {
      root.heldSession = ""
      root.fetchGlobalStatus()
      return
    }
    root.status = st.authenticated ? "locked" : "unauthenticated"
    root.loading = false
    Qt.callLater(function() {
      if (root.opened) {
        if (root.emailNeeded) emailField.forceActiveFocus()
        else passField.forceActiveFocus()
      }
    })
  }

  // -- unlock ----------------------------------------------------------------

  function startUnlock() {
    if (root.loading) return
    if (root.emailNeeded && !String(root.email).trim()) {
      root.error = "Email required"
      return
    }
    if (!String(root.masterPassword)) {
      root.error = "Master password required"
      return
    }
    root.error = ""
    root.loading = true

    if (root.emailNeeded) {
      // First login on this machine: approve the device in the Bitwarden app,
      // then unlock returns the session key.
      loginProc.command = VaultModel.loginCommand(String(root.email).trim(), root.heldSession)
      loginProc.environment = VaultModel.passwordEnvironment(root.masterPassword)
      loginProc.running = true
    } else {
      root.runUnlock()
    }
  }

  function runUnlock() {
    unlockProc.environment = VaultModel.passwordEnvironment(root.masterPassword)
    unlockProc.command = VaultModel.unlockCommand()
    unlockProc.running = true
  }

  function onUnlockSuccess(rawSession) {
    var session = String(rawSession || "").trim()
    root.masterPassword = ""
    if (!session) {
      root.error = "Unlock did not return a session"
      root.loading = false
      return
    }
    root.heldSession = session
    root.status = "unlocked"
    // Mirror to the OS keyring (non-fatal).
    sessionStore.running = true
    root.loadItems()
  }

  // -- list ------------------------------------------------------------------

  function loadItems() {
    root.screen = "list"
    root.loading = true
    root.error = ""
    listProc.command = VaultModel.listCommand(root.heldSession)
    listProc.running = true
  }

  function onListOutput(raw) {
    root.items = VaultModel.parseList(raw)
    root.rebuildFilter()
    root.loading = false
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function rebuildFilter() {
    var q = String(root.filterText).toLowerCase().trim()
    var out = []
    for (var i = 0; i < root.items.length; i++) {
      if (VaultModel.matchesQuery(root.items[i], q)) out.push(root.items[i])
    }
    root.filteredItems = out
    if (root.selectedIndex >= root.filteredItems.length)
      root.selectedIndex = root.filteredItems.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
  }

  // -- detail ----------------------------------------------------------------

  function openDetail(id) {
    root.screen = "detail"
    root.loading = true
    root.error = ""
    root.detail = null
    root.detailPassword = ""
    root.showPass = false
    getProc.command = VaultModel.getCommand(id, root.heldSession)
    getProc.running = true
  }

  function onDetailOutput(raw) {
    root.detail = VaultModel.parseItem(raw)
    root.loading = false
    if (root.detail) root.detailPassword = root.detail.password
    else root.error = "Could not read item"
  }

  // -- lock ------------------------------------------------------------------

  function lockVault() {
    if (root.heldSession) {
      lockProc.command = VaultModel.lockCommand(root.heldSession)
      lockProc.running = true
    }
    sessionClear.running = true
    root.heldSession = ""
    root.detail = null
    root.detailPassword = ""
    root.items = []
    root.filteredItems = []
    root.status = "locked"
    root.screen = "unlock"
    root.error = ""
    root.loading = false
    root.fetchGlobalStatus()
  }

  // -- copy ------------------------------------------------------------------

  function copyText(text) {
    if (!text) return
    copyProc.payload = text
    copyProc.running = true
  }

  function flashMessage(message) {
    root.flash = message
    flashTimer.restart()
  }

  // -- ui helpers ------------------------------------------------------------

  function clampIndex(i) {
    if (root.filteredItems.length === 0) return 0
    return Math.max(0, Math.min(i, root.filteredItems.length - 1))
  }

  function itemTypeGlyph(type) {
    switch (type) {
    case "login": return "󰍤"
    case "secureNote": return "󰈐"
    case "card": return "󰅝"
    case "identity": return "󰓹"
    default: return "󰈉"
    }
  }

  // -- processes -------------------------------------------------------------

  Process {
    id: sessionLookup
    command: VaultModel.sessionLookupCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSessionLookup(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && root.opened) root.onSessionLookup("")
    }
  }

  Process {
    id: sessionStore
    property string session: root.heldSession
    command: VaultModel.sessionStoreCommand()
    stdinEnabled: true
    onStarted: {
      write(String(root.heldSession || "") + "\n")
    }
  }

  Process {
    id: sessionClear
    command: VaultModel.sessionClearCommand()
  }

  Process {
    id: statusProc
    property bool hadSession: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onStatusOutput(text, statusProc.hadSession)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && root.opened) root.error = String(text).trim()
    }
  }

  Process {
    id: loginProc
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && root.opened) {
        root.error = String(text).trim() || "Login failed"
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.runUnlock()
      } else if (root.loading && root.opened && root.error === "") {
        root.error = "Login failed"
        root.loading = false
      }
    }
  }

  Process {
    id: unlockProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onUnlockSuccess(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && root.opened) {
        root.error = String(text).trim() || "Unlock failed"
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading && root.opened && root.error === "") {
        root.error = "Unlock failed"
        root.loading = false
      }
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onListOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && root.opened) {
        root.error = String(text).trim()
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading && root.opened && root.error === "") {
        root.error = "Could not list items"
        root.loading = false
      }
    }
  }

  Process {
    id: getProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onDetailOutput(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text && root.opened) {
        root.error = String(text).trim()
        root.loading = false
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading && root.opened && root.error === "") {
        root.error = "Could not read item"
        root.loading = false
      }
    }
  }

  Process {
    id: lockProc
  }

  Process {
    id: copyProc
    property string payload: ""
    command: ["wl-copy"]
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
    }
  }

  // -- overlay window --------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "com.aktivesolutions.bw-vault"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (emailField.activeFocus || passField.activeFocus) {
              // Blur the field first; a second Escape closes.
              keyCatcher.forceActiveFocus()
            } else if (root.screen === "list" && root.filterText) {
              root.filterText = ""; root.rebuildFilter()
            } else if (root.screen === "detail") {
              root.screen = "list"; root.detail = null; root.detailPassword = ""; root.showPass = false
            } else {
              root.dismiss()
            }
            event.accepted = true
            return
          }
          // While an input field holds focus, let it own the keys.
          if (emailField.activeFocus || passField.activeFocus) return

          if (root.screen === "list") {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              if (root.filteredItems.length > 0) root.openDetail(root.filteredItems[root.selectedIndex].id)
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.text === "j") {
              root.selectedIndex = root.clampIndex(root.selectedIndex + 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              root.selectedIndex = root.clampIndex(root.selectedIndex - 1)
              event.accepted = true
            } else if (event.text === "l") {
              root.lockVault()
              event.accepted = true
            } else if (Util.editsFilter(event, root.filterText)) {
              root.filterText = Util.editedFilter(event, root.filterText)
              root.rebuildFilter()
              event.accepted = true
            } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.filterText = root.filterText + event.text
              root.rebuildFilter()
              event.accepted = true
            }
          } else if (root.screen === "detail") {
            if (event.text === "c") { root.copyText(root.detail ? root.detail.username : ""); root.flashMessage("username copied"); event.accepted = true }
            else if (event.text === "y") { root.copyText(root.detailPassword); root.flashMessage("password copied"); event.accepted = true }
            else if (event.text === "p" || event.text === "P") { root.showPass = !root.showPass; event.accepted = true }
            else if (event.text === "l") { root.lockVault(); event.accepted = true }
          }
        }
      }

      Timer {
        id: flashTimer
        interval: 2000
        onTriggered: root.flash = ""
      }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        // --- unlock screen --------------------------------------------------
        Column {
          visible: root.screen === "unlock"
          anchors.centerIn: parent
          width: Math.min(Style.space(340), parent.width)
          spacing: Style.space(14)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "󰅆"
            color: root.foreground
            opacity: 0.8
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Bitwarden Vault"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            width: parent.width
            visible: root.status === "checking"
            horizontalAlignment: Text.AlignHCenter
            text: root.loading ? "Checking vault…" : "Checking vault…"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: emailField
            visible: root.emailNeeded
            width: parent.width
            placeholderText: "you@example.com"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.email = text
            onAccepted: root.startUnlock()
          }

          TextField {
            id: passField
            width: parent.width
            placeholderText: "Master password"
            password: true
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.masterPassword = text
            onAccepted: root.startUnlock()
          }

          Text {
            width: parent.width
            visible: root.error !== "" && !root.loading
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.error
            color: "#ff6b6b"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Unlock"
            hasCursor: true
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            onClicked: root.startUnlock()
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.loading && root.screen === "unlock"
              ? (root.emailNeeded ? "Approve the device in Bitwarden…" : "Unlocking…")
              : "esc to close"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // --- list screen ----------------------------------------------------
        Column {
          visible: root.screen === "list"
          anchors.fill: parent
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: root.filterText || "Search vault…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.15)
          }

          Text {
            width: parent.width
            visible: root.error !== ""
            wrapMode: Text.WordWrap
            text: root.error
            color: "#ff6b6b"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          ListView {
            id: listView
            width: parent.width
            height: parent.height - (root.error !== "" ? Style.space(30) : 0) - Style.space(24)
            clip: true
            spacing: Style.space(4)
            model: root.filteredItems
            boundsBehavior: Flickable.StopAtBounds
            currentIndex: root.selectedIndex

            onCountChanged: Qt.callLater(function() {
              if (root.selectedIndex >= 0)
                positionViewAtIndex(root.selectedIndex, ListView.Center)
            })

            delegate: BorderSurface {
              id: row
              required property var modelData
              required property int index

              readonly property bool hasCursor: index === root.selectedIndex

              width: ListView.view.width
              implicitHeight: Math.max(Style.space(46), titleLabel.implicitHeight + Style.space(14))
              radius: root.cornerRadius
              color: row.hasCursor ? root.selectedBackground : "transparent"
              borderSpec: row.hasCursor ? root.selectedBorderSpec : Border.none()

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - Style.space(90)
                  spacing: Style.space(2)

                  Text {
                    id: titleLabel
                    width: parent.width
                    text: modelData.name || "(untitled)"
                    color: row.hasCursor ? root.selectedText : root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: modelData.username || modelData.type
                    visible: modelData.username !== "" || modelData.type !== ""
                    color: row.hasCursor ? root.selectedText : Qt.darker(root.foreground, 1.4)
                    opacity: 0.7
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: itemTypeGlyph(modelData.type)
                  color: row.hasCursor ? root.selectedText : Qt.darker(root.foreground, 1.4)
                  opacity: 0.6
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.selectedIndex = row.index
                onClicked: root.openDetail(modelData.id)
              }
            }

            Text {
              anchors.centerIn: parent
              visible: root.filteredItems.length === 0 && !root.loading
              text: root.filterText ? "No matches" : "Vault is empty"
              color: Qt.darker(root.foreground, 1.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          Text {
            width: parent.width
            visible: !root.loading
            text: "enter open · / filter · l lock · esc close"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // --- detail screen --------------------------------------------------
        Column {
          visible: root.screen === "detail"
          anchors.fill: parent
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: root.loading ? "Decrypting…" : (root.detail ? root.detail.name : "Item")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Rectangle {
            width: parent.width
            height: 1
            color: Util.alpha(root.foreground, 0.15)
          }

          Text {
            width: parent.width
            visible: root.error !== ""
            wrapMode: Text.WordWrap
            text: root.error
            color: "#ff6b6b"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: !root.loading && root.detail !== null

            DetailRow {
              label: "type"
              value: root.detail ? root.detail.type : ""
              foreground: root.foreground
              dimForeground: Qt.darker(root.foreground, 1.4)
              fontFamily: root.fontFamily
            }
            DetailRow {
              label: "username"
              value: root.detail ? root.detail.username : ""
              foreground: root.foreground
              dimForeground: Qt.darker(root.foreground, 1.4)
              fontFamily: root.fontFamily
            }
            DetailRow {
              label: "password"
              value: root.detail ? (root.showPass ? root.detailPassword : "••••••••••••") : ""
              foreground: root.foreground
              dimForeground: Qt.darker(root.foreground, 1.4)
              fontFamily: root.fontFamily
            }
            Repeater {
              model: root.detail && root.detail.uris ? root.detail.uris : []
              DetailRow {
                label: "url"
                value: modelData
                foreground: root.foreground
                dimForeground: Qt.darker(root.foreground, 1.4)
                fontFamily: root.fontFamily
              }
            }
            DetailRow {
              label: "notes"
              value: root.detail ? root.detail.notes : ""
              foreground: root.foreground
              dimForeground: Qt.darker(root.foreground, 1.4)
              fontFamily: root.fontFamily
            }
          }

          Text {
            width: parent.width
            visible: root.detail !== null
            text: root.flash
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.space(8)
            visible: root.detail !== null

            Button {
              text: "Copy user"
              hasCursor: true
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: { root.copyText(root.detail.username); root.flashMessage("username copied") }
            }
            Button {
              text: "Copy pass"
              hasCursor: true
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: { root.copyText(root.detailPassword); root.flashMessage("password copied") }
            }
            Button {
              text: root.showPass ? "Hide" : "Reveal"
              hasCursor: true
              foreground: root.foreground
              accent: Color.accent
              fontFamily: root.fontFamily
              onClicked: root.showPass = !root.showPass
            }
          }

          Text {
            width: parent.width
            visible: root.detail !== null
            text: "esc back · p reveal · c copy user · y copy pass · l lock"
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // -- reusable detail row ----------------------------------------------------

  component DetailRow: Item {
    id: detailRow
    required property string label
    required property string value
    property color foreground: "#ffffff"
    property color dimForeground: "#999999"
    property string fontFamily: "sans-serif"
    width: parent ? parent.width : 0
    implicitHeight: Math.max(Style.space(20), valueText.implicitHeight)

    Text {
      id: labelText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(90)
      text: detailRow.label + ":"
      color: detailRow.dimForeground
      font.family: detailRow.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      id: valueText
      anchors.left: labelText.right
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: detailRow.value
      visible: detailRow.value !== ""
      color: detailRow.foreground
      font.family: detailRow.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
      wrapMode: Text.Wrap
      maximumLineCount: 4
    }
  }
}
