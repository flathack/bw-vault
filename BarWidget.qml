import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "VaultModel.js" as VaultModel

// BW Vault in the bar — lock state at a glance, and a dropdown for the case
// the fullscreen overlay is too much ceremony for: you want one password,
// right now, without losing sight of the window you are pasting into.
//
// Both views share Service.qml, so this dropdown does not run its own `bw`
// pipeline. That matters more than it sounds: `bw` is a Node program and a cold
// start costs ~4s here. Opening the dropdown against a warm cache costs nothing
// — the item list is already in the service. Only the password itself is
// fetched on demand, because only the password is worth never caching.
//
// The trade that makes this work: item metadata (names, usernames, URIs) now
// outlives the panel. Passwords never do.
Panel {
  id: root
  moduleName: "com.aktivesolutions.bw-vault"

  // The dropdown is worth its own keybinding, separate from the full vault:
  //   omarchy-shell bw-vault-bar toggle
  //   omarchy-shell bw-vault-bar search github
  // `omarchy-shell shell toggle com.aktivesolutions.bw-vault` stays pointed at
  // the overlay, since that is the plugin's summonable surface.
  //
  // Panel's own handler covers open/close/toggle; this widget declares the
  // whole surface itself so `search` can join them on the same target.
  ipcTarget: "bw-vault-bar"
  manageIpc: false

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
  readonly property var items: root.svc ? root.svc.items : []

  // -- view state ------------------------------------------------------------

  property string query: ""
  property var results: []
  property int selectedIndex: 0

  // The one in-flight password fetch, if any. Held as a token, never as a
  // password: see onItemFetched, where the secret goes straight to the
  // clipboard and out of scope.
  property string pendingToken: ""
  property string pendingLabel: ""
  property int fetchSeq: 0

  property string notice: ""
  property bool noticeIsError: false

  readonly property color foreground: root.bar ? root.bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(root.foreground, 1.45)
  readonly property color fainter: Qt.darker(root.foreground, 1.7)

  // md-lock (0xF033E) locked · md-lock_open_variant (0xF0FC6) unlocked ·
  // md-shield_off_outline (0xF099C) not logged in · md-loading (0xF0772) working
  readonly property string icon: root.status === "unauthenticated"
    ? "󰦜"
    : root.status === "checking"
      ? "󰝲"
      : root.unlocked ? "󰿆" : "󰌾"

  readonly property string statusText: root.status === "unauthenticated"
    ? "Not logged in"
    : root.status === "checking"
      ? "Checking…"
      : root.unlocked
        ? (root.itemsLoaded ? root.items.length + (root.items.length === 1 ? " item" : " items") : "Unlocked")
        : "Locked"

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

  // -- copying ---------------------------------------------------------------

  // The username is already in the cached metadata, so this is instant. Copying
  // it is a big share of what a vault is actually used for, and worth having as
  // its own key for that reason alone.
  function copyUsername() {
    var item = root.selectedItem
    if (!item || !item.username) {
      root.say("No username on this item", true)
      return
    }
    if (root.svc) root.svc.copyValue(item.username)
    root.say("Copied username · " + item.name, false)
  }

  // The password is not cached, so this costs one `bw get` — around four
  // seconds cold. The panel stays open and says so rather than pretending the
  // copy already happened.
  function copyPassword() {
    var item = root.selectedItem
    if (!item) return
    if (!root.svc) return
    root.pendingToken = "bar:" + (++root.fetchSeq)
    root.pendingLabel = item.name
    root.say("Fetching " + item.name + "…", false)
    root.svc.fetchItem(item.id, root.pendingToken)
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

    // The password lands here, goes to the clipboard, and is not kept: `item`
    // is a call argument that falls out of scope when this returns. The service
    // never assigned it to anything either.
    function onItemFetched(token, item) {
      if (token !== root.pendingToken) return
      root.pendingToken = ""
      if (!item || !item.password) {
        root.say("No password on " + root.pendingLabel, true)
        return
      }
      root.svc.copyValue(item.password)
      root.say("Copied password · " + root.pendingLabel, false)
      noticeTimer.restart()
    }

    function onItemFetchFailed(token, message) {
      if (token !== root.pendingToken) return
      root.pendingToken = ""
      root.say(message || "Could not read item", true)
      noticeTimer.restart()
    }

    function onItemsRefreshed() {
      if (root.opened) root.rebuild()
    }

    function onLockedOut(reason) {
      root.query = ""
      root.results = []
      root.selectedIndex = 0
      root.pendingToken = ""
      if (root.opened) root.say(reason === "expired" ? "Session expired" : "Locked", false)
    }
  }

  onOpenedChanged: {
    if (opened) {
      root.selectedIndex = 0
      root.notice = ""
      // Warm cache: this is a no-op and the list draws immediately. Cold: it
      // starts the chain, and onItemsRefreshed fills the list in.
      if (root.svc) root.svc.refresh()
      root.rebuild()
      Qt.callLater(function() {
        if (root.opened && root.unlocked) searchField.forceActiveFocus()
      })
    } else {
      // The field is the source of query (one-way, via onTextChanged), so
      // clearing the property alone would leave the last search sitting in the
      // box the next time the panel opens.
      searchField.text = ""
      root.query = ""
      root.results = []
      root.pendingToken = ""
      root.notice = ""
    }
  }

  onQueryChanged: root.rebuild()
  onItemsChanged: if (root.opened) root.rebuild()

  // Everything here filters metadata that is already in this process. Nothing
  // reads, fetches or copies a secret — a password still costs a keystroke on a
  // panel someone is looking at, which is the only place that decision belongs.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Open the dropdown with the search line already filled in, for a keybind
    // or a script that knows what you are looking for.
    function search(query: string): void {
      root.query = String(query || "")
      if (!root.opened) root.open()
      root.rebuild()
      Qt.callLater(function() {
        if (root.opened && root.unlocked) {
          searchField.text = root.query
          searchField.forceActiveFocus()
        }
      })
    }

    // Deliberately says nothing about *which* item is selected or what was
    // copied — only that a fetch is or is not outstanding.
    function status(): string {
      return JSON.stringify({
        status: root.status,
        items: root.items.length,
        results: root.results.length,
        query: root.query,
        opened: root.opened,
        pending: root.pendingToken !== "",
        notice: root.notice
      })
    }
  }

  function openOverlay() {
    root.close()
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function")
      root.bar.shell.summon(root.moduleName, "{}")
    else
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", root.moduleName])
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
        + " · left: quick copy · middle: full vault"
        + (root.lockOnRightClick && root.unlocked ? " · right: lock" : "")
      slotSize: Style.bar.statusSlot
      onPressed: function(b) {
        if (b === Qt.RightButton) {
          if (root.lockOnRightClick && root.unlocked && root.svc) root.svc.lock()
        } else if (b === Qt.MiddleButton) {
          root.openOverlay()
        } else {
          root.toggle()
        }
      }
    }

    Text {
      visible: root.showCount && root.unlocked && root.itemsLoaded && !root.vertical
      text: String(root.items.length)
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  readonly property bool vertical: root.bar ? root.bar.vertical === true : false

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: root.unlocked ? searchField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns every key while it has the caret, which is almost
      // always: this panel is a search box first.
      blocked: searchField.activeFocus

      onCloseRequested: root.close()
      onActivateRequested: if (!root.unlocked) root.openOverlay()

      Column {
        id: column
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Hero: what the vault is doing ------------------------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, lockButton.size)

          Text {
            id: heroIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.icon
            color: root.unlocked ? Color.accent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
          }

          // md-lock (0xF033E) — lock now, same op as right-clicking the icon.
          PanelActionButton {
            id: lockButton
            visible: root.unlocked
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰌾"
            tooltipText: "Lock the vault"
            foreground: root.foreground
            fontFamily: Style.font.family
            size: Style.space(24)
            bordered: true
            onClicked: if (root.svc) root.svc.lock()
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: (lockButton.visible ? lockButton.size + Style.space(12) : 0)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "BW Vault"
              color: root.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.statusText.toUpperCase()
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

        // ---------- Locked: nothing to search ----------------------------
        Column {
          visible: !root.unlocked
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width
            text: root.status === "unauthenticated"
              ? "Log in with your personal API key to use the vault."
              : root.status === "checking"
                ? "Checking the vault session…"
                : "The vault is locked. Unlocking needs your master password, which only the full vault window asks for."
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.status !== "checking"
            text: root.status === "unauthenticated" ? "Log in" : "Unlock"
            bordered: true
            foreground: root.foreground
            fontFamily: Style.font.family
            onClicked: root.openOverlay()
          }
        }

        // ---------- Unlocked: search and copy ----------------------------
        Column {
          visible: root.unlocked
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
            onAccepted: root.copyPassword()
            Keys.onPressed: function(event) {
              // Ctrl+U for the username: instant, because the metadata is
              // already here. Ctrl+O hands off to the full vault window.
              if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_U)) {
                root.copyUsername(); event.accepted = true
              } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_O)) {
                root.openOverlay(); event.accepted = true
              } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_L)) {
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
            visible: root.results.length === 0
            width: parent.width
            text: !root.itemsLoaded
              ? (root.busy ? "Loading the vault…" : "No items loaded")
              : (root.query !== "" ? "Nothing matches “" + root.query + "”" : "The vault is empty")
            color: root.fainter
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: root.notice !== ""
              ? root.notice
              : "enter copy · ctrl+u user · ctrl+l lock · ctrl+o vault"
            color: root.notice !== "" ? (root.noticeIsError ? Color.urgent : Color.accent) : root.fainter
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  // One vault entry: type glyph, name, username. No secret is in the model —
  // parseList() strips passwords before the list ever reaches a property.
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
          width: parent.width
          text: row.modelData.name || "(no name)"
          color: row.current ? Color.accent : row.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
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
        if (mouse.button === Qt.RightButton) root.copyUsername()
        else root.copyPassword()
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
