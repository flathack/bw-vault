// VaultModel.js — Backing logic for the BW Vault overlay.
//
// Talks to the official `bw` CLI the way bw-tui did: reads go through the
// CLI, and the session token is kept in memory and mirrored to the OS keyring
// (Secret Service via secret-tool) so the master password is only needed
// once per machine.
//
// This file is pure JS. The QML side owns all Process lifecycle; the model
// only builds commands and parses output. Secrets (master password, session
// token, item passwords) only ever live in QML properties / process
// environment, never in this module.

.pragma library

const KEYRING_SERVICE = "com.aktivesolutions.bw-vault"
const KEYRING_ACCOUNT = "bw-session"
const PASSWORD_ENV = "BW_VAULT_MASTER_PASSWORD"

// buildCommand(args, session) — a `bw` invocation. A held session is appended
// as --session so reads work without re-entering the master password. login /
// unlock are excluded because they establish the session rather than use it.
function buildCommand(args, session, useSession) {
  var full = ["bw"].concat(args || [])
  if (useSession && session) {
    full.push("--session", session)
  }
  return full
}

// Process `environment` map. The master password travels through the child's
// environment (bw --passwordenv) instead of argv, so it never shows up in
// process listings or shell history.
function passwordEnvironment(password) {
  var env = ({})
  env[PASSWORD_ENV] = String(password || "")
  return env
}

// -- Session persistence -----------------------------------------------------
//
// secret-tool is the Secret Service CLI on Arch (libsecret). Storing the
// Bitwarden session mirrors what the desktop app does with the OS keyring.
// Failures are non-fatal: a session that cannot be persisted is simply held
// in memory for the process lifetime.

function sessionStoreCommand() {
  return ["secret-tool", "store", "--label=bw-vault session", "service", KEYRING_SERVICE, "account", KEYRING_ACCOUNT]
}

function sessionLookupCommand() {
  return ["secret-tool", "lookup", "service", KEYRING_SERVICE, "account", KEYRING_ACCOUNT]
}

function sessionClearCommand() {
  return ["secret-tool", "clear", "service", KEYRING_SERVICE, "account", KEYRING_ACCOUNT]
}

// -- Commands ----------------------------------------------------------------

// statusCommand(session) — true status; a bogus session just reports
// unauthenticated, which is exactly what an expired token should mean.
function statusCommand(session) {
  return buildCommand(["status"], session, true)
}

// Two-factor login. Email (method 1) is used because the CLI can send the
// verification email itself and complete the login with --code, which the
// GUI can surface as an input box. A first call without a code sends the
// email and fails with "Code is required."; the flow then re-runs with the
// user's code. No TTY is available under Quickshell, so non-interactive mode
// is forced — otherwise the CLI would hang on its interactive prompt.
function loginCommand(email, code, useSession) {
  var args = ["login", email, "--passwordenv", PASSWORD_ENV, "--method", "1"]
  if (code) args = args.concat(["--code", String(code)])
  return buildCommand(args, "", false)
}

// Environment for login: keep the master password off argv and force
// non-interactive mode so the CLI never waits on a TTY prompt.
function loginEnvironment(password) {
  var env = passwordEnvironment(password)
  env.BW_NOINTERACTION = "true"
  return env
}

function unlockCommand() {
  return buildCommand(["unlock", "--passwordenv", PASSWORD_ENV, "--raw"], "", false)
}

function listCommand(session) {
  return buildCommand(["list", "items"], session, true)
}

function getCommand(id, session) {
  return buildCommand(["get", "item", id], session, true)
}

function lockCommand(session) {
  return buildCommand(["lock"], session, true)
}

// -- Output parsing ----------------------------------------------------------

// bw status JSON: { serverUrl, lastSync, status: "unauthenticated"|"locked"|"unlocked" }
function parseStatus(raw) {
  var st = null
  try { st = JSON.parse(raw) } catch (e) { return null }
  if (!st || typeof st.status !== "string") return null
  return {
    authenticated: st.status !== "unauthenticated",
    locked: st.status === "locked",
    unlocked: st.status === "unlocked"
  }
}

var ITEM_TYPES = {
  "1": "login",
  "2": "secureNote",
  "3": "card",
  "4": "identity"
}

function itemTypeName(type) {
  return ITEM_TYPES[String(type)] || "item"
}

// Strip secrets from list output: the list view never carries passwords.
function parseList(raw) {
  var arr = null
  try { arr = JSON.parse(raw) } catch (e) { return [] }
  if (!Array.isArray(arr)) return []
  var out = []
  for (var i = 0; i < arr.length; i++) {
    var it = arr[i]
    if (!it || typeof it !== "object") continue
    var login = it.login || {}
    var uris = []
    if (Array.isArray(login.uris)) {
      for (var j = 0; j < login.uris.length; j++) {
        var u = login.uris[j]
        if (u && u.uri) uris.push(u.uri)
      }
    }
    out.push({
      id: String(it.id || ""),
      name: String(it.name || ""),
      username: String(login.username || ""),
      type: itemTypeName(it.type),
      notes: String(it.notes || ""),
      uris: uris
    })
  }
  return out
}

// Detail read includes the password; callers must drop it after use.
function parseItem(raw) {
  var it = null
  try { it = JSON.parse(raw) } catch (e) { return null }
  if (!it || typeof it !== "object") return null
  var login = it.login || {}
  var uris = []
  if (Array.isArray(login.uris)) {
    for (var j = 0; j < login.uris.length; j++) {
      var u = login.uris[j]
      if (u && u.uri) uris.push(u.uri)
    }
  }
  return {
    id: String(it.id || ""),
    name: String(it.name || ""),
    username: String(login.username || ""),
    password: String(login.password || ""),
    type: itemTypeName(it.type),
    notes: String(it.notes || ""),
    uris: uris
  }
}

function matchesQuery(item, query) {
  var q = String(query || "").toLowerCase().trim()
  if (!q) return true
  return String(item.name).toLowerCase().indexOf(q) !== -1
    || String(item.username).toLowerCase().indexOf(q) !== -1
}
