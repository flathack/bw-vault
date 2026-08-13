# BW Vault

A Bitwarden vault overlay for [Omarchy](https://omarchy.org/), powered by the official [`bw`](https://github.com/bitwarden/cli) CLI. Summon it over any app, search your vault, and copy usernames or passwords straight to the clipboard — without leaving your workflow.

Rewritten in Quickshell/QML from the [bw-tui](https://github.com/keboy/bw-tui) Bubble Tea TUI.

## Features

- **API key authentication** — authenticates with your [personal API key](https://bitwarden.com/help/personal-api-key/) (`bw login --apikey`) using `BW_CLIENTID`/`BW_CLIENTSECRET` in the child process environment, never argv. This avoids CLI-unsupported 2FA methods and the interactive new-device verification prompt.
- **Unlock screen** — client_id + client_secret on first login, then master password; once authenticated, only the master password is needed. The master password travels through the child process environment (`bw --passwordenv`), never argv.
- **Searchable item list** — type to filter, arrow keys / `j` `k` to move, Enter to open.
- **Item detail** — reveal password (`p`), copy username (`c`), copy password (`y`) via `wl-copy`.
- **Session persistence** — the session key is mirrored to the OS keyring (Secret Service via `secret-tool`), so the master password is asked for once per machine.
- **Lock** — `l` locks the vault and clears the stored session.
- **Native Omarchy theming** — built on `BorderSurface`, `Button`, `TextField`, and `Color.menu.*` tokens, so it matches your theme.

## Setup: personal API key

1. In the Bitwarden web app, go to **Settings → Security → Keys**.
2. Select **View API key** and enter your master password.
3. Note the `client_id` (format `user.xxxx`) and `client_secret`.
4. Enter them in the overlay's unlock screen the first time you log in. They are passed to `bw login --apikey` via the process environment, never argv or a stored file.

## Requirements

- Omarchy (Quickshell-based shell)
- [Bitwarden CLI](https://bitwarden.com/help/bitwarden-cli/) (`bw`)
- `wl-clipboard` (`wl-copy`)
- `libsecret` (`secret-tool`) — session persistence

```sh
# Arch / Omarchy
sudo pacman -S bitwarden-cli wl-clipboard libsecret
```

## Install

```sh
omarchy plugin add https://github.com/keboy/bw-vault.git --enable
```

Or without enabling right away:

```sh
omarchy plugin add https://github.com/keboy/bw-vault.git
omarchy plugin enable com.aktivesolutions.bw-vault
```

## Usage

Summon the overlay from a keybinding. Add to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + B", "Bitwarden vault", "omarchy-shell shell toggle com.aktivesolutions.bw-vault")
```

You can also summon it ad hoc:

```sh
omarchy-shell shell toggle com.aktivesolutions.bw-vault
```

### Keys

| Key | Action |
|-----|--------|
| `esc` | Close (or back / clear filter) |
| `enter` | Open item / unlock |
| `↑` `↓` / `j` `k` | Move through list |
| `type` | Filter items |
| `p` | Reveal password |
| `c` | Copy username |
| `y` | Copy password |
| `l` | Lock vault |

## Remove

```sh
omarchy plugin disable com.aktivesolutions.bw-vault
omarchy plugin remove com.aktivesolutions.bw-vault
```

## Security notes

- The client_id, client_secret, and master password are written only to the child process environment (`BW_CLIENTID`/`BW_CLIENTSECRET`/`BW_VAULT_MASTER_PASSWORD`), never to argv or any file.
- Item passwords are fetched on demand (`bw get item <id>`) and held in a single QML property that is cleared on close/lock.
- The session key is stored in the OS keyring via `secret-tool`. If that fails, the session is held in memory only.
- This plugin runs unsandboxed in your shell process, like all Omarchy plugins. Review the source before trusting it.

## Development

```sh
omarchy plugin validate .        # check the manifest
omarchy-shell shell toggle com.aktivesolutions.bw-vault   # summon for a live test
```

Plugin structure:

```
manifest.json      # plugin manifest (id: com.aktivesolutions.bw-vault)
Vault.qml          # overlay UI + Process lifecycle
VaultModel.js      # bw CLI command building + JSON parsing (pure JS)
```

## License

MIT — see [LICENSE](LICENSE).
