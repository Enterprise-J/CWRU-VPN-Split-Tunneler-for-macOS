# CWRU VPN Split-Tunneler for macOS

A shell utility for macOS that manages [openfortivpn](https://github.com/adrienverge/openfortivpn) connections with split-tunneling. Only CWRU traffic (`129.22.0.0/16`) goes through the VPN; everything else stays on your normal ISP at full speed.

**Last updated: March 31, 2026**

## Prerequisites

- **macOS** and **Zsh**
- **openfortivpn**: `brew install openfortivpn`
- **Python 3**: Required for local TOTP code generation (ships with macOS).
- **Sudo privileges** — [enabling TouchID for sudo](https://dev.to/siddhantkcode/enable-touch-id-authentication-for-sudo-on-macos-sonoma-14x-4d28) is highly recommended.

## Installation & Setup

1. **Save the script** somewhere permanent (e.g., `~/scripts/split_tunnel.sh`).
2. **Source it** in your `~/.zshrc`:
    ```bash
    source ~/scripts/split_tunnel.sh
    ```
3. **Reload your shell**:
    ```bash
    source ~/.zshrc
    ```
4. **Install sudoers rules and configure TOTP**: Run the built-in setup:
    ```bash
    vpn --setup
    ```
    This does two things:

    **Sudoers rules** — Generates passwordless sudo rules for the routing, DNS, and network commands the script needs, validates them with `visudo -c`, and installs them to `/etc/sudoers.d/vpn`. Without these, the background route monitor cannot repair routing silently; you would be prompted for your password or the repair would fail.

    **TOTP secret (optional)** — Prompts you to paste your TOTP secret. This can be either a raw base32 string or a full `otpauth://totp/...` URI (the kind encoded in a QR code). The script validates the secret by generating a test code, then stores it in macOS Keychain under the service name `CaseWireless TOTP`. On subsequent `vpn` connections, the code is generated locally and appended to your password automatically — no manual entry, clipboard watching, or Duo Push needed. Press Enter to skip if you prefer the interactive TOTP flow.

    You can re-run `vpn --setup` at any time to update the sudoers rules or replace the stored TOTP secret.
5. **(Optional) Keychain credentials**: Ensure your CWRU credentials are saved in the macOS Keychain under the label **`CaseWireless`**. If you connect to campus Wi-Fi (CaseWireless) with your CWRU Network ID, this is already done automatically.

## Usage

> **Note:** This utility requires Zsh. Bash is not supported.

| Command | Description |
|---------|-------------|
| `vpn` | Connect to the VPN in split-tunnel mode. |
| `dvpn` | Disconnect and restore default routing. |
| `vpn --setup` | Install sudoers rules and optionally store a TOTP secret in Keychain. |

### TOTP Authentication

If a TOTP secret is stored in Keychain (via `vpn --setup`), codes are generated automatically at connect time — no manual entry or Duo interaction needed.

If no stored secret is available, the script falls back to the interactive prompt:
- **Auto-read clipboard**: Copy a 6-digit code and the script picks it up automatically (120s timeout).
- **Manual entry**: Type the code and press **Enter**.
- **Duo Push**: Press **Enter** without typing anything.

Credentials auto-fill from Keychain. If not found, you will be prompted to enter them manually.

## How It Works

### Routing

The script launches openfortivpn with `set-routes=0` and `set-dns=0`, taking full control of routing and DNS. Only traffic destined for `129.22.0.0/16` is routed through the VPN interface. All other traffic bypasses the VPN entirely. IPv6 is disabled on the active network service while the VPN is active to prevent tunnel bypass.

A background monitor watches for route changes using event-driven `route -n monitor` (with a periodic fallback check) and automatically repairs routing if macOS resets it (e.g., after a network switch).

### DNS

Scoped macOS resolvers are created for `case.edu`, `cwru.edu`, and `22.129.in-addr.arpa` (reverse PTR), directing CWRU-related DNS queries to university nameservers. All other DNS queries use your default resolver.

### Security

- Credentials are read from macOS Keychain and written to a `chmod 600` temporary file that is destroyed immediately after connection, with trap-based cleanup on failure.
- All credential variables (`VPN_PASS`, `VPN_USER`, `TOTP`, `TOTP_SECRET`) are explicitly unset from shell memory after use.
- The TOTP secret is stored in macOS Keychain (service `CaseWireless TOTP`) and never written to disk.
- Temporary directory cleanup validates the path matches an expected pattern before deletion, preventing accidental removal of unrelated directories.
- The VPN connection is protected by standard TLS certificate validation against the system trust store.
- Route integrity is continuously monitored and auto-repaired.
- On startup, the script checks whether the required sudoers rules are installed and warns if they are missing.

### Network Service Detection

IPv6 toggling and disconnect cleanup now dynamically detect the active network service (e.g., Wi-Fi, Ethernet, USB) from the physical interface, rather than assuming Wi-Fi. This allows correct operation when connected via Ethernet or other adapters.

### Disconnect Recovery

On disconnect, if connectivity cannot be restored, the script performs targeted route cleanup (removing split-tunnel routes and re-adding the default gateway) instead of flushing the entire routing table. This avoids disrupting unrelated routes or interfaces.

## Changes from Previous Version

- **Local TOTP generation**: A TOTP secret can be stored in Keychain during `vpn --setup`. Codes are generated locally via Python 3 HMAC-SHA1, eliminating the need for manual entry or Duo Push on every connection. Supports both raw base32 secrets and `otpauth://` URIs.
- **Dynamic network service detection**: IPv6 disable/enable and sudoers rules no longer hardcode `Wi-Fi`. The active network service is resolved from the physical interface at runtime, supporting Ethernet and other adapters.
- **Safer temp directory cleanup**: `_vpn_cleanup_tmp_dir` now validates `VPN_TMP_DIR` against an expected path pattern before running `rm -rf`.
- **Safer disconnect recovery**: `dvpn` no longer calls `route -n flush` (which nukes the entire routing table). Instead, it performs targeted route deletions and re-adds the default gateway.
- **Sudoers validation at connect**: `vpn` checks for the required sudoers rules and prints a warning if they are not installed.
- **Keychain abstraction**: Credential and TOTP secret lookups are factored into dedicated helper functions (`_vpn_get_saved_user`, `_vpn_get_totp_secret`, `_vpn_store_totp_secret`) with fallback between `find-internet-password` and `find-generic-password`.
- **Removed `route -n flush` from sudoers**: No longer needed since disconnect recovery uses targeted cleanup.

## Known Limitations

- **DNS multi-path leakage**: Due to macOS's multi-path DNS resolution, `case.edu` forward queries may also be sent to your default DNS resolver simultaneously. Your ISP can see that you queried a CWRU hostname, but cannot see the resolved IP (it receives NXDOMAIN) or any subsequent traffic (encrypted through the VPN tunnel).
- **Sudoers scope**: The sudoers rules grant broad NOPASSWD access to `/sbin/route -n add *` and `/sbin/route -n delete *`. macOS sudoers does not support finer-grained argument matching for `route`. Similarly, `networksetup -setv6off *` and `-setv6automatic *` use wildcards.
- **Clipboard monitoring**: When no TOTP secret is stored, the TOTP clipboard monitor polls `pbpaste` for up to 120 seconds. During this window, clipboard contents are read (but not stored or transmitted) to detect 6-digit codes.
- **Password on disk**: `openfortivpn` requires a config file for credentials. The password is briefly written to a `chmod 600` temp file and deleted immediately after use. This is a limitation of `openfortivpn` not supporting stdin-based password input.

---

**Disclaimer**: This is an unofficial community tool. Use at your own risk. Ensure compliance with CWRU's Acceptable Use Policy.
