# FlatVault

FlatVault brings your Bitwarden vault to the Omarchy bar. Search entries, copy passwords and usernames, and see current TOTP codes without leaving your desktop.

![FlatVault search with demo entries](screenshot-list.png)

*Screenshot with demo data from `test/demo-vault.json`; no real credentials are shown.*

## Install

Requires Omarchy, the Bitwarden CLI (`bw`), `jq`, `secret-tool` (libsecret), Python 3 with `cryptography`, and `wl-clipboard`.

```sh
omarchy plugin add https://github.com/flathack/bw-vault.git --enable
```

Open FlatVault from the bar. If prompted, enter your Bitwarden personal API key from **Account Settings → Security → Keys → View API Key**, then unlock with your master password. Use the pencil on the unlock screen to add, edit, select or remove vault connections.

## Use

- Type to search; press **Enter** or click an entry to copy its password.
- Press **Ctrl+U** to copy the username, or **Ctrl+Enter** to open details.
- Current TOTP codes appear beside entries that have one. They require a connection to the vault.
- Right-click the bar icon to lock FlatVault.

After a successful online refresh, an encrypted offline copy allows password access during an outage while the system keyring is unlocked. TOTP codes are unavailable offline. See [SECURITY.md](SECURITY.md) for storage details.

The existing plugin ID and `bw-vault` commands remain unchanged so installed connections and credentials continue to work.

To try the interface with demo data, run `test/demo --unlocked`. Run `test/run` for the project checks.
