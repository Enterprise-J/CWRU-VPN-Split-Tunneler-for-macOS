VPN_TMP_DIR_FILE="$HOME/.vpn_tmp_dir"
VPN_KEYCHAIN_LABEL="CaseWireless"
VPN_TOTP_KEYCHAIN_SERVICE="CaseWireless TOTP"
VPN_TOTP_KEYCHAIN_LABEL="CaseWireless TOTP"

_vpn_ensure_tmp_dir() {
    if [ -n "$VPN_TMP_DIR" ] && [ -d "$VPN_TMP_DIR" ]; then
        return 0
    fi
    if [ -f "$VPN_TMP_DIR_FILE" ]; then
        VPN_TMP_DIR=$(cat "$VPN_TMP_DIR_FILE")
        [ -d "$VPN_TMP_DIR" ] && return 0
    fi
    VPN_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vpn_XXXXXX")
    chmod 700 "$VPN_TMP_DIR"
    echo "$VPN_TMP_DIR" > "$VPN_TMP_DIR_FILE"
}

_vpn_cleanup_tmp_dir() {
    if [ -n "$VPN_TMP_DIR" ] && [ -d "$VPN_TMP_DIR" ]; then
        local tmp_root=${TMPDIR:-/tmp}
        tmp_root=${tmp_root%/}
        case "$VPN_TMP_DIR" in
            "$tmp_root"/vpn_*|/tmp/vpn_*|/var/folders/*/vpn_*)
                rm -rf "$VPN_TMP_DIR"
                ;;
            *)
                echo "Warning: VPN_TMP_DIR '$VPN_TMP_DIR' does not match expected pattern. Skipping cleanup."
                ;;
        esac
    fi
    rm -f "$VPN_TMP_DIR_FILE"
    unset VPN_TMP_DIR
}

_vpn_get_saved_user() {
    local saved_user
    saved_user=$(security find-internet-password -l "$VPN_KEYCHAIN_LABEL" 2>/dev/null | awk -F'=' '/"acct"<blob>/ {print $2}' | tr -d '"')
    if [ -n "$saved_user" ]; then
        printf '%s' "$saved_user"
        return 0
    fi

    saved_user=$(security find-generic-password -l "$VPN_KEYCHAIN_LABEL" 2>/dev/null | awk -F'=' '/"acct"<blob>/ {print $2}' | tr -d '"')
    [ -n "$saved_user" ] || return 1
    printf '%s' "$saved_user"
}

_vpn_get_totp_secret() {
    local totp_secret
    totp_secret=$(security find-generic-password -s "$VPN_TOTP_KEYCHAIN_SERVICE" -w 2>/dev/null)
    if [ -n "$totp_secret" ]; then
        printf '%s' "$totp_secret"
        return 0
    fi

    totp_secret=$(security find-generic-password -l "$VPN_TOTP_KEYCHAIN_LABEL" -w 2>/dev/null)
    [ -n "$totp_secret" ] || return 1
    printf '%s' "$totp_secret"
}

_vpn_store_totp_secret() {
    local totp_secret=$1
    local account_name=$2

    [ -n "$totp_secret" ] || return 1
    [ -n "$account_name" ] || account_name="${USER:-vpn}"

    security add-generic-password \
        -U \
        -a "$account_name" \
        -s "$VPN_TOTP_KEYCHAIN_SERVICE" \
        -l "$VPN_TOTP_KEYCHAIN_LABEL" \
        -w "$totp_secret" >/dev/null 2>&1
}

_vpn_generate_totp() {
    local totp_secret=$1
    local py_exec
    local code

    [ -n "$totp_secret" ] || return 1

    py_exec=$(command -v python3 2>/dev/null)
    [ -n "$py_exec" ] || return 1

    code=$(printf '%s' "$totp_secret" | "$py_exec" -c '
import base64
import hashlib
import hmac
import struct
import sys
import time
import urllib.parse

raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)

if raw.startswith("otpauth://"):
    parsed = urllib.parse.urlparse(raw)
    query = urllib.parse.parse_qs(parsed.query)
    raw = query.get("secret", [""])[0].strip()
    digits = int(query.get("digits", ["6"])[0])
    period = int(query.get("period", ["30"])[0])
    algorithm = query.get("algorithm", ["SHA1"])[0].upper()
else:
    digits = 6
    period = 30
    algorithm = "SHA1"

if not raw:
    raise SystemExit(1)

normalized = raw.replace(" ", "").replace("-", "").upper()
normalized += "=" * (-len(normalized) % 8)
key = base64.b32decode(normalized, casefold=True)
digestmod = getattr(hashlib, algorithm.lower(), None)
if digestmod is None:
    raise SystemExit(1)

counter = int(time.time()) // period
msg = struct.pack(">Q", counter)
digest = hmac.new(key, msg, digestmod).digest()
offset = digest[-1] & 0x0F
code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % (10 ** digits)
print(f"{code:0{digits}d}")
' 2>/dev/null)

    [ -n "$code" ] || return 1
    printf '%s' "$code"
}

_vpn_get_info() {
    VPN_IFACE=$(ifconfig -l | tr ' ' '\n' | grep '^ppp' | head -n 1)
    if [ -n "$VPN_IFACE" ]; then
        VPN_IP=$(ifconfig "$VPN_IFACE" 2>/dev/null | awk '/inet / {print $2}')
        [ -n "$VPN_IP" ] && return 0
    fi
    VPN_IP=$(ifconfig -a | awk '/^[a-z]/{iface=""} /^utun/{iface=$1} iface && /inet / && /10\.3\.0\./{print $2; exit}')
    [ -z "$VPN_IP" ] && return 1
    VPN_IFACE=$(ifconfig | grep -B 2 "$VPN_IP" | grep -oE "utun[0-9]+" | head -n 1)
    [ -z "$VPN_IFACE" ] && return 1
    return 0
}

_vpn_get_phys_info() {
    GATEWAY=$(route -n get default 2>/dev/null | grep 'gateway:' | awk '{print $2}')
    PHYS_IFACE=$(route -n get default 2>/dev/null | grep 'interface:' | awk '{print $2}')
    if [[ "$PHYS_IFACE" =~ utun ]] || [[ "$PHYS_IFACE" =~ ppp ]]; then
        local pg=$(netstat -nrf inet | awk '/^default/ && !/utun/ && !/ppp/ {print $2}' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -n "$pg" ]; then
            GATEWAY="$pg"
            PHYS_IFACE=$(route -n get "$pg" 2>/dev/null | grep 'interface:' | awk '{print $2}')
        fi
    fi
    if [[ "$PHYS_IFACE" =~ utun ]] || [[ "$PHYS_IFACE" =~ ppp ]] || [ -z "$GATEWAY" ]; then
        echo "Error: Could not determine a non-VPN gateway."
        return 1
    fi
    return 0
}

_vpn_flush_dns() {
    sudo /usr/sbin/dscacheutil -flushcache 2>/dev/null
    sudo /usr/bin/killall -HUP mDNSResponder 2>/dev/null
}

_vpn_get_network_service() {
    local iface=$1
    /usr/sbin/networksetup -listallhardwareports 2>/dev/null | awk -v dev="$iface" '
        /Hardware Port:/ { port=$0; sub(/Hardware Port: /, "", port) }
        /Device: / && $2 == dev { print port; exit }
    '
}

_vpn_apply_network_config() {
    local gw=$1 iface=$2 phys_iface=$3
    local network_service

    _vpn_ensure_tmp_dir

    sudo /sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
    sudo /sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
    sudo /sbin/route -n delete -net 129.22.0.0/16 >/dev/null 2>&1

    dig +short +time=2 +tries=1 vpn2.case.edu | grep '^[0-9]' > "$VPN_TMP_DIR/server_ips"
    for ip in $(cat "$VPN_TMP_DIR/server_ips" 2>/dev/null); do
        sudo /sbin/route -n delete -host "$ip" >/dev/null 2>&1
    done

    sudo /sbin/route -n add -net 0.0.0.0/1 "$gw" >/dev/null 2>&1
    sudo /sbin/route -n add -net 128.0.0.0/1 "$gw" >/dev/null 2>&1

    local DNS_SERVERS=($(grep "ns \[" "$VPN_TMP_DIR/openfortivpn.log" 2>/dev/null | grep -oE "ns \[[^]]+\]" | grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" | grep -v "0.0.0.0"))
    if [ ${#DNS_SERVERS[@]} -eq 0 ] && [ -f /etc/resolver/case.edu ]; then
        DNS_SERVERS=($(awk '/nameserver/ {print $2}' /etc/resolver/case.edu 2>/dev/null))
    fi
    local keepalive=""
    if [ ${#DNS_SERVERS[@]} -gt 0 ]; then
        sudo /bin/mkdir -p /etc/resolver
        local i=0
        for domain in case.edu cwru.edu; do
            for server in "${DNS_SERVERS[@]}"; do
                [ -z "$keepalive" ] && keepalive="$server"
                if [ $i -eq 0 ]; then
                    echo "nameserver $server" | sudo /usr/bin/tee /etc/resolver/$domain > /dev/null
                else
                    echo "nameserver $server" | sudo /usr/bin/tee -a /etc/resolver/$domain > /dev/null
                fi
                ((i++))
            done
            echo "domain $domain" | sudo /usr/bin/tee -a /etc/resolver/$domain > /dev/null
            echo "search_order 1" | sudo /usr/bin/tee -a /etc/resolver/$domain > /dev/null
            i=0
        done
        i=0
        for server in "${DNS_SERVERS[@]}"; do
            if [ $i -eq 0 ]; then
                echo "nameserver $server" | sudo /usr/bin/tee /etc/resolver/22.129.in-addr.arpa > /dev/null
            else
                echo "nameserver $server" | sudo /usr/bin/tee -a /etc/resolver/22.129.in-addr.arpa > /dev/null
            fi
            ((i++))
        done
    fi
    [ -z "$keepalive" ] && keepalive="pioneer.case.edu"

    sudo /sbin/route -n add -net 129.22.0.0/16 -interface "$iface" >/dev/null 2>&1

    network_service=$(_vpn_get_network_service "$phys_iface")
    if [ -z "$network_service" ]; then
        network_service="Wi-Fi"
        echo "Warning: Could not determine active network service for interface '$phys_iface'. Falling back to Wi-Fi." >&2
    fi
    sudo /usr/sbin/networksetup -setv6off "$network_service" 2>/dev/null

    echo "$keepalive"
}

_vpn_compile_menu_helper() {
    killall CWRUVPNMenu 2>/dev/null
    local APP_DIR="$HOME/.cwru_vpn_menu"
    local APP_PATH="$APP_DIR/CWRUVPNMenu"
    
    if [ ! -f "$APP_PATH" ]; then
        mkdir -p "$APP_DIR"
        _vpn_ensure_tmp_dir
        cat <<'EOF' > "$VPN_TMP_DIR/VPNStatus.swift"
import Cocoa
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button { 
            button.title = "🔒"
            button.toolTip = "CWRU VPN"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "CWRU VPN", action: nil, keyEquivalent: ""))
        statusItem.menu = menu
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
EOF
        swiftc "$VPN_TMP_DIR/VPNStatus.swift" -o "$APP_PATH" 2>/dev/null
    fi
}

_vpn_stop_monitor() {
    _vpn_ensure_tmp_dir

    if [ -f "$VPN_TMP_DIR/monitor.pid" ]; then
        local pid=$(cat "$VPN_TMP_DIR/monitor.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$VPN_TMP_DIR/monitor.pid"
    fi

    if [ -f "$VPN_TMP_DIR/fallback.pid" ]; then
        local pid=$(cat "$VPN_TMP_DIR/fallback.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$VPN_TMP_DIR/fallback.pid"
    fi

    if [ -f "$VPN_TMP_DIR/route_mon.pid" ]; then
        local pid=$(cat "$VPN_TMP_DIR/route_mon.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$VPN_TMP_DIR/route_mon.pid"
    fi

    if [ -f "$VPN_TMP_DIR/caffeinate.pid" ]; then
        local pid=$(cat "$VPN_TMP_DIR/caffeinate.pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$VPN_TMP_DIR/caffeinate.pid"
    fi

    if [ -f "$VPN_TMP_DIR/gui.pid" ]; then
        kill $(cat "$VPN_TMP_DIR/gui.pid") 2>/dev/null
        rm -f "$VPN_TMP_DIR/gui.pid"
    fi

    killall CWRUVPNMenu 2>/dev/null
}

_vpn_monitor() {
    local TARGET_IP=$1 KEEPALIVE_IP=$2 VPN_IFACE=$3

    "$HOME/.cwru_vpn_menu/CWRUVPNMenu" 2>/dev/null &
    local GUI_PID=$!
    echo $GUI_PID > "$VPN_TMP_DIR/gui.pid"

    caffeinate -i 2>/dev/null &
    local CAFF_PID=$!
    echo $CAFF_PID > "$VPN_TMP_DIR/caffeinate.pid"

    local FALLBACK_PID="" ROUTE_MON_PID=""

    _mon_cleanup() {
        kill $GUI_PID 2>/dev/null
        kill $CAFF_PID 2>/dev/null
        [ -n "$FALLBACK_PID" ] && kill $FALLBACK_PID 2>/dev/null
        [ -n "$ROUTE_MON_PID" ] && kill $ROUTE_MON_PID 2>/dev/null
        exec 3<&- 2>/dev/null
        rm -f "$VPN_TMP_DIR/route_fifo"
        rm -f "$VPN_TMP_DIR/monitor.pid" "$VPN_TMP_DIR/caffeinate.pid" "$VPN_TMP_DIR/gui.pid" "$VPN_TMP_DIR/fallback.pid" "$VPN_TMP_DIR/route_mon.pid"
    }
    trap _mon_cleanup EXIT

    _mon_check_and_repair() {
        if ! ifconfig | grep -q "$TARGET_IP"; then
            osascript -e 'display alert "CWRU VPN" message "VPN Connection Dropped." as critical' >/dev/null 2>&1 &
            touch "$VPN_TMP_DIR/vpn_dropped"
            return 1
        fi
        if ! netstat -nrf inet | grep -q "129\.22.*$VPN_IFACE"; then
            local GATEWAY PHYS_IFACE
            if _vpn_get_phys_info 2>/dev/null && [ -n "$GATEWAY" ] && [ -n "$VPN_IFACE" ]; then
                sudo /sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
                sudo /sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
                sudo /sbin/route -n add -net 0.0.0.0/1 "$GATEWAY" >/dev/null 2>&1
                sudo /sbin/route -n add -net 128.0.0.0/1 "$GATEWAY" >/dev/null 2>&1
                sudo /sbin/route -n add -net 129.22.0.0/16 -interface "$VPN_IFACE" >/dev/null 2>&1
                echo "$GATEWAY" > "$VPN_TMP_DIR/gateway"
                _vpn_flush_dns
            fi
        fi
        return 0
    }

    sleep 5

    {
        while true; do
            if [ -n "$KEEPALIVE_IP" ]; then
                ping -c 1 -W 2 "$KEEPALIVE_IP" >/dev/null 2>&1 &
            fi
            _mon_check_and_repair || break
            sleep 30 & wait $!
        done
    } &
    FALLBACK_PID=$!
    echo $FALLBACK_PID > "$VPN_TMP_DIR/fallback.pid"

    mkfifo "$VPN_TMP_DIR/route_fifo" 2>/dev/null
    route -n monitor > "$VPN_TMP_DIR/route_fifo" 2>/dev/null &
    ROUTE_MON_PID=$!
    echo $ROUTE_MON_PID > "$VPN_TMP_DIR/route_mon.pid"

    exec 3< "$VPN_TMP_DIR/route_fifo"

    while true; do
        if [ -f "$VPN_TMP_DIR/vpn_dropped" ]; then
            rm -f "$VPN_TMP_DIR/vpn_dropped"
            exec 3<&-
            _mon_cleanup
            trap - EXIT
            dvpn
            return 0
        fi
        if read -r -t 1 line <&3 2>/dev/null; then
            _mon_check_and_repair || {
                rm -f "$VPN_TMP_DIR/vpn_dropped"
                exec 3<&-
                _mon_cleanup
                trap - EXIT
                dvpn
                return 0
            }
        fi
    done
}
vpn() {
    for arg in "$@"; do
        case "$arg" in
            -h|--help)
                echo "Usage: vpn [--setup | -h]"
                return 0
                ;;
            --setup)
                local OFV_PATH
                local SETUP_VPN_USER TOTP_SECRET
                OFV_PATH=$(command -v openfortivpn 2>/dev/null)
                [ -z "$OFV_PATH" ] && [ -f /opt/homebrew/bin/openfortivpn ] && OFV_PATH="/opt/homebrew/bin/openfortivpn"
                [ -z "$OFV_PATH" ] && OFV_PATH="/usr/local/bin/openfortivpn"
                local TMP_SUDOERS
                TMP_SUDOERS=$(mktemp "${TMPDIR:-/tmp}/vpn_sudoers.XXXXXX")

                cat <<EOF > "$TMP_SUDOERS"
$(whoami) ALL=(ALL) NOPASSWD: /sbin/route -n add *
$(whoami) ALL=(ALL) NOPASSWD: /sbin/route -n delete *
$(whoami) ALL=(ALL) NOPASSWD: $OFV_PATH
$(whoami) ALL=(ALL) NOPASSWD: /usr/sbin/dscacheutil -flushcache
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/killall -HUP mDNSResponder
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/killall openfortivpn
$(whoami) ALL=(ALL) NOPASSWD: /bin/mkdir -p /etc/resolver
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/resolver/case.edu
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/tee -a /etc/resolver/case.edu
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/resolver/cwru.edu
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/tee -a /etc/resolver/cwru.edu
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/tee /etc/resolver/22.129.in-addr.arpa
$(whoami) ALL=(ALL) NOPASSWD: /usr/bin/tee -a /etc/resolver/22.129.in-addr.arpa
$(whoami) ALL=(ALL) NOPASSWD: /bin/rm -f /etc/resolver/case.edu /etc/resolver/cwru.edu /etc/resolver/22.129.in-addr.arpa
$(whoami) ALL=(ALL) NOPASSWD: /usr/sbin/networksetup -setv6off *
$(whoami) ALL=(ALL) NOPASSWD: /usr/sbin/networksetup -setv6automatic *
EOF

                if sudo visudo -c -f "$TMP_SUDOERS" >/dev/null 2>&1; then
                    sudo /bin/mkdir -p /etc/sudoers.d
                    sudo cp "$TMP_SUDOERS" /etc/sudoers.d/vpn
                    sudo chmod 440 /etc/sudoers.d/vpn
                else
                    echo "Error: Generated sudoers rules failed validation. Setup aborted."
                    rm -f "$TMP_SUDOERS"
                    return 1
                fi
                rm -f "$TMP_SUDOERS"

                if [ -t 0 ]; then
                    SETUP_VPN_USER=$(_vpn_get_saved_user 2>/dev/null)
                    [ -n "$SETUP_VPN_USER" ] || SETUP_VPN_USER="${USER:-vpn}"

                    printf "TOTP secret (optional; paste otpauth://... or raw base32, Enter to skip): "
                    read -r TOTP_SECRET
                    TOTP_SECRET=$(printf '%s' "$TOTP_SECRET" | tr -d '\r')

                    if [ -n "$TOTP_SECRET" ]; then
                        if _vpn_generate_totp "$TOTP_SECRET" >/dev/null 2>&1; then
                            if _vpn_store_totp_secret "$TOTP_SECRET" "$SETUP_VPN_USER"; then
                                echo "Stored TOTP secret in macOS Keychain for runtime code generation."
                            else
                                echo "Warning: Could not store the TOTP secret in macOS Keychain."
                            fi
                        else
                            echo "Error: Invalid TOTP secret. Not saved."
                        fi
                    else
                        echo "Skipped TOTP Keychain update. Run 'vpn --setup' later if you want to add it."
                    fi
                fi
                return 0
                ;;
            *) return 1 ;;
        esac
    done

    sudo -v 2>/dev/null || return 1
    if ! sudo -n -l /sbin/route -n add 0.0.0.0 0.0.0.0 >/dev/null 2>&1; then
        echo "Warning: sudoers rules not installed. Run 'vpn --setup' first. Background route repair may fail silently."
    fi

    _vpn_ensure_tmp_dir

    local VPN_IP VPN_IFACE GATEWAY PHYS_IFACE VPN_PASS VPN_USER TOTP TOTP_SECRET

    if _vpn_get_info; then
        if ! _vpn_get_phys_info; then
            return 1
        fi
        [ -z "$GATEWAY" ] || [ -z "$VPN_IFACE" ] && return 1
        echo "$GATEWAY" > "$VPN_TMP_DIR/gateway"
        _vpn_stop_monitor

        local P2P_IP=$(ifconfig "$VPN_IFACE" 2>/dev/null | awk '/-->/ {print $4}')
        netstat -nrf inet | awk -v iface="$VPN_IFACE" -v p2p="$P2P_IP" '
            $NF == iface && $1 != "Destination" {
                dest = $1
                if (dest == p2p) next
                if (dest ~ /^10\./ || dest ~ /^169\.254/ || dest == "default" || dest == "255.255.255.255/32" || dest == "224.0.0/4") next
                if (dest ~ /^(0|128)(\.|\/)/) next
                if (dest == "129.22" || dest ~ /^129\.22\./) next
                print dest
            }' | while read -r dest; do
            sudo /sbin/route -n delete -host "$dest" -ifscope "$VPN_IFACE" >/dev/null 2>&1
            sudo /sbin/route -n delete -host "$dest" >/dev/null 2>&1
            sudo /sbin/route -n add -host "$dest" "$GATEWAY" >/dev/null 2>&1
        done

        local KEEPALIVE_IP
        KEEPALIVE_IP=$(_vpn_apply_network_config "$GATEWAY" "$VPN_IFACE" "$PHYS_IFACE")

        _vpn_flush_dns
        _vpn_compile_menu_helper
        ( _vpn_monitor "$VPN_IP" "$KEEPALIVE_IP" "$VPN_IFACE" & echo $! > "$VPN_TMP_DIR/monitor.pid" )
        unset VPN_PASS VPN_USER TOTP
        return 0
    fi

    VPN_PASS=$(security find-internet-password -l "$VPN_KEYCHAIN_LABEL" -w 2>/dev/null)
    VPN_USER=$(_vpn_get_saved_user 2>/dev/null)
    if [ -z "$VPN_PASS" ] || [ -z "$VPN_USER" ]; then
        VPN_PASS=$(security find-generic-password -l "$VPN_KEYCHAIN_LABEL" -w 2>/dev/null)
        VPN_USER=$(_vpn_get_saved_user 2>/dev/null)
    fi

    if [ -z "$VPN_USER" ] || [ -z "$VPN_PASS" ]; then
        printf "Username: "
        read -r VPN_USER
        printf "Password: "
        read -rs VPN_PASS
        echo
    fi

    TOTP_SECRET=$(_vpn_get_totp_secret 2>/dev/null)
    if [ -n "$TOTP_SECRET" ]; then
        TOTP=$(_vpn_generate_totp "$TOTP_SECRET" 2>/dev/null)
        if [ -z "$TOTP" ]; then
            echo "Stored TOTP secret could not be used. Falling back to Duo Push or manual entry."
        fi
    fi

    if [ -t 0 ] && [ -z "$TOTP" ]; then
        printf "TOTP (Enter for Duo Push, type, or auto-read clipboard): "
        
        local INITIAL_CLIP=$(pbpaste 2>/dev/null)
        local CLIP_FILE="$VPN_TMP_DIR/clip_totp"
        TOTP=""
        
        trap 'TOTP=$(cat "$CLIP_FILE" 2>/dev/null); echo "$TOTP"' USR1
        
        set +m 2>/dev/null
        {
            local _clip_start=$(date +%s)
            while true; do
                sleep 0.2
                if (( $(date +%s) - _clip_start >= 120 )); then
                    break
                fi
                local CURRENT_CLIP=$(pbpaste 2>/dev/null)
                if [ "$CURRENT_CLIP" != "$INITIAL_CLIP" ]; then
                    local CLEAN_CLIP=$(echo "$CURRENT_CLIP" | tr -d '\n\r ')
                    if [[ "$CLEAN_CLIP" =~ ^[0-9]{6}$ ]]; then
                        echo "$CLEAN_CLIP" > "$CLIP_FILE"
                        kill -USR1 $$ 2>/dev/null
                        break
                    fi
                    INITIAL_CLIP="$CURRENT_CLIP"
                fi
            done
            unset INITIAL_CLIP CURRENT_CLIP CLEAN_CLIP
        } >/dev/null 2>&1 </dev/null &!
        local CLIP_PID=$!
        set -m 2>/dev/null
        
        local MAN_TOTP=""
        while [ -z "$TOTP" ]; do
            if read -r -t 0.2 MAN_TOTP 2>/dev/null; then
                break
            fi
        done
        
        set +m 2>/dev/null
        kill "$CLIP_PID" 2>/dev/null
        set -m 2>/dev/null
        
        trap - USR1
        rm -f "$CLIP_FILE"
        
        if [ -z "$TOTP" ]; then
            TOTP=$(echo "$MAN_TOTP" | tr -d '\n\r ')
        fi
        
    fi

    [ -n "$TOTP" ] && VPN_PASS="${VPN_PASS},${TOTP}"

    sudo /usr/bin/killall openfortivpn 2>/dev/null

    local VPN_CONF
    VPN_CONF=$(mktemp "${TMPDIR:-/tmp}/vpn_conf.XXXXXX")
    chmod 600 "$VPN_CONF"

    cat > "$VPN_CONF" <<CONFEOF
host = vpn2.case.edu
port = 443
username = $VPN_USER
password = $VPN_PASS
set-dns = 0
set-routes = 0
CONFEOF

    trap 'rm -f "$VPN_CONF"; dvpn >/dev/null 2>&1' EXIT INT TERM

    local OFV_EXEC
    OFV_EXEC=$(command -v openfortivpn 2>/dev/null)
    [ -z "$OFV_EXEC" ] && [ -f /opt/homebrew/bin/openfortivpn ] && OFV_EXEC="/opt/homebrew/bin/openfortivpn"
    [ -z "$OFV_EXEC" ] && OFV_EXEC="/usr/local/bin/openfortivpn"

    ( sudo "$OFV_EXEC" -c "$VPN_CONF" > "$VPN_TMP_DIR/openfortivpn.log" 2>&1 & echo $! > "$VPN_TMP_DIR/ofv.pid" )
    local OFV_PID=$(cat "$VPN_TMP_DIR/ofv.pid" 2>/dev/null)
    rm -f "$VPN_TMP_DIR/ofv.pid"

    local start_time=$(date +%s)
    while ! _vpn_get_info; do
        if ! kill -0 "$OFV_PID" 2>/dev/null && ! pgrep -q openfortivpn; then
            echo "Authentication failed."
            unset VPN_PASS VPN_USER TOTP TOTP_SECRET
            rm -f "$VPN_CONF"
            trap - EXIT INT TERM
            dvpn
            return 1
        fi
        if grep -qE "ERROR:" "$VPN_TMP_DIR/openfortivpn.log" 2>/dev/null; then
            echo "Authentication failed."
            unset VPN_PASS VPN_USER TOTP TOTP_SECRET
            rm -f "$VPN_CONF"
            trap - EXIT INT TERM
            dvpn
            return 1
        fi
        if (( $(date +%s) - start_time >= 60 )); then
            echo "Connection timed out."
            unset VPN_PASS VPN_USER TOTP TOTP_SECRET
            rm -f "$VPN_CONF"
            trap - EXIT INT TERM
            dvpn
            return 1
        fi
        sleep 1
    done

    rm -f "$VPN_CONF"
    trap - EXIT INT TERM

    if ! _vpn_get_phys_info; then
        unset VPN_PASS VPN_USER TOTP TOTP_SECRET
        return 1
    fi
    if [ -z "$GATEWAY" ] || [ -z "$VPN_IFACE" ]; then
        unset VPN_PASS VPN_USER TOTP TOTP_SECRET
        return 1
    fi
    echo "$GATEWAY" > "$VPN_TMP_DIR/gateway"

    local KEEPALIVE_IP
    KEEPALIVE_IP=$(_vpn_apply_network_config "$GATEWAY" "$VPN_IFACE" "$PHYS_IFACE")

    _vpn_flush_dns
    _vpn_compile_menu_helper
    ( _vpn_monitor "$VPN_IP" "$KEEPALIVE_IP" "$VPN_IFACE" & echo $! > "$VPN_TMP_DIR/monitor.pid" )
    unset VPN_PASS VPN_USER TOTP TOTP_SECRET
    return 0
}

dvpn() {
    _vpn_ensure_tmp_dir

    if ! _vpn_get_info && ! pgrep -q openfortivpn \
        && [ ! -f /etc/resolver/case.edu ] \
        && [ ! -f /etc/resolver/cwru.edu ] \
        && [ ! -f /etc/resolver/22.129.in-addr.arpa ] \
        && [ ! -f "$VPN_TMP_DIR/gateway" ] \
        && [ ! -f "$VPN_TMP_DIR/monitor.pid" ] \
        && [ ! -f "$VPN_TMP_DIR/fallback.pid" ] \
        && [ ! -f "$VPN_TMP_DIR/route_mon.pid" ] \
        && [ ! -f "$VPN_TMP_DIR/caffeinate.pid" ]; then
        return 0
    fi

    _vpn_stop_monitor

    local GATEWAY PHYS_IFACE
    _vpn_get_phys_info 2>/dev/null
    if [ -z "$GATEWAY" ] && [ -f "$VPN_TMP_DIR/gateway" ]; then
        GATEWAY=$(cat "$VPN_TMP_DIR/gateway")
    fi

    sudo /bin/rm -f /etc/resolver/case.edu /etc/resolver/cwru.edu /etc/resolver/22.129.in-addr.arpa 2>/dev/null

    local VPN_IP VPN_IFACE P2P_IP
    if _vpn_get_info; then
        P2P_IP=$(ifconfig "$VPN_IFACE" 2>/dev/null | awk '/-->/ {print $4}')
        netstat -nrf inet | awk -v iface="$VPN_IFACE" '$NF == iface && $1 != "Destination" {print $1}' | while read -r dest; do
            sudo /sbin/route -n delete -host "$dest" -ifscope "$VPN_IFACE" >/dev/null 2>&1
            sudo /sbin/route -n delete -host "$dest" >/dev/null 2>&1
            sudo /sbin/route -n delete -net "$dest" -interface "$VPN_IFACE" >/dev/null 2>&1
            sudo /sbin/route -n delete -net "$dest" >/dev/null 2>&1
        done
    fi

    sudo /usr/bin/killall openfortivpn 2>/dev/null

    sudo /sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
    sudo /sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
    sudo /sbin/route -n delete -net 129.22.0.0/16 >/dev/null 2>&1

    local CURRENT_GW=$(route -n get default 2>/dev/null | grep 'gateway:' | awk '{print $2}')
    if [ -z "$CURRENT_GW" ] || [ "$CURRENT_GW" = "$GATEWAY" ]; then
        sudo /sbin/route -n delete default >/dev/null 2>&1
        [ -n "$GATEWAY" ] && sudo /sbin/route -n add default "$GATEWAY" >/dev/null 2>&1
    fi

    if [ -f "$VPN_TMP_DIR/server_ips" ]; then
        while read -r ip; do sudo /sbin/route -n delete -host "$ip" >/dev/null 2>&1; done < "$VPN_TMP_DIR/server_ips"
    fi

    local NETWORK_SERVICE
    NETWORK_SERVICE=$(_vpn_get_network_service "$PHYS_IFACE")
    if [ -z "$NETWORK_SERVICE" ]; then
        NETWORK_SERVICE="Wi-Fi"
        echo "Warning: Could not determine active network service for interface '$PHYS_IFACE'. Falling back to Wi-Fi." >&2
    fi
    sudo /usr/sbin/networksetup -setv6automatic "$NETWORK_SERVICE" 2>/dev/null

    _vpn_flush_dns
    _vpn_cleanup_tmp_dir

    set +m 2>/dev/null
    {
        if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && ! ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
            sudo /sbin/route -n delete -net 0.0.0.0/1 >/dev/null 2>&1
            sudo /sbin/route -n delete -net 128.0.0.0/1 >/dev/null 2>&1
            sudo /sbin/route -n delete -net 129.22.0.0/16 >/dev/null 2>&1
            [ -n "$GATEWAY" ] && sudo /sbin/route -n delete default >/dev/null 2>&1
            [ -n "$GATEWAY" ] && sudo /sbin/route -n add default "$GATEWAY" >/dev/null 2>&1
            sleep 2
            if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && ! ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
                osascript -e 'display alert "CWRU VPN" message "Network routing could not be automatically restored. Please manually toggle Wi-Fi." as critical' >/dev/null 2>&1 &
            fi
        fi
    } >/dev/null 2>&1 </dev/null &!
    set -m 2>/dev/null
}
