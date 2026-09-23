import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "VaultModel.js" as VaultModel

// BW Vault, in the bar. The whole plugin lives here now: unlock, search, copy,
// and item detail, in a dropdown under a padlock.
//
// There used to be a fullscreen overlay as well. It went because the dropdown
// does the same job with less ceremony — you want one password, and you are
// already looking at the field you will paste it into.
//
// The dropdown closes when focus moves to a browser. API-key setup therefore
// retains only the non-secret client ID across closes, so the user can copy
// the client secret in a second trip and save both values to Secret Service.
//
// Session, item metadata and every `bw` child live in Service.qml, which the
// shell mounts once. This file holds screens, selection and focus.
Panel {
  id: root
  moduleName: "com.aktivesolutions.bw-vault"

  // Its own IPC target, so it can carry a keybinding:
  //   omarchy-shell bw-vault-bar toggle
  //   omarchy-shell bw-vault-bar search github
  //
  // `ipcTarget` is left unset on purpose: setting it makes Panel declare a
  // second handler for the same name, and the two then split the method list
  // between them — `open` and `toggle` stopped being visible to
  // `qs ipc show`, which is a bad surprise for anyone binding a key to them.
  // The handler below owns the name outright.
  //
  // The shell still logs "Handler was registered but will not be used" for
  // this target. That is not this: it logs the same line for omarchy.audio,
  // omarchy.bluetooth and every other panel-backed bar widget, because it
  // instantiates them more than once. The surviving handler is this one.
  readonly property string ipcName: "bw-vault-bar"

  readonly property var svc: (root.bar && root.bar.shell) ? root.bar.shell.serviceFor(moduleName) : null

  // The shell injects settings into widgets but never into services, so this
  // widget is the only place that sees them — hand them over.
  function pushSettings() {
    if (svc && "settings" in svc) svc.settings = root.settings
  }

  onSvcChanged: root.pushSettings()
  onSettingsChanged: root.pushSettings()
  Component.onCompleted: root.pushSettings()

  readonly property int maxResults: Math.max(3, Math.min(20, Number(root.setting("maxResults", 8)) || 8))
  readonly property bool lockOnRightClick: root.setting("lockOnRightClick", true) !== false
  readonly property bool showCount: root.setting("showCount", false) === true

  // -- mirrored service state ------------------------------------------------

  readonly property string status: root.svc ? root.svc.status : "checking"
  readonly property bool unlocked: root.svc ? root.svc.unlocked : false
  readonly property bool itemsLoaded: root.svc ? root.svc.itemsLoaded : false
  readonly property bool busy: root.svc ? root.svc.busy : false
  // `busy` covers any bw child, including the ~5s list that runs when the
  // panel opens. `unlocking` is only the login/unlock pair. The unlock form
  // must gate on the latter: gating on `busy` disables the password field for
  // the first five seconds it is on screen, so the opening characters of
  // whatever you type are dropped and the truncated rest is submitted — which
  // bw reports as a decryption failure, not as a short password.
  readonly property string authPhase: root.svc ? root.svc.authPhase : ""
  readonly property bool unlocking: root.authPhase !== ""
  readonly property bool apiKeyStored: root.svc ? root.svc.apiKeyStored : false
  readonly property bool apiKeySaving: root.svc ? root.svc.apiKeySaving : false
  readonly property var items: root.svc ? root.svc.items : []
  readonly property bool offline: root.svc ? root.svc.offline : false
  readonly property string serviceError: root.svc ? root.svc.error : ""

  // -- view state ------------------------------------------------------------

  // "unlock" | "connections" | "list" | "detail"
  property string screen: "list"

  readonly property string endpointToolPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/bw-vault-storage")).replace(/^file:\/\//, ""))
  property var endpoints: []
  property string selectedEndpointId: "default"
  property string editingEndpointId: ""
  property bool connectionEditor: false
  property string connectionError: ""
  property string pendingRemoveId: ""
  readonly property var selectedConnection: {
    for (var i = 0; i < root.endpoints.length; i++)
      if (root.endpoints[i].id === root.selectedEndpointId) return root.endpoints[i]
    return null
  }

  function endpointAction(action, args) {
    if (endpointProc.running) return
    root.connectionError = ""
    endpointProc.operation = action
    endpointProc.command = [root.endpointToolPath, action].concat(args || [])
    endpointProc.running = true
  }

  function loadEndpoints() { root.endpointAction("list", []) }

  function openConnections() {
    if (root.apiKeySaving) return
    root.connectionEditor = false
    root.pendingRemoveId = ""
    root.screen = "connections"
    root.loadEndpoints()
  }

  function editConnection(item) {
    root.editingEndpointId = item ? item.id : ""
    connectionNameField.text = item ? item.name : ""
    connectionUrlField.text = item ? item.url : ""
    root.connectionEditor = true
    Qt.callLater(function() { connectionNameField.forceActiveFocus() })
  }

  function saveConnection() {
    var name = connectionNameField.text.trim()
    var url = connectionUrlField.text.trim()
    if (!name || !/^https?:\/\/[^\s/]+(?::\d+)?\/?$/.test(url)) {
      root.connectionError = "Enter a name and an HTTP(S) server URL"
      return
    }
    root.endpointAction(root.editingEndpointId ? "update" : "add",
      root.editingEndpointId ? [root.editingEndpointId, name, url] : [name, url])
  }

  Process {
    id: endpointProc
    property string operation: ""
    stdout: StdioCollector { id: endpointOut; waitForEnd: true }
    stderr: StdioCollector { id: endpointErr; waitForEnd: true }
    onExited: function(exitCode) {
      var op = endpointProc.operation
      endpointProc.operation = ""
      if (exitCode !== 0) {
        root.connectionError = String(endpointErr.text || "Connection change failed").trim().split("\n")[0]
        return
      }
      if (op === "list") {
        try {
          var data = JSON.parse(endpointOut.text)
          root.endpoints = data.endpoints || []
          root.selectedEndpointId = data.selected || "default"
        } catch (e) { root.connectionError = "Could not read connections" }
        return
      }
      root.connectionEditor = false
      root.pendingRemoveId = ""
      if (root.svc) root.svc.endpointChanged()
      root.screen = "unlock"
      Qt.callLater(function() { root.loadEndpoints() })
    }
  }

  property string query: ""
  property var results: []
  property int selectedIndex: 0

  // Read off the unlock field, one-way via onTextChanged — clearing the field
  // is what actually zeroes it.
  property string masterPassword: ""

  // Whatever `bw get` is currently fetching, as a token and an intent. Never a
  // password: see onItemFetched.
  property string pendingToken: ""
  property string pendingIntent: ""
  property string pendingLabel: ""
  property int fetchSeq: 0
  property string pendingTotpToken: ""
  property int totpSeq: 0

  // The one open item. Holds a password and current TOTP code for as long as
  // the detail screen is showing them, and no longer — see leaveDetail().
  property var detail: null
  property string detailPassword: ""
  property string detailTotp: ""
  property string detailTotpError: ""
  property bool showPass: false

  property string notice: ""
  property bool noticeIsError: false

  readonly property bool vertical: root.bar ? root.bar.vertical === true : false
  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.45)
  readonly property color fainter: Qt.darker(root.foreground, 1.7)

  // A padlock is the wrong mark for this. In a status bar it reads as *screen*
  // lock, and a bar that appears to say "this machine is unlocked" is worse
  // than no icon at all. A shield with a key says credentials instead, and the
  // filled/outline pair carries locked-vs-unlocked without a padlock anywhere.
  //
  // md-shield_key (0xF0BC4) unlocked · md-shield_key_outline (0xF0BC5) locked ·
  // md-shield_off_outline (0xF099C) not logged in · md-loading (0xF0772) working
  readonly property string icon: root.status === "unauthenticated"
    ? "󰦜"
    : root.status === "checking"
      ? "󰝲"
      : root.unlocked ? "󰯄" : "󰯅"

  readonly property string statusText: root.status === "unauthenticated"
    ? (root.apiKeyStored ? "Not logged in" : "Not set up")
    : root.status === "checking"
      ? "Checking…"
      : root.unlocked
        ? (root.offline ? "Offline · " : "") + (root.itemsLoaded ? root.items.length + (root.items.length === 1 ? " item" : " items") : "Unlocked")
        : "Locked"

  // -- screens ---------------------------------------------------------------

  function syncScreen() {
    root.screen = root.unlocked ? "list" : "unlock"
  }

  // KeyboardPanel applies focusTarget only when the panel opens. Switching
  // from the list to detail while it is already open otherwise leaves the
  // hidden search field focused: its Esc handler closes the whole panel and
  // p/c/y never reach PanelKeyCatcher.
  function focusCurrentScreen() {
    if (!root.opened) return
    if (root.screen === "detail") keyCatcher.forceActiveFocus()
    else if (root.screen === "list" && root.unlocked) searchField.forceActiveFocus()
    else if (root.screen === "unlock" && root.status !== "checking") {
      if (!root.apiKeyStored && root.status === "unauthenticated")
        (clientIdField.text ? clientSecretField : clientIdField).forceActiveFocus()
      else passField.forceActiveFocus()
    }
    else if (root.screen === "connections")
      (root.connectionEditor ? connectionNameField : keyCatcher).forceActiveFocus()
  }

  function leaveDetail() {
    root.detail = null
    root.detailPassword = ""
    root.detailTotp = ""
    root.detailTotpError = ""
    root.pendingTotpToken = ""
    root.showPass = false
    root.screen = "list"
    Qt.callLater(function() {
      if (root.opened && root.unlocked) searchField.forceActiveFocus()
    })
  }

  // -- filtering -------------------------------------------------------------

  function rebuild() {
    var q = String(root.query).toLowerCase().trim()
    var source = root.items
    var out = []
    for (var i = 0; i < source.length && out.length < root.maxResults; i++) {
      if (VaultModel.matchesQuery(source[i], q)) out.push(source[i])
    }
    root.results = out
    root.selectedIndex = root.clampIndex(root.selectedIndex)
    if (root.svc) root.svc.touch()
  }

  function clampIndex(i) {
    if (root.results.length === 0) return 0
    return Math.max(0, Math.min(i, root.results.length - 1))
  }

  function move(delta) {
    root.selectedIndex = root.clampIndex(root.selectedIndex + delta)
  }

  readonly property var selectedItem: (root.selectedIndex >= 0 && root.selectedIndex < root.results.length)
    ? root.results[root.selectedIndex]
    : null

  // -- unlock ----------------------------------------------------------------

  function submitUnlock() {
    if (root.unlocking) return
    if (!root.apiKeyStored && root.status === "unauthenticated") {
      root.say("Save your API key first", true)
      return
    }
    if (!String(root.masterPassword)) {
      root.say("Master password required", true)
      return
    }
    root.notice = ""
    if (root.svc) root.svc.unlockWithStored(root.masterPassword)
  }

  function submitApiKey() {
    var clientId = clientIdField.text.trim()
    var clientSecret = clientSecretField.text
    if (!clientId || !clientSecret) {
      root.say("Client ID and client secret are required", true)
      return
    }
    if (root.svc && root.svc.storeApiKey(clientId, clientSecret)) {
      clientSecretField.text = ""
      root.notice = ""
    }
  }

  // -- copying ---------------------------------------------------------------

  // The username is already in the cached metadata, so this is instant. Copying
  // it is a big share of what a vault is actually used for, and worth its own
  // key for that reason alone.
  function copyUsername(item) {
    var target = item || root.selectedItem
    if (!target || !target.username) {
      root.say("No username on this item", true)
      return
    }
    if (root.svc) root.svc.copyValue(target.username)
    root.say("Copied username · " + target.name, false)
  }

  // The password is not cached, so this costs one `bw get` — around four
  // seconds cold. The panel says it is fetching rather than pretending the copy
  // already happened.
  function fetchSelected(intent) {
    if (root.pendingToken !== "") {
      root.say("Another item is still loading", true)
      return
    }
    var item = root.selectedItem
    if (!item || !root.svc) return
    root.pendingToken = "bar:" + (++root.fetchSeq)
    root.pendingIntent = intent
    root.pendingLabel = item.name
    root.say(intent === "detail" ? "Opening " + item.name + "…" : "Fetching " + item.name + "…", false)
    if (intent === "detail") {
      root.screen = "detail"
      root.detail = null
      root.detailPassword = ""
      root.detailTotp = ""
      root.detailTotpError = ""
      root.pendingTotpToken = ""
      root.showPass = false
    }
    root.svc.fetchItem(item.id, root.pendingToken)
  }

  function copyDetailPassword() {
    if (!root.detailPassword) {
      root.say("No password on this item", true)
      return
    }
    if (root.svc) root.svc.copyValue(root.detailPassword)
    root.say("Copied password", false)
  }

  function refreshDetailTotp() {
    if (!root.detail || root.detail.hasTotp !== true || !root.svc) return
    if (root.offline) {
      root.detailTotpError = "Unavailable offline"
      return
    }
    if (root.pendingTotpToken !== "") return
    root.detailTotp = ""
    root.detailTotpError = ""
    root.pendingTotpToken = "bar-totp:" + (++root.totpSeq)
    root.svc.fetchTotp(root.detail.id, root.pendingTotpToken)
  }

  function copyDetailTotp() {
    if (!root.detailTotp) {
      root.say(root.pendingTotpToken !== "" ? "One-time code is still loading" : "No one-time code available", true)
      return
    }
    if (root.svc) root.svc.copyValue(root.detailTotp)
    root.say("Copied one-time code", false)
  }

  function say(message, isError) {
    root.notice = message
    root.noticeIsError = isError === true
    noticeTimer.restart()
  }

  Timer {
    id: noticeTimer
    interval: 4000
    repeat: false
    onTriggered: if (root.pendingToken === "") root.notice = ""
  }

  Connections {
    target: root.svc

    // The password lands here and goes no further than this widget: to the
    // clipboard, or onto the detail screen for as long as it is showing. The
    // service never assigned it to anything.
    function onItemFetched(token, item, password) {
      if (token !== root.pendingToken) return
      var intent = root.pendingIntent
      root.pendingToken = ""
      root.pendingIntent = ""

      if (intent === "detail") {
        root.detail = item
        root.detailPassword = String(password || "")
        root.detailTotp = ""
        root.detailTotpError = ""
        root.notice = ""
        if (item && item.hasTotp === true) root.refreshDetailTotp()
        return
      }
      if (!item || !password) {
        root.say("No password on " + root.pendingLabel + " — ctrl+enter for details", true)
        return
      }
      root.svc.copyValue(password)
      root.say("Copied password · " + root.pendingLabel, false)
      noticeTimer.restart()
    }

    function onItemFetchFailed(token, message) {
      if (token !== root.pendingToken) return
      var intent = root.pendingIntent
      root.pendingToken = ""
      root.pendingIntent = ""
      if (intent === "detail") root.screen = "list"
      root.say(message || "Could not read item", true)
      noticeTimer.restart()
    }

    function onTotpFetched(token, code) {
      if (token !== root.pendingTotpToken) return
      root.pendingTotpToken = ""
      if (root.screen !== "detail" || !root.detail || root.detail.hasTotp !== true) return
      root.detailTotp = String(code || "")
      root.detailTotpError = ""
    }

    function onTotpFetchFailed(token, message) {
      if (token !== root.pendingTotpToken) return
      root.pendingTotpToken = ""
      if (root.screen !== "detail") return
      root.detailTotp = ""
      root.detailTotpError = String(message || "Could not read one-time code")
    }

    function onItemsRefreshed() {
      if (!root.opened) return
      root.syncScreen()
      root.rebuild()
      Qt.callLater(function() {
        if (root.opened && root.unlocked && root.screen === "list") searchField.forceActiveFocus()
      })
    }

    function onUnlockSucceeded() {
      passField.text = ""
      root.masterPassword = ""
    }

    function onAuthFailed() {
      passField.text = ""
      root.masterPassword = ""
      if (root.opened) Qt.callLater(function() { passField.forceActiveFocus() })
    }

    function onApiKeySaved() {
      clientIdField.text = ""
      clientSecretField.text = ""
      root.say("API key saved. Enter your master password.", false)
      if (root.opened) Qt.callLater(function() { passField.forceActiveFocus() })
    }

    function onApiKeySaveFailed(message) {
      root.say(message, true)
      if (root.opened) Qt.callLater(function() { clientSecretField.forceActiveFocus() })
    }

    function onLockedOut(reason) {
      root.query = ""
      root.results = []
      root.selectedIndex = 0
      root.pendingToken = ""
      root.pendingIntent = ""
      root.detail = null
      root.detailPassword = ""
      root.detailTotp = ""
      root.detailTotpError = ""
      root.pendingTotpToken = ""
      root.showPass = false
      root.screen = "unlock"
      if (reason === "switched") {
        clientIdField.text = ""
        clientSecretField.text = ""
      }
      if (root.opened) {
        root.say(reason === "expired" ? "Session expired"
          : (reason === "switched" ? "Connection changed" : "Locked"), false)
        Qt.callLater(function() { if (root.opened) root.focusCurrentScreen() })
      }
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.loadEndpoints()
      root.selectedIndex = 0
      root.notice = ""
      root.syncScreen()
      // Warm cache: this is a no-op and the list draws immediately. Cold: it
      // starts the chain, and onItemsRefreshed fills the list in.
      if (root.svc) root.svc.refresh()
      root.rebuild()
      Qt.callLater(function() {
        if (!root.opened) return
        if (root.unlocked) searchField.forceActiveFocus()
        else if (root.status !== "checking") root.focusCurrentScreen()
      })
    } else {
      // The fields are the source of query / masterPassword (one-way, via
      // onTextChanged), so clearing the properties alone would leave the last
      // search — and the master password — sitting in the boxes.
      searchField.text = ""
      passField.text = ""
      clientSecretField.text = ""
      root.masterPassword = ""
      root.query = ""
      root.results = []
      root.pendingToken = ""
      root.pendingIntent = ""
      root.detail = null
      root.detailPassword = ""
      root.detailTotp = ""
      root.detailTotpError = ""
      root.pendingTotpToken = ""
      root.showPass = false
      root.notice = ""
    }
  }

  onQueryChanged: root.rebuild()
  onItemsChanged: if (root.opened) root.rebuild()
  onUnlockedChanged: if (root.opened) root.syncScreen()
  onStatusChanged: if (root.opened && root.screen === "unlock")
    Qt.callLater(function() { root.focusCurrentScreen() })
  onScreenChanged: Qt.callLater(function() { root.focusCurrentScreen() })

  // Everything here filters metadata that is already in this process. Nothing
  // reads, fetches or copies a secret — a password still costs a keystroke on a
  // panel someone is looking at, which is the only place that decision belongs.
  IpcHandler {
    target: root.ipcName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connections(): void {
      if (!root.opened) root.open()
      root.openConnections()
    }

    // Open the dropdown with the search line already filled in, for a keybind
    // or a script that knows what you are looking for.
    function search(query: string): void {
      root.query = String(query || "")
      if (!root.opened) root.open()
      root.rebuild()
      Qt.callLater(function() {
        if (root.opened && root.unlocked) {
          searchField.text = root.query
          root.screen = "list"
          searchField.forceActiveFocus()
        }
      })
    }

    // Deliberately says nothing about which item is selected or what was
    // copied — only that a fetch is or is not outstanding.
    function status(): string {
      return JSON.stringify({
        status: root.status,
        screen: root.screen,
        apiKeyStored: root.apiKeyStored,
        items: root.items.length,
        results: root.results.length,
        query: root.query,
        opened: root.opened,
        pending: root.pendingToken !== "",
        notice: root.notice
      })
    }
  }

  // -------------------------------------------------------------------- bar
  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  Row {
    id: barRow
    spacing: Style.space(5)

    BarIconButton {
      id: button
      bar: root.bar
      text: root.icon
      tooltipText: "BW Vault — " + root.statusText
        + (root.lockOnRightClick && root.unlocked ? " · right: lock" : "")
      slotSize: Style.bar.statusSlot
      onPressed: function(b) {
        if (b === Qt.RightButton && root.lockOnRightClick && root.unlocked) {
          if (root.svc) root.svc.lock()
        } else {
          root.toggle()
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.showCount && root.unlocked && root.itemsLoaded && !root.vertical
      text: String(root.items.length)
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.screen === "detail" ? keyCatcher
      : (root.screen === "connections" ? (root.connectionEditor ? connectionNameField : keyCatcher)
        : (root.unlocked ? searchField
          : (!root.apiKeyStored && root.status === "unauthenticated"
            ? (clientIdField.text ? clientSecretField : clientIdField) : passField)))
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // A focused text field owns every key. On the detail screen there is no
      // field, so the single-letter shortcuts below are safe there and only
      // there.
      // A field may retain activeFocus for one event-loop turn after becoming
      // hidden. Detail navigation must win during that transition as well.
      blocked: root.screen !== "detail" && (searchField.activeFocus || passField.activeFocus
        || connectionNameField.activeFocus || connectionUrlField.activeFocus
        || clientIdField.activeFocus || clientSecretField.activeFocus)

      onCloseRequested: root.screen === "detail" ? root.leaveDetail()
        : (root.screen === "connections" ? (root.connectionEditor ? root.connectionEditor = false : root.screen = "unlock") : root.close())
      onMoveRequested: function(dx, dy) {
        if (root.screen === "detail" && dx < 0) root.leaveDetail()
      }
      onTextKey: function(t) {
        // Ctrl+L arrives here as the control character it produces (0x0C),
        // not as "l" — PanelKeyCatcher's movement branch matches on event.text
        // and a held Ctrl changes it, so the vim-style "l" binding never sees
        // this. Handled on every screen so lock is reachable from the detail
        // view too, where there is no field to press ctrl+l in.
        if (t === "\f") {
          if (root.svc) root.svc.lock()
          return
        }
        if (root.screen !== "detail") return
        if (t === "p" || t === "P") root.showPass = !root.showPass
        else if (t === "c" || t === "C") root.copyUsername(root.detail)
        else if (t === "y" || t === "Y") root.copyDetailPassword()
        else if (t === "o" || t === "O") root.copyDetailTotp()
        else if (t === "r" || t === "R") root.refreshDetailTotp()
      }

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero: what the vault is doing ------------------------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight,
            lockButton.visible ? lockButton.size : 0, editConnectionsButton.visible ? editConnectionsButton.size : 0)

          Text {
            textFormat: Text.PlainText
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.unlocked ? Color.accent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }

          // md-shield_lock_outline (0xF0CCC) — same op as right-clicking the
          // bar icon. A shield again, so nothing in this plugin draws the
          // padlock that means screen lock elsewhere in the bar.
          PanelActionButton {
            id: lockButton
            visible: root.unlocked
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰳌"
            tooltipText: "Lock the vault"
            foreground: root.foreground
            fontFamily: Style.font.family
            size: Style.space(24)
            bordered: true
            onClicked: if (root.svc) root.svc.lock()
          }

          PanelActionButton {
            id: editConnectionsButton
            visible: root.screen === "unlock"
            enabled: !root.apiKeySaving
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰏫"
            tooltipText: "Edit vault connections"
            foreground: root.foreground
            fontFamily: Style.font.family
            size: Style.space(22)
            onClicked: root.openConnections()
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: ((lockButton.visible ? lockButton.size : 0)
              + (editConnectionsButton.visible ? editConnectionsButton.size : 0))
              + ((lockButton.visible || editConnectionsButton.visible) ? Style.space(12) : 0)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.screen === "detail" && root.detail ? root.detail.name
                : (root.screen === "connections" ? "Connections" : "BW Vault")
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: (root.screen === "connections" ? "VAULT SERVERS"
                : root.screen === "detail"
                ? (root.detail ? String(root.detail.type).toUpperCase() : "OPENING…")
                : root.statusText.toUpperCase())
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              elide: Text.ElideRight
            }
          }
        }

        PanelSeparator {
          foreground: root.foreground
        }

        // ---------- Unlock ------------------------------------------------
        Column {
          visible: root.screen === "unlock"
          width: parent.width
          spacing: Style.space(10)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.selectedConnection
              ? root.selectedConnection.name + (root.selectedConnection.url ? " · " + root.selectedConnection.url : "")
              : "Default connection"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          Column {
            visible: !root.apiKeyStored && root.status === "unauthenticated"
            width: parent.width
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "Paste your personal API key from the web vault: Account Settings → Security → Keys. Your client ID stays here while you copy the secret."
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            TextField {
              id: clientIdField
              width: parent.width
              foreground: root.foreground
              placeholderText: "client_id"
              enabled: !root.apiKeySaving
              onAccepted: clientSecretField.forceActiveFocus()
              Keys.onEscapePressed: root.close()
            }

            TextField {
              id: clientSecretField
              width: parent.width
              foreground: root.foreground
              placeholderText: "client_secret"
              password: true
              enabled: !root.apiKeySaving
              onAccepted: root.submitApiKey()
              Keys.onEscapePressed: root.close()
            }

            Row {
              spacing: Style.space(8)
              PanelActionButton {
                iconText: "󰄬"
                tooltipText: "Save API key to system keyring"
                enabled: !root.apiKeySaving
                focusable: true
                bordered: true
                size: Style.space(26)
                onClicked: root.submitApiKey()
              }
              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "Save API key"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.apiKeySaving || root.notice !== "" || root.serviceError !== ""
              width: parent.width
              text: root.apiKeySaving ? "Saving to the system keyring…"
                : (root.notice !== "" ? root.notice : root.serviceError)
              color: root.noticeIsError || root.serviceError !== "" ? Color.urgent : root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          TextField {
            id: passField
            visible: root.apiKeyStored || root.status !== "unauthenticated"
            width: parent.width
            foreground: root.foreground
            placeholderText: "Master password"
            password: true
            enabled: !root.unlocking
            onTextChanged: root.masterPassword = text
            onAccepted: root.submitUnlock()
            Keys.onEscapePressed: root.close()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            // No password field on screen means no key to press — saying
            // "enter to unlock" under a form that isn't there is just noise.
            visible: passField.visible || root.unlocking
            text: root.unlocking
              ? (root.authPhase === "login" ? "Authenticating…" : "Unlocking…")
              : root.serviceError !== ""
                ? root.serviceError
                : "Enter to unlock"
            color: root.serviceError !== "" ? Color.urgent : root.fainter
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Connections -------------------------------------------
        Column {
          visible: root.screen === "connections"
          width: parent.width
          spacing: Style.space(8)

          Column {
            visible: !root.connectionEditor
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.endpoints
              delegate: Item {
                required property var modelData
                width: parent.width
                implicitHeight: Style.space(46)

                Column {
                  anchors.left: parent.left
                  anchors.right: endpointActions.left
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: (modelData.id === root.selectedEndpointId ? "● " : "") + modelData.name
                    color: modelData.id === root.selectedEndpointId ? Color.accent : root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    text: modelData.url || "Bitwarden default"
                    color: root.fainter
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                  }
                }

                Row {
                  id: endpointActions
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  PanelActionButton {
                    iconText: "󰁔"
                    tooltipText: "Use this connection"
                    enabled: !endpointProc.running && modelData.id !== root.selectedEndpointId
                    size: Style.space(22)
                    onClicked: root.endpointAction("select", [modelData.id])
                  }
                  PanelActionButton {
                    iconText: "󰏫"
                    tooltipText: "Edit connection"
                    enabled: !endpointProc.running
                    size: Style.space(22)
                    onClicked: root.editConnection(modelData)
                  }
                  PanelActionButton {
                    iconText: root.pendingRemoveId === modelData.id ? "󰄬" : "󰆴"
                    tooltipText: root.pendingRemoveId === modelData.id ? "Click again to remove" : "Remove connection"
                    enabled: !endpointProc.running && modelData.id !== "default"
                    size: Style.space(22)
                    onClicked: {
                      if (root.pendingRemoveId === modelData.id) root.endpointAction("remove", [modelData.id])
                      else root.pendingRemoveId = modelData.id
                    }
                  }
                }
              }
            }

            PanelActionButton {
              iconText: "󰐕"
              tooltipText: "Add connection"
              enabled: !endpointProc.running
              size: Style.space(24)
              focusable: true
              onClicked: root.editConnection(null)
            }
          }

          Column {
            visible: root.connectionEditor
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: connectionNameField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Connection name"
              enabled: !endpointProc.running
              Keys.onEscapePressed: root.connectionEditor = false
            }
            TextField {
              id: connectionUrlField
              width: parent.width
              foreground: root.foreground
              placeholderText: "https://vault.example.com"
              enabled: !endpointProc.running
              onAccepted: root.saveConnection()
              Keys.onEscapePressed: root.connectionEditor = false
            }
            Row {
              spacing: Style.space(8)
              PanelActionButton {
                iconText: "󰄬"
                tooltipText: "Save connection"
                enabled: !endpointProc.running
                focusable: true
                bordered: true
                size: Style.space(24)
                onClicked: root.saveConnection()
              }
              PanelActionButton {
                iconText: "󰅖"
                tooltipText: "Cancel"
                enabled: !endpointProc.running
                focusable: true
                size: Style.space(24)
                onClicked: root.connectionEditor = false
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.connectionError !== ""
            width: parent.width
            text: root.connectionError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelActionButton {
            iconText: "󰁍"
            tooltipText: "Back to unlock"
            size: Style.space(24)
            focusable: true
            onClicked: root.screen = "unlock"
          }
        }

        // ---------- List --------------------------------------------------
        Column {
          visible: root.screen === "list"
          width: parent.width
          spacing: Style.space(10)

          TextField {
            id: searchField
            width: parent.width
            foreground: root.foreground
            placeholderText: "Search the vault"
            onTextChanged: root.query = text

            Keys.onUpPressed: root.move(-1)
            Keys.onDownPressed: root.move(1)
            Keys.onEscapePressed: root.close()
            // Enter arrives as `accepted`, not as a Keys handler — binding both
            // would fire the fetch twice.
            onAccepted: root.fetchSelected("copy")
            Keys.onPressed: function(event) {
              if (!(event.modifiers & Qt.ControlModifier)) return
              if (event.key === Qt.Key_U) {
                root.copyUsername(null); event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.fetchSelected("detail"); event.accepted = true
              } else if (event.key === Qt.Key_L) {
                if (root.svc) root.svc.lock()
                event.accepted = true
              }
            }
          }

          Column {
            id: resultList
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.results

              delegate: ResultRow {
                width: resultList.width
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.results.length === 0
            width: parent.width
            text: !root.itemsLoaded
              ? (root.busy ? "Loading the vault…" : "No items loaded")
              : (root.query !== "" ? "Nothing matches that" : "The vault is empty")
            color: root.fainter
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.notice !== "" ? root.notice : (root.serviceError !== "" ? root.serviceError : "enter copy · ctrl+u user · ctrl+enter open")
            color: root.notice !== "" ? (root.noticeIsError ? Color.urgent : Color.accent) : (root.serviceError !== "" ? Color.urgent : root.fainter)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // ---------- Detail ------------------------------------------------
        Column {
          visible: root.screen === "detail"
          width: parent.width
          spacing: Style.space(8)

          DetailField {
            label: "USERNAME"
            value: root.detail ? String(root.detail.username || "") : ""
          }

          DetailField {
            label: "PASSWORD"
            // The one place a secret is drawn. Hidden until `p`, and gone the
            // moment the screen is left.
            value: root.detail
              ? (root.detailPassword === ""
                  ? "—"
                  : (root.showPass ? root.detailPassword : "••••••••••••"))
              : ""
          }

          DetailField {
            label: "ONE-TIME CODE"
            value: root.detail && root.detail.hasTotp === true
              ? (root.pendingTotpToken !== ""
                  ? "Loading…"
                  : (root.detailTotp !== "" ? root.detailTotp : (root.detailTotpError || "Unavailable")))
              : ""
          }

          DetailField {
            label: "URI"
            value: root.detail && root.detail.uris && root.detail.uris.length > 0
              ? String(root.detail.uris[0])
              : ""
          }

          DetailField {
            label: "NOTES"
            value: root.detail ? String(root.detail.notes || "") : ""
            wrap: true
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.notice !== ""
              ? root.notice
              : (root.detail
                  ? (root.detail.hasTotp === true
                      ? "p reveal · c user · y password · o otp · r refresh · ctrl+l lock · esc back"
                      : "p reveal · c user · y password · ctrl+l lock · esc back")
                  : "Fetching…")
            color: root.notice !== "" ? (root.noticeIsError ? Color.urgent : Color.accent) : root.fainter
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  Timer {
    id: totpRefreshTimer
    interval: 30000
    repeat: true
    running: root.opened && root.screen === "detail" && root.detail && root.detail.hasTotp === true
    onTriggered: root.refreshDetailTotp()
  }

  // One labelled row on the detail screen. Hidden when the item has nothing
  // for it, so a secure note does not show four empty boxes.
  component DetailField: Column {
    id: field
    property string label: ""
    property string value: ""
    property bool wrap: false

    visible: field.value !== ""
    width: parent ? parent.width : 0
    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: field.label
      color: root.fainter
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
    }

    Text {
      textFormat: Text.PlainText
      width: parent.width
      text: field.value
      color: root.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      wrapMode: field.wrap ? Text.WordWrap : Text.NoWrap
      maximumLineCount: field.wrap ? 6 : 1
      elide: Text.ElideRight
    }
  }

  // One vault entry. No secret is in the model — parseList() strips passwords
  // before the list ever reaches a property.
  component ResultRow: CursorSurface {
    id: row
    required property int index
    required property var modelData

    readonly property bool current: row.index === root.selectedIndex

    hasCursor: rowMouse.containsMouse || row.current
    foreground: root.foreground

    implicitHeight: Math.max(Style.space(34), rowContent.implicitHeight)

    Item {
      id: rowContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      implicitHeight: Math.max(rowGlyph.implicitHeight, info.implicitHeight)

      Text {
        textFormat: Text.PlainText
        id: rowGlyph
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyphForType(row.modelData.type)
        color: row.current ? Color.accent : Qt.darker(row.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }

      Column {
        id: info
        spacing: Style.space(1)
        anchors.left: rowGlyph.right
        anchors.leftMargin: Style.space(10)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: row.modelData.name || "(no name)"
          color: row.current ? Color.accent : row.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          visible: String(row.modelData.username || "") !== ""
          width: parent.width
          text: row.modelData.username
          color: root.fainter
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: root.selectedIndex = row.index
      onClicked: function(mouse) {
        root.selectedIndex = row.index
        if (mouse.button === Qt.RightButton) root.fetchSelected("detail")
        else root.fetchSelected("copy")
      }
    }
  }

  function glyphForType(type) {
    switch (type) {
    case "login": return "󰍤"
    case "secureNote": return "󰈐"
    case "card": return "󰅝"
    case "identity": return "󰓹"
    default: return "󰈉"
    }
  }
}
