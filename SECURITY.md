# Security policy

BW Vault handles credentials inside the always-running Omarchy shell process.
Treat every source change and dependency update as security-sensitive.

## Supported version

Only the latest tagged release is supported. Install an immutable release tag
when stability matters; do not pin a password manager integration to a moving
branch.

## Security model

- The official Bitwarden CLI remains the vault and cryptography boundary.
- A short-lived helper allowlists fields from `bw list` and `bw get` before QML
  receives their JSON. TOTP seeds remain inside Bitwarden; QML receives only a
  presence flag and codes calculated by `bw get totp` on demand.
- Secrets use child-process environments or stdin instead of command-line
  arguments. Reusable credentials and sessions are stored through Secret
  Service (`secret-tool`).
- Item reads are serialized and invalidated when the session generation
  changes. Temporary output and environment properties are cleared on exit.
- Credential clipboard writes carry the Wayland sensitive-data hint and a
  compare-before-clear timeout.
- Vault-controlled text is rendered as plain text.

This is defense in depth, not process isolation: Omarchy plugins run
unsandboxed in the shell process. A compromised plugin or same-user process can
still access data available to that user. QML/JavaScript strings also cannot be
reliably zeroized; clearing temporary properties removes references and bounds
their useful lifetime, but garbage-collected memory may retain old bytes.

## Reporting

Do not include real credentials, vault exports or session tokens in a report.
Open an issue with redacted reproduction steps, or contact the repository owner
privately when public disclosure would expose users before a fix is available.

## Release checks

Every release must pass `test/run`. GitHub Actions are pinned to immutable
commit SHAs, and the release tag must point at the tested commit.
