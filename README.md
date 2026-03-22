# CWRU VPN Split-Tunneler for macOS

A shell utility for macOS that manages [openfortivpn](https://github.com/adrienverge/openfortivpn) connections with split-tunneling. Only CWRU traffic (`129.22.0.0/16`) goes through the VPN; everything else stays on your normal ISP at full speed.

**Last updated: March 21, 2026**

## Prerequisites

- **macOS** and **Zsh**
- **openfortivpn**: `brew install openfortivpn`
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
4. **Install sudoers rules**: The background monitor needs passwordless sudo for routing commands. Run the built-in setup:
    ```bash
    vpn --setup
    ```
5. **(Optional) Keychain credentials**: Ensure your CWRU credentials are saved in the macOS Keychain under the label **`CaseWireless`**. If you connect to campus Wi-Fi (CaseWireless) with your CWRU Network ID, this is already done automatically.

## Usage

> **Note:** This utility requires Zsh. Bash is not supported.

| Command | Description |
|---------|-------------|
| `vpn` | Connect to the VPN in split-tunnel mode. |
| `dvpn` | Disconnect and restore default routing. |
| `vpn --setup` | Install the required passwordless sudo rules to `/etc/sudoers.d/vpn`. |

Every new connection requires TOTP verification. At the prompt:
- **Auto-read clipboard**: Copy a 6-digit code and the script picks it up automatically (120s timeout).
- **Manual entry**: Type the code and press **Enter**.
- **Duo Push**: Press **Enter** without typing anything.

Credentials auto-fill from Keychain. If not found, you will be prompted to enter them manually.

## How It Works

### Routing

The script launches openfortivpn with `set-routes=0` and `set-dns=0`, taking full control of routing and DNS. Only traffic destined for `129.22.0.0/16` is routed through the VPN interface. All other traffic bypasses the VPN entirely. IPv6 is disabled on Wi-Fi while the VPN is active to prevent tunnel bypass.

A background monitor watches for route changes using event-driven `route -n monitor` (with a periodic fallback check) and automatically repairs routing if macOS resets it (e.g., after a network switch).

### DNS

Scoped macOS resolvers are created for `case.edu`, `cwru.edu`, and `22.129.in-addr.arpa` (reverse PTR), directing CWRU-related DNS queries to university nameservers. All other DNS queries use your default resolver.

### Security

- Credentials are read from macOS Keychain and written to a `chmod 600` temporary file that is destroyed immediately after connection, with trap-based cleanup on failure.
- All credential variables (`VPN_PASS`, `VPN_USER`, `TOTP`) are explicitly unset from shell memory after use.
- The VPN connection is protected by standard TLS certificate validation against the system trust store.
- Route integrity is continuously monitored and auto-repaired.

## Known Limitations

- **DNS multi-path leakage**: Due to macOS's multi-path DNS resolution, `case.edu` forward queries may also be sent to your default DNS resolver simultaneously. Your ISP can see that you queried a CWRU hostname, but cannot see the resolved IP (it receives NXDOMAIN) or any subsequent traffic (encrypted through the VPN tunnel).
- **Sudoers scope**: The sudoers rules grant broad NOPASSWD access to `/sbin/route -n add *` and `/sbin/route -n delete *`. macOS sudoers does not support finer-grained argument matching for `route`.
- **Clipboard monitoring**: The TOTP clipboard monitor polls `pbpaste` for up to 120 seconds. During this window, clipboard contents are read (but not stored or transmitted) to detect 6-digit codes.
- **Password on disk**: `openfortivpn` requires a config file for credentials. The password is briefly written to a `chmod 600` temp file and deleted immediately after use. This is a limitation of `openfortivpn` not supporting stdin-based password input.

---

**Disclaimer**: This is an unofficial community tool. Use at your own risk. Ensure compliance with CWRU's Acceptable Use Policy.
