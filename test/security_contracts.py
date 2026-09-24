#!/usr/bin/env python3

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
service = (ROOT / "Service.qml").read_text()
widget = (ROOT / "BarWidget.qml").read_text()
model = (ROOT / "VaultModel.js").read_text()
helper = (ROOT / "bin" / "bw-vault-query").read_text()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(
    'command: ["wl-copy", "--sensitive"]' in service,
    "credential copies must carry wl-copy --sensitive",
)
require('apiKeySaveProc.payload = JSON.stringify' in service and
        'apiKeySaveProc.stdinEnabled = true' in service and
        'payload = ""' in service,
        "API key setup must pass credentials on stdin and clear its payload")
require('clientSecretField.text = ""' in widget,
        "API key form must clear the client secret")
require('Qt.resolvedUrl("bin/bw-vault-query")' in service,
        "helper path must resolve from Service.qml, not a stripped manifest field")

text_blocks = len(re.findall(r"^\s*Text \{", widget, re.MULTILINE))
plain_text_guards = widget.count("textFormat: Text.PlainText")
require(text_blocks == plain_text_guards, "every QML Text block must force PlainText")

require("if (getProc.running)" in service, "fetchItem must reject overlapping requests")
require(
    "signal itemFetched(string token, var item, string password, bool fromCache)" in service,
    "password must travel separately from cached item metadata",
)
require(
    "signal totpFetched(string token, string code)" in service,
    "TOTP codes must travel separately from item metadata",
)

require(
    "onScreenChanged: {" in widget and
    "root.focusCurrentScreen(); root.refreshListTotp()" in widget,
    "screen changes must explicitly transfer keyboard focus",
)
require(
    'if (root.screen === "detail") keyCatcher.forceActiveFocus()' in widget,
    "detail shortcuts require PanelKeyCatcher focus",
)
require(
    'blocked: root.screen !== "detail" &&' in widget,
    "a stale hidden-field focus must not block detail keys",
)

for forbidden_collector in ("sessionLookupOut", "apiKeySecretLookupOut", "getOut"):
    require(forbidden_collector not in service, f"secret collector remains: {forbidden_collector}")

parse_list = model.split("function parseList", 1)[1].split("function parseItem", 1)[0]
require("notes:" not in parse_list, "list cache must not retain notes")
require("password:" not in parse_list, "list cache must not retain passwords")

require(
    'buildCommand(["list", "items"])' not in model,
    "raw list query must stay in short-lived helper",
)
require(
    'buildCommand(["get", "item"' not in model,
    "raw item query must stay in short-lived helper",
)
require("bw-vault-cli list items" in helper, "helper must minimize list output before QML")
require("bw-vault-cli get item \"$2\"" in helper, "helper must minimize detail output before QML")
require('bw-vault-cli get totp "$2"' in helper, "TOTP must be calculated by the Bitwarden CLI")
require(
    "password: (.login.password" in helper and "hasTotp:" in helper,
    "detail helper must expose only a TOTP presence flag, never map the seed",
)
require(
    "totp: (.login.totp" not in helper,
    "TOTP seed must never be mapped into helper output",
)

for process_name in ("listProc", "getProc", "totpProc", "lockProc"):
    require(
        f"{process_name}.environment = VaultModel.nonInteractiveEnvironment()" in service,
        f"{process_name} must clear its BW_SESSION environment",
    )

require(
    'if (!waitForCliLock) service.fetchGlobalStatus()' in service,
    "lock must not query status until the CLI lock child exits",
)
require(
    "if (requestGeneration === service.generation) service.fetchGlobalStatus()" in service,
    "the lock child must refresh status only for the active generation",
)
require(
    "property bool clearAfterExit: false" in service and "sessionStore.clearAfterExit = true" in service,
    "locking must serialize session-store termination before keyring clear",
)

require(
    'if (err.indexOf("BW_VAULT_OFFLINE") !== -1)' in service and
    'service.status = "unavailable"' in service and
    'root.status === "unavailable"' in widget,
    "a network outage without a cache must preserve the session and show unavailable",
)
require(
    'if (root.screen === "detail") root.leaveDetail()' in widget and
    'root.pendingToken = ""' in widget.split('function leaveDetail()', 1)[1].split('// -- filtering', 1)[0],
    "list refresh must clear detail secrets and pending detail requests",
)
require(
    'if (!force && (service.status === "locked" || service.status === "unauthenticated")) return' in service and
    'root.screen === "unlock" ? "Retry vault connection"' in widget,
    "reopening a settled locked vault must be cheap and offer an explicit retry",
)
require(
    'root.clearListTotp()' in widget and
    'if (root.screen !== "list") root.clearListTotp()' in widget and
    'if (!root.unlocked) root.clearListTotp()' in widget,
    "list TOTP codes must clear when the panel, screen, or session changes",
)

print("Security contract tests passed")
