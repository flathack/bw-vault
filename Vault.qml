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
// This file is a view. The session token, the item metadata, and every `bw`
// child live in Service.qml, which the shell mounts once at startup and shares
// with the bar dropdown (BarWidget.qml). What stays here is what only a
// fullscreen overlay has: which screen is showing, what is typed in the search
// line, which row is selected, and the credentials on the unlock form.
//
// The unlock form is the reason the API-key keyring lookups stayed behind. The
// client_id / client_secret pre-fill exists to serve exactly this screen, and
// keeping it here means the always-loaded service never holds a client_secret.
// The master password is the same story: it is read off the field, handed to
// Service.unlock(), and lives from there on only inside a child process
// environment that is cleared when the child exits.
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (manifest && manifest.id) || "com.aktivesolutions.bw-vault"
  readonly property var svc: (root.shell && typeof root.shell.serviceFor === "function")
    ? root.shell.serviceFor(root.pluginId)
    : null

  // -- view state ------------------------------------------------------------

  property bool opened: false

  property string screen: "unlock"

  // Credentials, read off the unlock form. Bound one-way from the fields'
  // onTextChanged, which is why clearing a field is what actually zeroes the
  // property — assigning the property alone leaves the secret in the field.
  property string clientId: ""
  property string clientSecret: ""
  property string masterPassword: ""

  property var filteredItems: []
  property string filterText: ""
  property int selectedIndex: 0

  property var detail: null
  property string detailPassword: ""
  property bool showPass: false
  property bool detailLoading: false
  property string detailToken: ""
  property int detailSeq: 0

  property string localError: ""
  property string flash: ""

  // -- mirrored from the service --------------------------------------------

  readonly property string status: root.svc ? root.svc.status : "checking"
  readonly property string authPhase: root.svc ? root.svc.authPhase : ""
  readonly property var items: root.svc ? root.svc.items : []
  readonly property bool loading: (root.svc ? root.svc.busy : false) || root.detailLoading
  readonly property string error: root.localError !== ""
    ? root.localError
    : (root.svc ? root.svc.error : "")

  readonly property bool apiKeyNeeded: root.status === "unauthenticated"

  // -- appearance ------------------------------------------------------------

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

  // The unlock card floats (and is draggable) only while the API key is being
  // entered, so a browser can be read alongside it.
  readonly property bool floating: root.screen === "unlock" && root.apiKeyNeeded
  property int floatX: 0
  property int floatY: 0
  readonly property int floatW: Math.min(Style.space(480), (panel.screen ? panel.screen.width : Style.space(700)) - Style.gapsOut * 2)
  readonly property int floatH: Math.min(Style.space(560), (panel.screen ? panel.screen.height : Style.space(700)) - Style.gapsOut * 2)
  readonly property int cardWidth: root.floating ? root.floatW : Math.min(Style.space(480), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: root.floating ? root.floatH : Math.min(Style.space(560), panel.height - Style.gapsOut * 2)

  // -- open / close ----------------------------------------------------------

  function open(payloadJson) {
    root.opened = true
    root.localError = ""
    root.flash = ""
    root.showPass = false
    root.detailPassword = ""
    root.detail = null
    root.detailLoading = false
    root.filterText = ""
    root.selectedIndex = 0
    passField.text = ""

    // Pre-fill the unlock form from the keyring. Cheap (secret-tool, ~25ms) and
    // only useful to this screen, so it does not belong in the service.
    apiKeyIdLookup.running = true
    apiKeySecretLookup.running = true

    // A warm cache means the list is ready to draw before the first frame; a
    // cold one means refresh() starts the chain and onItemsRefreshed lands us
    // on the list when it completes.
    root.syncScreen()
    if (root.svc) root.svc.refresh()

    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function syncScreen() {
    if (root.svc && root.svc.unlocked && root.svc.itemsLoaded) {
      root.screen = "list"
      root.rebuildFilter()
    } else {
      root.screen = "unlock"
    }
  }

  // Drop every secret this view is holding. The session and the item metadata
  // deliberately survive in the service — that is what makes reopening (and the
  // bar dropdown) instant. Nothing dropped here is recoverable from what stays:
  // metadata carries no passwords.
  //
  // Clearing the text fields is what actually zeroes masterPassword /
  // clientSecret; see the property declarations above. clientIdField is left
  // alone — a client id isn't a secret.
  //
  // The clipboard is deliberately NOT wiped here. The overlay takes exclusive
  // keyboard focus, so dismissing it is the only way to reach another window and
  // paste; wiping on dismiss would make copying useless. The service's
  // clipboardClearTimer handles the wipe 20s after the copy instead.
  function clearViewSecrets() {
    passField.text = ""
    clientSecretField.text = ""
    root.masterPassword = ""
    root.clientSecret = ""
    root.detailPassword = ""
    root.detail = null
    root.detailToken = ""
    root.detailLoading = false
    root.showPass = false
    root.filteredItems = []
    root.selectedIndex = 0
  }

  function close() {
    root.opened = false
    root.localError = ""
    root.clearViewSecrets()
  }

  function dismiss() {
    root.opened = false
    root.localError = ""
    root.clearViewSecrets()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
    else close()
  }

  // -- service wiring --------------------------------------------------------

  Connections {
    target: root.svc

    // The list landed. Whether it came from this open or from the bar dropdown
    // asking a moment earlier, the overlay shows it.
    function onItemsRefreshed() {
      if (!root.opened) return
      root.localError = ""
      root.screen = "list"
      root.rebuildFilter()
      Qt.callLater(function() {
        if (root.opened) keyCatcher.forceActiveFocus()
      })
    }

    // The API key that just worked is worth keeping: the next unlock then needs
    // only the master password. Stored from this view's fields, so the service
    // never sees a client_secret. Non-fatal.
    function onLoginSucceeded() {
      apiKeyIdStore.payload = String(root.clientId || "")
      apiKeyIdStore.stdinEnabled = true
      apiKeyIdStore.running = true
      apiKeySecretStore.payload = String(root.clientSecret || "")
      apiKeySecretStore.stdinEnabled = true
      apiKeySecretStore.running = true
    }

    function onUnlockSucceeded() {
      passField.text = ""
      root.masterPassword = ""
    }

    // Locked, or the keyring session turned out to be dead. Either way there is
    // nothing left to show.
    function onLockedOut(reason) {
      root.screen = "unlock"
      root.detail = null
      root.detailPassword = ""
      root.detailToken = ""
      root.detailLoading = false
      root.showPass = false
      root.filteredItems = []
      root.selectedIndex = 0
      root.filterText = ""
      if (root.opened) Qt.callLater(function() { root.focusUnlock() })
    }

    // The password arrives here and goes no further than this view; the service
    // never assigned it to anything. Ignored unless this overlay is the one that
    // asked — the bar dropdown fetches through the same service.
    function onItemFetched(token, item) {
      if (token !== root.detailToken) return
      root.detailLoading = false
      root.detail = item
      root.detailPassword = item ? item.password : ""
    }

    function onItemFetchFailed(token, message) {
      if (token !== root.detailToken) return
      root.detailLoading = false
      root.localError = message || "Could not read item"
    }
  }

  // -- unlock ----------------------------------------------------------------

  function startUnlock() {
    if (root.loading) return
    if (root.apiKeyNeeded && !String(root.clientId).trim()) {
      root.localError = "client_id required"
      return
    }
    if (root.apiKeyNeeded && !String(root.clientSecret)) {
      root.localError = "client_secret required"
      return
    }
    if (!String(root.masterPassword)) {
      root.localError = "Master password required"
      return
    }
    root.localError = ""
    if (root.svc) root.svc.unlock(root.clientId, root.clientSecret, root.masterPassword)
  }

  // -- filtering -------------------------------------------------------------

  // Apply a pending debounced rebuild right now. Selection and Enter must act on
  // what the user actually typed, not on the last coalesced frame.
  function flushFilter() {
    if (!filterTimer.running) return
    filterTimer.stop()
    root.rebuildFilter()
  }

  function rebuildFilter() {
    var q = String(root.filterText).toLowerCase().trim()
    var source = root.items
    var out = []
    for (var i = 0; i < source.length; i++) {
      if (VaultModel.matchesQuery(source[i], q)) out.push(source[i])
    }
    root.filteredItems = out
    if (root.selectedIndex >= root.filteredItems.length)
      root.selectedIndex = root.filteredItems.length - 1
    if (root.selectedIndex < 0) root.selectedIndex = 0
    if (root.svc) root.svc.touch()
  }

  // -- detail ----------------------------------------------------------------

  function openDetail(id) {
    root.screen = "detail"
    root.detailLoading = true
    root.localError = ""
    root.detail = null
    root.detailPassword = ""
    root.showPass = false
    root.detailToken = "overlay:" + (++root.detailSeq)
    if (root.svc) root.svc.fetchItem(id, root.detailToken)
  }

  // -- lock / copy -----------------------------------------------------------

  function lockVault() {
    root.filterText = ""
    root.localError = ""
    if (root.svc) root.svc.lock()
  }

  function copyText(text) {
    if (!text) return
    if (root.svc) root.svc.copyValue(text)
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

  onApiKeyNeededChanged: if (root.apiKeyNeeded) root.centerFloat()

  // Focus the right unlock field: the master password when the API key is
  // already configured (keyring pre-fill), otherwise the client_id field.
  // Safe to call repeatedly — hidden fields and in-flight states are no-ops.
  function focusUnlock() {
    if (!root.opened) return
    if (root.screen !== "unlock") return
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

  // Live introspection for debugging: `omarchy-shell bw-vault state`
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
      service: root.svc ? "up" : "down",
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

  // -- keyring pre-fill for the unlock form ----------------------------------

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
    // Snapshotted by the caller before running, so a dismiss racing the
    // asynchronous start can't blank the keyring entry.
    property string payload: ""
    command: VaultModel.apiKeyIdStoreCommand()
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
      stdinEnabled = false
    }
  }

  Process {
    id: apiKeySecretStore
    property string payload: ""
    command: VaultModel.apiKeySecretStoreCommand()
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
      stdinEnabled = false
    }
  }

  // Coalesce fast typing. Assigning a new array to the ListView model is a full
  // delegate reset plus a reposition, so one rebuild per burst beats one per
  // keystroke. The search line is bound to filterText and still updates on every
  // character, so typing itself stays responsive.
  Timer {
    id: filterTimer
    interval: 60
    onTriggered: root.rebuildFilter()
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
              root.filterText = ""; filterTimer.stop(); root.rebuildFilter()
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
              root.flushFilter()
              if (root.filteredItems.length > 0) root.openDetail(root.filteredItems[root.selectedIndex].id)
              event.accepted = true
            } else if (event.key === Qt.Key_Down || event.text === "j") {
              root.flushFilter()
              root.selectedIndex = root.clampIndex(root.selectedIndex + 1)
              event.accepted = true
            } else if (event.key === Qt.Key_Up || event.text === "k") {
              root.flushFilter()
              root.selectedIndex = root.clampIndex(root.selectedIndex - 1)
              event.accepted = true
            } else if (event.text === "l") {
              root.lockVault()
              event.accepted = true
            } else if (Util.editsFilter(event, root.filterText)) {
              root.filterText = Util.editedFilter(event, root.filterText)
              filterTimer.restart()
              event.accepted = true
            } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
              root.filterText = root.filterText + event.text
              filterTimer.restart()
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
