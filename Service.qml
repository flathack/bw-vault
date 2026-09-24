import QtQuick
import Quickshell
import Quickshell.Io
import "VaultModel.js" as VaultModel

// Vault session, owned by the shell rather than by any one view.
//
// Both views — the fullscreen overlay and the bar dropdown — are windows onto
// this object. It holds the session token, the item metadata, and every `bw`
// child process; they hold selection, focus, and pixels.
//
// Why a service at all: `bw` is a Node program, and a cold start costs ~4s on
// this machine. When the overlay owned the session, closing it dropped the
// item list, so every open paid that again. A dropdown you summon for one
// password cannot afford it. The list now survives between opens.
//
// What that buys is bounded on purpose:
//
//   * Only metadata is cached. A short-lived helper reduces `bw list` output to
//     names, usernames, ids, types and URIs before it enters this process.
//   * A password fetched by fetchItem() travels out through the itemFetched
//     signal and is never assigned to a property on this object. The requester
//     drops it when it is done.
//   * A TOTP seed never enters this process. fetchTotp() asks the CLI for only
//     the current code and clears its temporary buffer after emitting it.
//   * Credentials passed to unlock() go straight into a child's environment and
//     that environment is cleared the moment the child exits. They are never
//     stored here either.
//   * The metadata cache expires on idle (cacheTtlMinutes) and is dropped
//     outright on lock. The session token itself is unaffected — it lives in the
//     OS keyring, as it did before.
Item {
  id: service

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string pluginId: (manifest && manifest.id) || "com.aktivesolutions.bw-vault"
  // The host strips __sourceDir from the manifest passed to services. Resolve
  // from this QML file instead, so startup cannot stay on "Checking…" forever.
  readonly property string helperPath: decodeURIComponent(
    String(Qt.resolvedUrl("bin/bw-vault-query")).replace(/^file:\/\//, ""))
  readonly property string pluginPath: service.helperPath.slice(0, -"/bin/bw-vault-query".length)

  // Pushed in by the bar widget: the shell injects settings into widgets but
  // never into services, so the widget is the only place that sees them.
  property var settings: ({})

  function localCommand(args) {
    if (!args || !args.length) return args
    if (args[0] === "bw-vault-cli" || args[0] === "bw-vault-secret")
      return [service.pluginPath + "/bin/" + args[0]].concat(args.slice(1))
    return args
  }

  // -- observable state ------------------------------------------------------

  // "checking" | "unlocked" | "locked" | "unauthenticated"
  property string status: "checking"
  // "" | "login" | "unlock"
  property string authPhase: ""
  property bool busy: false
  property string error: ""
  property bool offline: false
  property bool cacheReady: false

  // Metadata only. See parseList() — no passwords pass through here.
  property var items: []
  property bool itemsLoaded: false

  readonly property bool hasSession: service.heldSession !== ""
  readonly property bool unlocked: service.status === "unlocked"
  readonly property bool fetching: getProc.running || totpProc.running

  // Session token. Held here so reads can skip the master password; mirrored to
  // the OS keyring so it also survives a shell restart.
  property string heldSession: ""

  // Whether a personal API key is already in the keyring. Only the flag is
  // kept — never the key itself. Drives whether the panel can offer an unlock
  // form at all, or has to send you to `bw-vault-setup` first.
  property bool apiKeyStored: false
  property bool apiKeySaving: false

  // The master password, in transit between the keyring lookup that unlock
  // needs and the child process that consumes it. This is the one secret that
  // briefly lands on this object, and it is cleared the instant unlock() is
  // called — see finishStoredUnlock(). It exists because the lookup is async
  // and there is nowhere else to park a value across it.
  property string pendingMaster: ""

  signal loginSucceeded()
  signal unlockSucceeded()
  signal itemsRefreshed()
  signal lockedOut(string reason)
  signal itemFetched(string token, var item, string password, bool fromCache)
  signal itemFetchFailed(string token, string message)
  signal totpFetched(string token, string code)
  signal totpFetchFailed(string token, string message)
  signal authFailed()
  signal apiKeySaved()
  signal apiKeySaveFailed(string message)

  // -- lifecycle -------------------------------------------------------------

  // Invalidates in-flight children. A `bw list` started before a lock must not
  // be allowed to repopulate the cache after it; comparing the generation it
  // was started in against the current one is what stops that. `opened` used to
  // serve this purpose, back when there was one view and it owned the state.
  property int generation: 0

  readonly property int cacheTtlMinutes: {
    var raw = Number(service.settings ? service.settings.cacheTtlMinutes : NaN)
    if (!isFinite(raw)) return 15
    return Math.max(0, Math.min(240, Math.round(raw)))
  }

  Component.onCompleted: {
    // The host injects the manifest immediately after createObject(). Defer the
    // first query one event-loop turn so helperPath is available before any
    // Bitwarden command can run.
    Qt.callLater(function() {
      apiKeyIdProbe.generation = service.generation
      apiKeyIdProbe.running = true
      service.refresh()
    })
  }

  // Bring the session up to date. Cheap when the cache is warm: a warm cache
  // means a live session, and re-listing would cost a cold start for nothing.
  function refresh(force) {
    if (service.unlocked) {
      if (!force && service.itemsLoaded) service.touch()
      else if (!listProc.running) service.loadItems(false)
      return
    }
    if (!force && (service.status === "locked" || service.status === "unauthenticated")) return
    if (service.busy) return
    service.error = ""
    service.status = "checking"
    service.busy = true
    sessionLookup.output = ""
    sessionLookup.generation = service.generation
    sessionLookup.running = true
  }

  // Reset the idle clock. Any view that is showing vault contents calls this,
  // so the cache expires on real idleness rather than on wall-clock age.
  function touch() {
    cacheTimer.stop()
    if (service.cacheTtlMinutes > 0 && service.itemsLoaded) cacheTimer.restart()
  }

  // Drop cached metadata but keep the session: the next open pays one `bw list`
  // and no master password. Used by the idle timer and by any view that wants a
  // guaranteed-fresh list.
  function forgetCache() {
    service.generation++
    service.items = []
    service.itemsLoaded = false
    service.cacheReady = false
    cacheTimer.stop()
  }

  // A connection change swaps the CLI data directory and keyring namespace.
  // Drop every reference to the previous vault before looking up the new one.
  function endpointChanged() {
    service.generation++
    for (var proc of [sessionLookup, statusProc, loginProc, unlockProc,
                      listProc, getProc, totpProc, apiKeyIdLookup,
                      apiKeySecretLookup, apiKeyIdProbe, apiKeySaveProc,
                      sessionStore]) {
      if (proc.running) proc.running = false
    }
    service.clearAuthEnvironment()
    service.clearSessionEnvironments()
    apiKeySaveProc.payload = ""
    copyProc.queuedPayload = ""
    service.requestClipboardClear()
    service.heldSession = ""
    service.items = []
    service.itemsLoaded = false
    service.cacheReady = false
    service.offline = false
    service.error = ""
    service.busy = false
    service.authPhase = ""
    service.apiKeyStored = false
    service.apiKeySaving = false
    cacheTimer.stop()
    service.lockedOut("switched")
    Qt.callLater(function() {
      apiKeyIdProbe.generation = service.generation
      apiKeyIdProbe.running = true
      service.refresh(true)
    })
  }

  function onSessionLookup(rawSession) {
    var candidate = String(rawSession || "").trim()
    if (candidate) {
      // Optimistic: a session out of the keyring is unverified, but listing
      // with it collapses verify-then-list into one cold start. A dead session
      // is diagnosed by the list failing, not by asking first.
      service.heldSession = candidate
      service.loadItems(true)
      return
    }
    service.heldSession = ""
    service.fetchGlobalStatus()
  }

  function fetchGlobalStatus() {
    service.status = "checking"
    service.busy = true
    statusProc.generation = service.generation
    statusProc.command = service.localCommand(VaultModel.statusCommand())
    statusProc.running = true
  }

  function onStatusOutput(raw) {
    var st = VaultModel.parseStatus(raw)
    if (!st) {
      service.error = "Vault unavailable. Reconnect or use a saved offline copy."
      service.loadItems(false)
      return
    }
    if (st.unlocked) {
      service.status = "unlocked"
      service.loadItems(false)
      return
    }
    // statusProc only ever runs without a session, so this is the final word.
    service.status = st.authenticated ? "locked" : "unauthenticated"
    service.busy = false
  }

  // -- unlock ----------------------------------------------------------------

  function storeApiKey(clientId, clientSecret) {
    if (apiKeySaveProc.running || !clientId || !clientSecret) return false
    service.error = ""
    service.apiKeySaving = true
    apiKeySaveProc.generation = service.generation
    apiKeySaveProc.payload = JSON.stringify({ clientId: clientId, clientSecret: clientSecret })
    apiKeySaveProc.stdinEnabled = true
    apiKeySaveProc.running = true
    return true
  }

  // Credentials arrive as arguments and leave through a child's environment.
  // Nothing is retained: see clearAuthEnvironment(), which runs on exit whether
  // the child succeeded or failed.
  function unlock(clientId, clientSecret, masterPassword) {
    if (service.busy && service.authPhase !== "") return
    service.error = ""
    service.busy = true

    if (service.status === "unauthenticated") {
      service.authPhase = "login"
      loginProc.command = service.localCommand(VaultModel.apikeyLoginCommand())
      loginProc.environment = VaultModel.apikeyLoginEnvironment(
        String(clientId || "").trim(), clientSecret, masterPassword)
      // Held only until the login child exits, so the unlock that follows a
      // successful login does not need the password passed in a second time.
      unlockProc.environment = VaultModel.passwordEnvironment(masterPassword)
      unlockProc.output = ""
      loginProc.generation = service.generation
      loginProc.running = true
      return
    }

    service.authPhase = "unlock"
    unlockProc.environment = VaultModel.passwordEnvironment(masterPassword)
    unlockProc.output = ""
    unlockProc.command = service.localCommand(VaultModel.unlockCommand())
    unlockProc.generation = service.generation
    unlockProc.running = true
  }

  // Unlock using the API key already in the keyring, so the panel only ever
  // has to ask for the master password. On a machine with no key stored this
  // is refused rather than half-attempted: `bw-vault-setup` is the way in.
  function unlockWithStored(masterPassword) {
    if (service.busy) return
    if (service.status !== "unauthenticated") {
      service.unlock("", "", masterPassword)
      return
    }
    if (!service.apiKeyStored) {
      service.error = "No API key stored — run bw-vault-setup"
      return
    }
    service.error = ""
    service.busy = true
    service.pendingMaster = masterPassword
    apiKeyIdLookup.generation = service.generation
    apiKeyIdLookup.running = true
  }

  function finishStoredUnlock(clientId, clientSecret) {
    var master = service.pendingMaster
    service.pendingMaster = ""
    if (!clientId || !clientSecret) {
      service.error = "Could not read the stored API key"
      service.busy = false
      service.authFailed()
      return
    }
    service.unlock(clientId, clientSecret, master)
  }

  function runUnlock() {
    service.authPhase = "unlock"
    unlockProc.output = ""
    unlockProc.command = service.localCommand(VaultModel.unlockCommand())
    unlockProc.generation = service.generation
    unlockProc.running = true
  }

  // The one place credentials stop existing. Quickshell keeps `environment`
  // alive for the lifetime of the Process object, so leaving it set would park
  // the master password in the (always-loaded) shell process until the next
  // unlock overwrote it.
  function clearAuthEnvironment() {
    loginProc.environment = ({})
    unlockProc.environment = VaultModel.nonInteractiveEnvironment()
    service.pendingMaster = ""
  }

  function clearSessionEnvironments() {
    listProc.environment = VaultModel.nonInteractiveEnvironment()
    getProc.environment = VaultModel.nonInteractiveEnvironment()
    totpProc.environment = VaultModel.nonInteractiveEnvironment()
    // A running lock child still needs the session snapshot it was launched
    // with. Its onExited handler clears this environment.
    if (!lockProc.running) lockProc.environment = VaultModel.nonInteractiveEnvironment()
  }

  function failAuthentication(message) {
    var raw = String(message || "")
    service.error = /502|503|504|ECONN|ENOTFOUND|ServerConfig|fetch failed/i.test(raw)
      ? "Vault server unavailable. Try the offline copy or reconnect."
      : (raw.split("\n")[0].slice(0, 180) || "Authentication failed")
    service.busy = false
    service.authPhase = ""
    service.clearAuthEnvironment()
    service.authFailed()
  }

  function onUnlockSuccess(rawSession) {
    var session = String(rawSession || "").trim()
    service.authPhase = ""
    service.clearAuthEnvironment()
    if (!session) {
      service.failAuthentication("Unlock did not return a session")
      return
    }
    service.heldSession = session
    service.status = "unlocked"
    // Mirror to the keyring (non-fatal). Snapshot onto the Process now: the
    // child starts asynchronously, and reading heldSession in onStarted would
    // write an empty session if a lock landed in between. stdin is re-opened so
    // the previous run's EOF has not left the write channel closed.
    sessionStore.payload = session
    sessionStore.clearAfterExit = false
    sessionStore.stdinEnabled = true
    sessionStore.running = true
    service.unlockSucceeded()
    service.loadItems(false)
  }

  // -- list ------------------------------------------------------------------

  // speculative: the session came straight from the keyring and is unverified,
  // so a failure means "that session is dead", not "show the user an error".
  function loadItems(speculative) {
    if (!service.helperPath) {
      service.error = "BW Vault helper path is unavailable"
      service.busy = false
      return
    }
    listProc.speculative = speculative === true
    listProc.generation = service.generation
    service.cacheReady = false
    service.busy = true
    service.error = ""
    listProc.command = VaultModel.listCommand(service.helperPath)
    listProc.environment = VaultModel.sessionEnvironment(service.heldSession)
    listProc.running = true
  }

  function onListOutput(raw) {
    // Items came back, so the session is good — this is what replaces the
    // `bw status` check on the speculative path.
    service.status = "unlocked"
    service.items = VaultModel.parseList(raw)
    service.itemsLoaded = true
    service.busy = false
    service.touch()
    service.itemsRefreshed()
  }

  // -- one item, with its password -------------------------------------------

  // The password is handed to the requester through the signal and is never
  // assigned to a property here. `token` lets a view ignore a fetch some other
  // view asked for.
  function fetchItem(id, token) {
    if (getProc.running) {
      service.itemFetchFailed(String(token || ""), "Another item is still loading")
      return false
    }
    if (!service.helperPath) {
      service.itemFetchFailed(String(token || ""), "BW Vault helper path is unavailable")
      return false
    }
    getProc.token = String(token || "")
    getProc.generation = service.generation
    getProc.output = ""
    getProc.command = VaultModel.getCommand(service.helperPath, id)
    var env = VaultModel.sessionEnvironment(service.heldSession)
    if (service.cacheReady && service.itemsLoaded && service.unlocked)
      env.BW_VAULT_CACHE_OK = "1"
    getProc.environment = env
    getProc.running = true
    return true
  }

  // Fetch only the current one-time code. The seed never leaves Bitwarden:
  // bin/bw-vault-query invokes `bw get totp` instead of exposing login.totp.
  function fetchTotp(id, token) {
    if (totpProc.running) {
      service.totpFetchFailed(String(token || ""), "Another one-time code is still loading")
      return false
    }
    if (!service.helperPath) {
      service.totpFetchFailed(String(token || ""), "BW Vault helper path is unavailable")
      return false
    }
    totpProc.token = String(token || "")
    totpProc.generation = service.generation
    totpProc.output = ""
    totpProc.errorOutput = ""
    totpProc.command = VaultModel.totpCommand(service.helperPath, id)
    totpProc.environment = VaultModel.sessionEnvironment(service.heldSession)
    totpProc.running = true
    return true
  }

  function cancelTotp(token) {
    if (!token || !totpProc.running || totpProc.token !== token) return
    // Let the in-flight child finish before this Process can be reused. Its
    // empty token makes the result disposable and avoids an old onExited
    // handler clearing a newer request's buffers.
    totpProc.token = ""
  }

  // -- lock ------------------------------------------------------------------

  function lock() {
    var startCliLock = !lockProc.running && (service.unlocked || service.heldSession !== "")
    var waitForCliLock = lockProc.running || startCliLock
    service.generation++
    if (apiKeyIdLookup.running) apiKeyIdLookup.running = false
    if (apiKeySecretLookup.running) apiKeySecretLookup.running = false
    if (loginProc.running) loginProc.running = false
    if (unlockProc.running) unlockProc.running = false
    apiKeySecretLookup.clientId = ""
    apiKeySecretLookup.output = ""
    unlockProc.output = ""
    if (listProc.running) listProc.running = false
    if (getProc.running) getProc.running = false
    if (totpProc.running) totpProc.running = false
    if (lockProc.running) {
      // A repeated lock request still waits for the already-running child.
      lockProc.generation = service.generation
    } else if (startCliLock) {
      lockProc.generation = service.generation
      lockProc.command = service.localCommand(VaultModel.lockCommand())
      lockProc.environment = VaultModel.sessionEnvironment(service.heldSession)
      lockProc.running = true
    }
    if (sessionStore.running) {
      // Do not let a just-completed unlock re-store its session after the
      // clear. Terminate the store and clear once its child has exited.
      sessionStore.clearAfterExit = true
      sessionStore.running = false
    } else {
      sessionClear.running = true
    }
    copyProc.queuedPayload = ""
    service.requestClipboardClear()
    service.heldSession = ""
    service.items = []
    service.itemsLoaded = false
    service.cacheReady = false
    cacheTimer.stop()
    service.status = "locked"
    service.offline = false
    service.error = ""
    service.busy = false
    service.authPhase = ""
    service.clearAuthEnvironment()
    service.clearSessionEnvironments()
    service.lockedOut("locked")
    // Querying before `bw lock` exits can observe the old unlocked state and
    // repopulate the cache after the user explicitly locked the vault.
    if (!waitForCliLock) service.fetchGlobalStatus()
  }

  // A session that turned out to be dead. Same teardown as lock(), minus the
  // `bw lock` call — there is nothing live to lock.
  function sessionDied() {
    service.generation++
    sessionClear.running = true
    service.heldSession = ""
    service.items = []
    service.itemsLoaded = false
    service.cacheReady = false
    cacheTimer.stop()
    service.clearSessionEnvironments()
    service.lockedOut("expired")
    service.fetchGlobalStatus()
  }

  // -- clipboard -------------------------------------------------------------

  property string clipboardDigest: ""

  function copyValue(text) {
    if (!text) return
    if (copyProc.running) {
      // Keep at most the newest requested value. It will start only after the
      // current clipboard source has exited, so payload and digest cannot refer
      // to different copies.
      copyProc.queuedPayload = text
      return
    }
    service.startCopy(text)
  }

  function startCopy(text) {
    copyProc.stdinEnabled = true
    copyProc.payload = text
    copyProc.running = true
    // Remember what we put there so the auto-wipe can recognise it later.
    service.clipboardDigest = Qt.md5(text)
    clipboardClearTimer.restart()
  }

  // Wipe the clipboard, but only if it still holds the value we put there.
  // `wl-copy --clear` is unconditional, so firing it blind would destroy
  // whatever the user copied in the meantime.
  function requestClipboardClear() {
    clipboardClearTimer.stop()
    if (!service.clipboardDigest) return
    clipboardRead.running = true
  }

  function onClipboardRead(raw, exitCode) {
    var digest = service.clipboardDigest
    service.clipboardDigest = ""
    if (exitCode !== 0 || !digest) return
    // md5sum prints "<32 hex>  -"; only the digest ever reaches this process.
    if (String(raw).slice(0, 32) !== digest) return
    clipboardClear.running = true
  }

  // -- idle cache expiry -----------------------------------------------------

  Timer {
    id: cacheTimer
    interval: Math.max(1, service.cacheTtlMinutes) * 60000
    repeat: false
    onTriggered: service.forgetCache()
  }

  // -- keyring ---------------------------------------------------------------

  Process {
    id: apiKeySaveProc
    property string payload: ""
    property int generation: 0
    command: [service.pluginPath + "/bin/bw-vault-storage", "store-key"]
    stdinEnabled: true
    stderr: StdioCollector { id: apiKeySaveErr; waitForEnd: true }
    onStarted: {
      write(payload + "\n")
      payload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      payload = ""
      stdinEnabled = false
      if (apiKeySaveProc.generation !== service.generation) return
      service.apiKeySaving = false
      if (exitCode === 0) {
        service.apiKeyStored = true
        service.error = ""
        service.apiKeySaved()
      } else {
        service.error = "Could not save API key to the system keyring"
        service.apiKeySaveFailed(service.error)
      }
    }
  }

  Process {
    id: sessionLookup
    property string output: ""
    property int generation: 0
    command: service.localCommand(VaultModel.sessionLookupCommand())
    stdout: SplitParser {
      onRead: function(line) { sessionLookup.output += String(line || "") }
    }
    onExited: {
      var value = sessionLookup.output
      var requestGeneration = sessionLookup.generation
      sessionLookup.output = ""
      if (requestGeneration === service.generation) service.onSessionLookup(value)
    }
  }

  Process {
    id: sessionStore
    // Snapshotted by the caller before running; see onUnlockSuccess.
    property string payload: ""
    property bool clearAfterExit: false
    command: service.localCommand(VaultModel.sessionStoreCommand())
    stdinEnabled: true
    onStarted: {
      write(payload + "\n")
      payload = ""
      // Close stdin so secret-tool sees EOF, stores the secret, and exits.
      // Quickshell's Process never closes the write channel on its own, so
      // without this the store would block forever and never persist.
      stdinEnabled = false
    }
    onExited: {
      // Also cover a child that failed before onStarted could consume it.
      payload = ""
      stdinEnabled = false
      if (clearAfterExit) {
        clearAfterExit = false
        sessionClear.running = true
      }
    }
  }

  Process {
    id: sessionClear
    command: service.localCommand(VaultModel.sessionClearCommand())
  }

  // The client id is not a secret, so it can be read at startup to answer "is
  // this machine set up?" without holding anything sensitive. The secret is
  // only ever read in the moment it is handed to `bw login`.
  Process {
    id: apiKeyIdProbe
    property int generation: 0
    command: service.localCommand(VaultModel.apiKeyIdLookupCommand())
    stdout: StdioCollector {
      id: apiKeyIdProbeOut
      waitForEnd: true
    }
    onExited: {
      if (apiKeyIdProbe.generation === service.generation)
        service.apiKeyStored = String(apiKeyIdProbeOut.text || "").trim() !== ""
    }
  }

  Process {
    id: apiKeyIdLookup
    property int generation: 0
    command: service.localCommand(VaultModel.apiKeyIdLookupCommand())
    stdout: StdioCollector {
      id: apiKeyIdLookupOut
      waitForEnd: true
    }
    onExited: {
      if (apiKeyIdLookup.generation !== service.generation) return
      apiKeySecretLookup.clientId = String(apiKeyIdLookupOut.text || "").trim()
      apiKeySecretLookup.output = ""
      apiKeySecretLookup.generation = apiKeyIdLookup.generation
      apiKeySecretLookup.running = true
    }
  }

  Process {
    id: apiKeySecretLookup
    property string clientId: ""
    property string output: ""
    property int generation: 0
    command: service.localCommand(VaultModel.apiKeySecretLookupCommand())
    stdout: SplitParser {
      onRead: function(line) { apiKeySecretLookup.output += String(line || "") }
    }
    onExited: {
      var id = apiKeySecretLookup.clientId
      var secret = apiKeySecretLookup.output
      var requestGeneration = apiKeySecretLookup.generation
      apiKeySecretLookup.clientId = ""
      apiKeySecretLookup.output = ""
      if (requestGeneration !== service.generation) return
      service.finishStoredUnlock(id, String(secret || "").trim())
    }
  }

  // -- bw --------------------------------------------------------------------

  Process {
    id: statusProc
    property int generation: 0
    environment: VaultModel.nonInteractiveEnvironment()
    stderr: StdioCollector {
      waitForEnd: true
    }
    stdout: StdioCollector {
      id: statusOut
      waitForEnd: true
    }
    onExited: {
      if (statusProc.generation === service.generation) service.onStatusOutput(statusOut.text)
    }
  }

  Process {
    id: loginProc
    property int generation: 0
    stderr: StdioCollector {
      id: loginErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var err = String(loginErr.text || "").trim()
      var requestGeneration = loginProc.generation
      if (requestGeneration !== service.generation) {
        loginProc.environment = ({})
        return
      }
      if (exitCode === 0) {
        service.error = ""
        // The API-key login leaves the vault locked; the unlock that follows
        // consumes the master password still sitting in unlockProc.environment.
        loginProc.environment = ({})
        service.loginSucceeded()
        service.runUnlock()
        return
      }
      service.failAuthentication(err || "Login failed")
    }
  }

  Process {
    id: unlockProc
    property string output: ""
    property int generation: 0
    environment: VaultModel.nonInteractiveEnvironment()
    stdout: SplitParser {
      onRead: function(line) { unlockProc.output += String(line || "") }
    }
    stderr: StdioCollector {
      id: unlockErr
      waitForEnd: true
    }
    onExited: function(exitCode) {
      var session = unlockProc.output
      var requestGeneration = unlockProc.generation
      unlockProc.output = ""
      if (requestGeneration !== service.generation) {
        unlockProc.environment = VaultModel.nonInteractiveEnvironment()
        return
      }
      if (exitCode === 0) service.onUnlockSuccess(session)
      else service.failAuthentication(String(unlockErr.text || "").trim() || "Unlock failed")
    }
  }

  Process {
    id: listProc
    property bool speculative: false
    property int generation: 0
    // Without this a dead session makes bw prompt for the master password
    // instead of exiting non-zero, and the speculative run never resolves.
    environment: VaultModel.nonInteractiveEnvironment()
    stdout: StdioCollector {
      id: listOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: listErr
      waitForEnd: true
    }
    // Decided here rather than on stream-finish because only the exit code can
    // tell a dead session from an empty vault.
    onExited: function(exitCode) {
      var raw = listOut.text
      var err = String(listErr.text || "").trim()
      var speculative = listProc.speculative
      var requestGeneration = listProc.generation
      listProc.environment = VaultModel.nonInteractiveEnvironment()
      // Started before a lock: whatever it found belongs to a session that no
      // longer exists.
      if (requestGeneration !== service.generation) return
      if (exitCode !== 0) {
        service.offline = false
        service.cacheReady = false
        if (err.indexOf("BW_VAULT_OFFLINE") !== -1) {
          service.status = "unavailable"
          service.error = "Vault unavailable and no offline copy is ready"
          service.busy = false
          return
        }
        if (speculative) {
          service.sessionDied()
          return
        }
        service.error = "Vault unavailable and no offline copy is ready"
        service.busy = false
        return
      }
      service.offline = err.indexOf("BW_VAULT_OFFLINE") !== -1
      service.cacheReady = err.indexOf("BW_VAULT_CACHE_FAILED") === -1
      service.error = service.offline ? "Using encrypted offline copy"
        : (err.indexOf("BW_VAULT_CACHE_FAILED") !== -1 ? "Offline copy could not be updated" : "")
      service.onListOutput(raw)
    }
  }

  Process {
    id: getProc
    property string token: ""
    property string output: ""
    property string errorOutput: ""
    property int generation: 0
    environment: VaultModel.nonInteractiveEnvironment()
    stdout: SplitParser {
      onRead: function(line) { getProc.output += String(line || "") }
    }
    stderr: SplitParser {
      onRead: function(line) { getProc.errorOutput += String(line || "") + "\n" }
    }
    onExited: function(exitCode) {
      var token = getProc.token
      var raw = getProc.output
      var err = String(getProc.errorOutput || "").trim()
      var requestGeneration = getProc.generation
      getProc.token = ""
      getProc.output = ""
      getProc.errorOutput = ""
      getProc.environment = VaultModel.nonInteractiveEnvironment()
      if (requestGeneration !== service.generation) return
      if (exitCode !== 0) {
        service.itemFetchFailed(token, "Item unavailable online or in the offline copy")
        return
      }
      if (err.indexOf("BW_VAULT_OFFLINE") !== -1) service.offline = true
      var item = VaultModel.parseItem(raw)
      if (!item) {
        service.itemFetchFailed(token, "Could not read item")
        return
      }
      var password = String(item.password || "")
      item.password = ""
      service.itemFetched(token, item, password,
        err.indexOf("BW_VAULT_CACHE_HIT") !== -1 || err.indexOf("BW_VAULT_OFFLINE") !== -1)
    }
  }

  Process {
    id: totpProc
    property string token: ""
    property string output: ""
    property string errorOutput: ""
    property int generation: 0
    environment: VaultModel.nonInteractiveEnvironment()
    stdout: SplitParser {
      onRead: function(line) { totpProc.output += String(line || "") }
    }
    stderr: SplitParser {
      onRead: function(line) { totpProc.errorOutput += String(line || "") + "\n" }
    }
    onExited: function(exitCode) {
      var token = totpProc.token
      var code = String(totpProc.output || "").trim()
      var err = String(totpProc.errorOutput || "").trim()
      var requestGeneration = totpProc.generation
      totpProc.token = ""
      totpProc.output = ""
      totpProc.errorOutput = ""
      totpProc.environment = VaultModel.nonInteractiveEnvironment()
      if (!token) return
      if (requestGeneration !== service.generation) return
      if (exitCode !== 0 || !code) {
        service.totpFetchFailed(token, err || "Could not read one-time code")
        return
      }
      service.totpFetched(token, code)
    }
  }

  Process {
    id: lockProc
    property int generation: 0
    environment: VaultModel.nonInteractiveEnvironment()
    onExited: {
      var requestGeneration = lockProc.generation
      lockProc.environment = VaultModel.nonInteractiveEnvironment()
      if (requestGeneration === service.generation) service.fetchGlobalStatus()
    }
  }

  // -- clipboard processes ---------------------------------------------------

  Process {
    id: copyProc
    property string payload: ""
    property string queuedPayload: ""
    command: ["wl-copy", "--sensitive"]
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
      // Close stdin so wl-copy sees EOF, copies, and exits. Otherwise the
      // process leaks and keeps the clipboard source pipe open.
      stdinEnabled = false
    }
    onExited: {
      payload = ""
      if (!queuedPayload) return
      var next = queuedPayload
      queuedPayload = ""
      Qt.callLater(function() { service.startCopy(next) })
    }
  }

  // Reads the clipboard back so the wipe can confirm it still holds our value.
  // The output is hashed in the pipeline rather than in QML: a StdioCollector's
  // text is read-only, so collecting the raw clipboard would park the plaintext
  // password in the shell process — the exact retention this avoids. Only the
  // digest crosses over.
  Process {
    id: clipboardRead
    command: ["sh", "-c", "wl-paste --no-newline | md5sum"]
    stdout: StdioCollector {
      id: clipboardReadOut
      waitForEnd: true
    }
    onExited: function(exitCode) { service.onClipboardRead(clipboardReadOut.text, exitCode) }
  }

  Process {
    id: clipboardClear
    command: ["wl-copy", "--clear"]
  }

  Timer {
    id: clipboardClearTimer
    interval: 20000
    onTriggered: service.requestClipboardClear()
  }

  // Live introspection for debugging: `omarchy-shell com.aktivesolutions.bw-vault state`
  IpcHandler {
    target: "com.aktivesolutions.bw-vault"

    function state(): string {
      return JSON.stringify({
        status: service.status,
        authPhase: service.authPhase,
        busy: service.busy,
        session: service.heldSession ? "yes" : "no",
        apiKeyStored: service.apiKeyStored,
        items: service.items.length,
        itemsLoaded: service.itemsLoaded,
        cacheReady: service.cacheReady,
        cacheTtlMinutes: service.cacheTtlMinutes,
        generation: service.generation,
        error: service.error
      })
    }

    function refresh(): void { service.refresh(true) }
    function lock(): void { service.lock() }
    function forget(): void { service.forgetCache() }
  }
}
