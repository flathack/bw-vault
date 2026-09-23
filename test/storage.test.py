#!/usr/bin/env python3
"""Exercise isolated endpoints and encrypted offline reads using fixture tools."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
from cryptography.fernet import Fernet

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="bw-vault-storage-test-") as tmp:
    base = Path(tmp)
    fixture = base / "fixture"
    fixture.mkdir()
    (fixture / "unlocked").touch()
    (fixture / "authed").touch()
    legacy = base / "config/Bitwarden CLI/data.json"
    legacy.parent.mkdir(parents=True)
    legacy.write_text(json.dumps({"global_environment_environment": {"urls": {"base": "https://old.example.test"}}}))
    env = dict(os.environ, XDG_STATE_HOME=str(base / "state"), XDG_CONFIG_HOME=str(base / "config"),
               BW_FIXTURE_STATE=str(fixture),
               PATH=str(root / "test/fixtures") + ":" + os.environ["PATH"])

    def run(*args, offline=False):
        result = subprocess.run(args, env=dict(env, BW_FIXTURE_OFFLINE="1" if offline else "0"),
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        return result.stdout

    initial = json.loads(run(str(root / "bin/bw-vault-storage"), "list"))
    assert initial["endpoints"][0]["url"] == "https://old.example.test"
    run("secret-tool", "store", "service", "com.aktivesolutions.bw-vault", "account", "bw-session")
    run(str(root / "bin/bw-vault-endpoints"), "update", "default", "Main", "https://new.example.test")
    cleared = subprocess.run(["secret-tool", "lookup", "service", "com.aktivesolutions.bw-vault",
                              "account", "bw-session"], env=env, capture_output=True)
    assert cleared.returncode != 0
    assert json.loads(legacy.read_text())["global_environment_environment"]["urls"]["base"] == "https://old.example.test"
    assert json.loads((base / "state/bw-vault/cli/default/data.json").read_text())["global_environment_environment"]["urls"]["base"] == "https://new.example.test"
    ident = run(str(root / "bin/bw-vault-endpoints"), "add", "NAS", "https://vault.example.test").strip()
    online = json.loads(run(str(root / "bin/bw-vault-query"), "list"))
    cache = base / "state/bw-vault" / ("cache-" + ident + ".enc")
    assert cache.exists()
    assert b"demo-not-a-real-password" not in cache.read_bytes()
    secret = run("secret-tool", "lookup", "service", "com.aktivesolutions.bw-vault",
                 "account", "offline-cache-" + ident).strip().encode()
    decrypted = Fernet(secret).decrypt(cache.read_bytes())
    assert b"totp-must-not-survive" not in decrypted
    assert b"hidden-field-must-not-survive" not in decrypted
    assert json.loads(run(str(root / "bin/bw-vault-query"), "list", offline=True)) == online
    locked = subprocess.run([str(root / "bin/bw-vault-query"), "list"],
                            env=dict(env, BW_FIXTURE_LOCKED="1"), capture_output=True)
    assert locked.returncode != 0
    run(str(root / "bin/bw-vault-endpoints"), "select", "default")
    missing = subprocess.run([str(root / "bin/bw-vault-query"), "list"],
                             env=dict(env, BW_FIXTURE_OFFLINE="1"), capture_output=True)
    assert missing.returncode != 0
    run(str(root / "bin/bw-vault-endpoints"), "select", ident)
    item = online[0]["id"]
    assert json.loads(run(str(root / "bin/bw-vault-query"), "get", item, offline=True))["id"] == item
    run("secret-tool", "store", "service", "com.aktivesolutions.bw-vault",
        "account", "bw-session-" + ident)
    run(str(root / "bin/bw-vault-endpoints"), "update", ident, "NAS new", "https://other.example.test")
    assert not cache.exists()
    cleared = subprocess.run(["secret-tool", "lookup", "service", "com.aktivesolutions.bw-vault",
                              "account", "bw-session-" + ident], env=env, capture_output=True)
    assert cleared.returncode != 0
    assert json.loads((base / "state/bw-vault/cli" / ident / "data.json").read_text())["global_environment_environment"]["urls"]["base"] == "https://other.example.test"
    run(str(root / "bin/bw-vault-endpoints"), "remove", ident)
    assert not cache.exists()
    assert not (base / "state/bw-vault/cli" / ident).exists()

print("Endpoint and offline cache tests passed")
