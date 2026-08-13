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
// Screens: unlock (API key + master password) → searchable item list → item detail
// with copy-username / copy-password / reveal / lock.
//
// Session handling mirrors bw-tui: the session token is read from the OS
// keyring (secret-tool) on open, verified against `bw`, and re-stored after
// unlock so the master password is asked for once per machine. The personal
// API key (client_id / client_secret) is stored the same way after the first
// login, so it is pasted from the browser exactly once. The master password
// only ever travels through the child process environment (bw --passwordenv),
// never argv or a QML property that outlives the flow.

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
  property string clientId: ""
  property string clientSecret: ""
  property string masterPassword: ""

  property var items: []
  property var filteredItems: []
  property string filterText: ""
  property int selectedIndex: 0

  property var detail: null
  property string detailPassword: ""
  property bool showPass: false

  // "idle" | "login" | "unlock" — which auth step is in flight
  property string authPhase: "idle"
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
  // Floating unlock card: while the API key is needed the overlay shrinks to a
  // small draggable card and drops keyboard exclusivity, so you can switch to
  // the browser and copy client_id / client_secret without closing it.
  readonly property bool floating: root.screen === "unlock" && root.apiKeyNeeded
  property int floatX: 0
  property int floatY: 0
  readonly property int floatW: Math.min(Style.space(480), (panel.screen ? panel.screen.width : Style.space(700)) - Style.gapsOut * 2)
  readonly property int floatH: Math.min(Style.space(560), (panel.screen ? panel.screen.height : Style.space(700)) - Style.gapsOut * 2)
  readonly property int cardWidth: root.floating ? root.floatW : Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: root.floating ? root.floatH : Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
  // The account is not yet authenticated on this machine — the API key is
  // needed to log in. Once authenticated (even locked), only the master
  // password is required to unlock.
  readonly property bool apiKeyNeeded: status === "unauthenticated"

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
    clientIdField.text = ""
    clientSecretField.text = ""
    passField.text = ""

    // Start the keyring lookups (session + personal API key); the session
    // lookup drives the status chain and the key lookups pre-fill the unlock
    // screen.
    sessionLookup.running = true
    apiKeyIdLookup.running = true
    apiKeySecretLookup.running = true

    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    root.loading = false
    root.authPhase = ""
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

  // Keyring-backed API key pre-fill: the client_id / client_secret stored by
  // a previous login land here, so the unlock screen only needs the master
  // password from then on.
  function onApiKeyIdLookup(raw) {
    var id = String(raw || "").trim()
    if (root.opened && id) clientIdField.text = id
    root.focusUnlock()
  }

  function onApiKeySecretLookup(raw) {
    var secret = String(raw || "").trim()
    if (root.opened && secret) clientSecretField.text = secret
    root.focusUnlock()
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
    if (root.apiKeyNeeded) root.centerFloat()
    root.loading = false
    Qt.callLater(function() { root.focusUnlock() })
  }

  // -- unlock ----------------------------------------------------------------

  function startUnlock() {
    if (root.loading) return
    if (root.apiKeyNeeded && !String(root.clientId).trim()) {
      root.error = "client_id required"
      return
    }
    if (root.apiKeyNeeded && !String(root.clientSecret)) {
      root.error = "client_secret required"
      return
    }
    if (!String(root.masterPassword)) {
      root.error = "Master password required"
      return
    }
    root.error = ""
    root.loading = true

    if (root.apiKeyNeeded) {
      // Not yet authenticated: log in with the personal API key, then unlock.
      root.authPhase = "login"
      loginProc.command = VaultModel.apikeyLoginCommand()
      loginProc.environment = VaultModel.apikeyLoginEnvironment(
        String(root.clientId).trim(), root.clientSecret, root.masterPassword)
      loginProc.running = true
    } else {
      // Already authenticated; only the master password unlocks the vault.
      root.authPhase = "unlock"
      root.runUnlock()
    }
  }

  function runUnlock() {
    root.authPhase = "unlock"
    unlockProc.environment = VaultModel.passwordEnvironment(root.masterPassword)
    unlockProc.command = VaultModel.unlockCommand()
    unlockProc.running = true
  }

  function onUnlockSuccess(rawSession) {
    var session = String(rawSession || "").trim()
    root.masterPassword = ""
    root.authPhase = ""
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

  // Center the floating unlock card on its output. Called whenever the overlay
  // drops into the unauthenticated state; the card is re-centered on each open
  // so it never spawns off-screen.
  function centerFloat() {
    var sw = panel.screen ? panel.screen.width : 0
    var sh = panel.screen ? panel.screen.height : 0
    if (sw > 0) root.floatX = Math.max(0, Math.round((sw - root.floatW) / 2))
    if (sh > 0) root.floatY = Math.max(0, Math.round((sh - root.floatH) / 2))
  }

  // Focus the right unlock field: the master password when the API key is
  // already configured (keyring pre-fill), otherwise the client_id field.
  // Safe to call repeatedly — hidden fields and in-flight states are no-ops.
  function focusUnlock() {
    if (!root.opened) return
    if (root.status === "checking" || root.loading) return
    if (root.apiKeyNeeded) {
      if (root.clientId && root.clientSecret) passField.forceActiveFocus()
      else clientIdField.forceActiveFocus()
    } else {
      passField.forceActiveFocus()
    }
  }

  function clampIndex(i) {
    if (root.filteredItems.length === 0) return 0
    return Math.max(0, Math.min(i, root.filteredItems.length - 1))
  }

  // Live introspection for debugging: `omarchy-shell shell call <id> state`
  function state() {
    return JSON.stringify({
      opened: root.opened,
      screen: root.screen,
      status: root.status,
      floating: root.floating,
      floatPos: root.floatX + "," + root.floatY,
      loading: root.loading,
      authPhase: root.authPhase,
      clientId: root.clientId ? "set" : "",
      heldSession: root.heldSession ? "yes" : "no",
      error: root.error,
      items: root.items.length,
      filtered: root.filteredItems.length,
      selectedIndex: root.selectedIndex
    })
  }

  IpcHandler {
    target: "bw-vault"
    function ping(): string { return "ok" }
    function open(): void { root.open("{}") }
    function close(): void { root.dismiss() }
    function toggle(): void { root.opened ? root.dismiss() : root.open("{}") }
    function state(): string { return root.state() }
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
      id: sessionLookupOut
      waitForEnd: true
    }
    onExited: root.onSessionLookup(sessionLookupOut.text)
  }

  Process {
    id: sessionStore
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
    id: apiKeyIdLookup
    command: VaultModel.apiKeyIdLookupCommand()
    stdout: StdioCollector {
      id: apiKeyIdLookupOut
      waitForEnd: true
    }
    onExited: root.onApiKeyIdLookup(apiKeyIdLookupOut.text)
  }

  Process {
    id: apiKeySecretLookup
    command: VaultModel.apiKeySecretLookupCommand()
    stdout: StdioCollector {
      id: apiKeySecretLookupOut
      waitForEnd: true
    }
    onExited: root.onApiKeySecretLookup(apiKeySecretLookupOut.text)
  }

  Process {
    id: apiKeyIdStore
    command: VaultModel.apiKeyIdStoreCommand()
    stdinEnabled: true
    onStarted: {
      write(String(root.clientId || "") + "\n")
    }
  }

  Process {
    id: apiKeySecretStore
    command: VaultModel.apiKeySecretStoreCommand()
    stdinEnabled: true
    onStarted: {
      write(String(root.clientSecret || "") + "\n")
    }
  }

  Process {
    id: statusProc
    property bool hadSession: false
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (!root.opened) return
      root.onStatusOutput(statusOut.text, statusProc.hadSession)
    }
  }

  Process {
    id: loginProc
    property string collectedErr: ""
    stdout: StdioCollector {
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: loginErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (!root.opened) return
      var err = String(loginErr.text || "").trim()

      if (exitCode === 0) {
        root.error = ""
        // Persist the working API key to the keyring (non-fatal) so the next
        // open pre-fills it and only the master password is needed.
        apiKeyIdStore.running = true
        apiKeySecretStore.running = true
        root.runUnlock()
        return
      }

      if (root.loading) {
        root.error = err || "Login failed"
        root.loading = false
        root.authPhase = ""
        Qt.callLater(function() {
          if (root.opened) clientIdField.forceActiveFocus()
        })
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
        root.authPhase = ""
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.loading && root.opened && root.error === "") {
        root.error = "Unlock failed"
        root.loading = false
        root.authPhase = ""
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
    width: root.floating ? root.floatW : (panel.screen ? panel.screen.width : 0)
    height: root.floating ? root.floatH : (panel.screen ? panel.screen.height : 0)
    anchors.left: true
    anchors.top: true
    anchors.right: root.floating ? false : true
    anchors.bottom: root.floating ? false : true
    margins.left: root.floating ? root.floatX : 0
    margins.top: root.floating ? root.floatY : 0
    color: "transparent"
    WlrLayershell.namespace: "com.aktivesolutions.bw-vault"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.floating ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      visible: !root.floating
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
            if (root.screen === "list" && root.filterText) {
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
          if (clientIdField.activeFocus || clientSecretField.activeFocus || passField.activeFocus) return

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
            visible: root.status === "checking" || (root.loading && root.screen === "unlock")
            horizontalAlignment: Text.AlignHCenter
            text: root.status === "checking"
              ? "Checking vault…"
              : (root.authPhase === "login" ? "Authenticating with API key…" : "Unlocking…")
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: clientIdField
            visible: root.apiKeyNeeded && !root.loading && root.status !== "checking"
            width: parent.width
            placeholderText: "client_id (user.xxxx)"
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.clientId = text
            onAccepted: root.startUnlock()
          }

          TextField {
            id: clientSecretField
            visible: root.apiKeyNeeded && !root.loading && root.status !== "checking"
            width: parent.width
            placeholderText: "client_secret"
            password: true
            foreground: root.foreground
            accent: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            onTextChanged: root.clientSecret = text
            onAccepted: root.startUnlock()
          }

          TextField {
            id: passField
            visible: !root.loading && root.status !== "checking"
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
            visible: !root.loading && root.status !== "checking"
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
            visible: !root.loading && root.status !== "checking"
            text: root.floating ? "drag the card to move · esc to close" : "esc to close"
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

      // Drag handle for the floating unlock card: press and drag to move the
      // card out of the way while you copy credentials from another window.
      Item {
        id: dragBar
        visible: root.floating
        z: 10
        height: Style.space(28)
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset

        MouseArea {
          id: dragHandle
          anchors.fill: parent
          property bool dragActive: false
          property real pressGlobalX: 0
          property real pressGlobalY: 0
          property int startX: 0
          property int startY: 0
          hoverEnabled: true
          cursorShape: Qt.SizeAllCursor
          onPressed: function(mouse) {
            dragActive = true
            // Global pointer coords are invariant under the window moving, so
            // the grab point stays pinned to the cursor regardless of compositor
            // feedback lag when margins update.
            var g = dragHandle.mapToGlobal(mouse.x, mouse.y)
            pressGlobalX = g.x
            pressGlobalY = g.y
            startX = root.floatX
            startY = root.floatY
          }
          onPositionChanged: function(mouse) {
            if (!dragActive || !(mouse.buttons & Qt.LeftButton)) return
            var g = dragHandle.mapToGlobal(mouse.x, mouse.y)
            var sw = panel.screen ? panel.screen.width : root.floatW
            var sh = panel.screen ? panel.screen.height : root.floatH
            root.floatX = Math.max(0, Math.min(startX + (g.x - pressGlobalX), sw - root.floatW))
            root.floatY = Math.max(0, Math.min(startY + (g.y - pressGlobalY), sh - root.floatH))
          }
          onReleased: dragActive = false
          onCanceled: dragActive = false

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰅆  Bitwarden Vault"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            opacity: 0.85
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
