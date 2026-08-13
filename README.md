# BW Vault

A Bitwarden vault overlay for [Omarchy](https://omarchy.org/), powered by the official [`bw`](https://github.com/bitwarden/cli) CLI. Summon it over any app, search your vault, and copy usernames or passwords straight to the clipboard — without leaving your workflow.

Rewritten in Quickshell/QML from the [bw-tui](https://github.com/keboy/bw-tui) Bubble Tea TUI.

## Screenshots

Unlock screen · searchable vault list:

![Unlock screen](screenshot-unlock.png)

![Vault list](screenshot-vault.png)

## Features

- **API key authentication** — authenticates with your [personal API key](https://bitwarden.com/help/personal-api-key/) (`bw login --apikey`) using `BW_CLIENTID`/`BW_CLIENTSECRET` in the child process environment, never argv. The API key is an alternative auth path that doesn't require interactive 2FA at login time and bypasses the new-device verification prompt.
- **Unlock screen** — client_id + client_secret on first login (then kept in the OS keyring), master password each time; once authenticated, only the master password is needed. The master password travels through the child process environment (`bw --passwordenv`), never argv.
- **Floating unlock card** — while the API key is still needed, the overlay shrinks to a small card you can drag out of the way, and it stops grabbing the keyboard, so you can copy the key from your browser and paste it back without closing the overlay.
- **Searchable item list** — type to filter, arrow keys / `j` `k` to move, Enter to open.
- **Item detail** — reveal password (`p`), copy username (`c`), copy password (`y`) via `wl-copy`.
- **Session persistence** — the session key is mirrored to the OS keyring (Secret Service via `secret-tool`), so the master password is asked for once per machine when the keyring is available.
- **Lock** — `l` locks the vault and clears the stored session.
- **Native Omarchy theming** — built on `BorderSurface`, `Button`, `TextField`, and `Color.menu.*` tokens, so it matches your theme.

### Scope

This is a quick-access overlay, not a full vault manager. It reads and copies items only — it doesn't create, edit, or delete items, and it doesn't cover attachments, organizations/collections, or multiple accounts. Use the official apps for those.

## Setup: personal API key

1. In the Bitwarden web app, go to **Settings → Security → Keys**.
2. Select **View API key** and enter your master password.
3. Note the `client_id` (format `user.xxxx`) and `client_secret`.
4. Enter them in the overlay's unlock screen the first time you log in. They are passed to `bw login --apikey` via the process environment and then stored in your OS keyring.

### Stored in your OS keyring

The overlay keeps the personal API key in the OS keyring (the same Secret Service entry your session uses). You paste the `client_id` / `client_secret` into the unlock screen when you first set it up — and again if you rotate the key in the Bitwarden web app. On every other open the overlay pre-fills them from the keyring and only asks for the master password; a rotated key is stored the next time you log in.

## Requirements

- Omarchy (Quickshell-based shell)
- A `wlr-layer-shell`-compatible Wayland compositor (Omarchy's Hyprland, Sway, etc.) — not X11
- [Bitwarden CLI](https://bitwarden.com/help/bitwarden-cli/) (`bw`)
- `wl-clipboard` (`wl-copy`)
- `libsecret` (`secret-tool`) — session and API key persistence

```sh
# Arch / Omarchy
sudo pacman -S bitwarden-cli wl-clipboard libsecret
```

## Install

```sh
omarchy plugin add https://github.com/alkevintan/bw-vault.git --enable
```

Or without enabling right away:

```sh
omarchy plugin add https://github.com/alkevintan/bw-vault.git
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
| `drag card` | Move the floating unlock card (while entering the API key) |
| `enter` | Open item / unlock |
| `↑` `↓` / `j` `k` | Move through list |
| `type` | Filter items |
| `p` | Reveal password |
| `c` | Copy username |
| `y` | Copy password |
| `l` | Lock vault |

## Troubleshooting

- `bw: command not found` → install the [Bitwarden CLI](https://bitwarden.com/help/bitwarden-cli/).
- `secret-tool: command not found` → install `libsecret`.
- The overlay doesn't appear when summoned → confirm the plugin is enabled: `omarchy plugin list`.
- The floating card won't take a paste from the browser → click into the card's field first; if the compositor still keeps keyboard focus on the card (`WlrKeyboardFocus.OnDemand` quirk), close and reopen the overlay.

## Known issues

- `WlrKeyboardFocus.OnDemand` can occasionally retain keyboard focus on some compositors, so the browser may not take keystrokes while the floating card is open.
- If the OS keyring daemon is not running, the session and API key are held in memory only and lost when the shell restarts.

## Remove

```sh
omarchy plugin disable com.aktivesolutions.bw-vault
omarchy plugin remove com.aktivesolutions.bw-vault
```

## Security notes

- The client_id and client_secret are passed to `bw login --apikey` via the child process environment and stored in your OS keyring via `secret-tool`, never in a plaintext file in your home directory. The master password only ever lives in the child process environment (`BW_VAULT_MASTER_PASSWORD`), never argv or a file.
- Item passwords are fetched on demand (`bw get item <id>`) and held in a single QML property that is cleared on close/lock.
- The session key is stored in the OS keyring via `secret-tool`. If that fails, the session is held in memory only.
- This plugin runs unsandboxed in your shell process, like all Omarchy plugins. It has access to your session and can run arbitrary commands. Review the source before trusting it.

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
