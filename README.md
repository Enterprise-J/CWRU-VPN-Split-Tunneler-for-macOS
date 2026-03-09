# CWRU VPN Split-Tunneler for macOS

A secure, custom shell utility for macOS that manages [openfortivpn](https://github.com/adrienverge/openfortivpn) connections with intelligent split-tunneling. Only CWRU traffic (`129.22.x.x`) goes through the VPN; everything else stays on your normal ISP at full speed, preserving your privacy and bandwidth.

**Last updated: March 8, 2026**

## Prerequisites

- **macOS** and **Z Shell (Zsh)** (use `networksetup`, `security`, `scutil`, `swiftc`, `pbpaste`, and `&!`)
- **openfortivpn**: `brew install openfortivpn`
- **Sudo Privileges** — [enabling TouchID for sudo](https://dev.to/siddhantkcode/enable-touch-id-authentication-for-sudo-on-macos-sonoma-14x-4d28) is highly recommended.

## Installation & Setup

1. **Save the script** somewhere permanent (e.g., `~/scripts/split_tunnel.sh`).
2. **Add the following line** to your `~/.zshrc`:
    ```bash
    source ~/scripts/split_tunnel.sh
    ```
3. **Reload your shell**:
    ```bash
    source ~/.zshrc
    ```
4. **Configure Sudoers**: The background VPN monitor needs permission to manage routing without pausing to ask for a password. Run the built-in setup command to generate the necessary security rules:
    ```bash
    vpn --setup
    ```
5. **(Optional) Keychain credentials**: Ensure your CWRU credentials are saved in the macOS Keychain under the label **`CaseWireless`**. If you connect to the campus WiFi (CaseWireless) with your CWRU Network ID, this is already done automatically.

## Usage

> **Note:** There is no `bash` support; this utility is for `zsh` only.

| Command | Description |
|---------|-------------|
| `vpn` | Connect to the VPN in secure split-tunnel mode. |
| `dvpn` | Disconnect, gracefully clean up routes, and restore defaults. |
| `vpn --setup` | Output the required `/etc/sudoers.d/` rules for installation. |

Every new connection requires a TOTP verification. At the TOTP prompt, you have a few options:
- **Auto-read clipboard**: Simply copy a 6-digit code, and the script will automatically read it.
- **Manual entry**: Type your TOTP code manually and press **Enter**.
- **Duo Push**: Press **Enter** without typing anything to receive a Duo Push.

Your credentials will auto-fill securely from Keychain; if they don’t appear, the script will prompt you to enter your Network ID and passphrase manually.

## How It Works

### Routing
The script launches openfortivpn with `--set-routes=0` and manages all routing locally. Only traffic destined for `129.22.0.0/16` is routed through the VPN interface. All other web traffic bypasses the VPN entirely.

### Privacy
Scoped macOS DNS resolvers (`/etc/resolver/case.edu` and `cwru.edu`) are generated securely. This ensures that **only** CWRU domain queries go to university nameservers. All other DNS queries use your local ISP, keeping your personal browsing invisible to the university network.

### Security
Unlike default `openfortivpn` implementations, this script never exposes your password to the system process list. Credentials are dynamically written to a strictly permissioned (`chmod 600`) temporary file, passed to the client, and immediately destroyed.

---

**Disclaimer**: This is an unofficial community tool. Use at your own risk. Ensure compliance with CWRU's Acceptable Use Policy.
