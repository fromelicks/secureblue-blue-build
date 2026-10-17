# ── AmneziaWG (awg-quick) ──────────────────────────────────────────────────

# WireGuard with traffic obfuscation, run from the userspace datapath. The
# image ships awg/awg-quick/amneziawg-go; the tunnel config is per-machine
# runtime state and lives in /etc/amnezia/amneziawg/<iface>.conf, never in the
# recipe. See docs/amneziawg.md.

# Import an AmneziaWG config, or one exported from the AmneziaVPN client.
[group('AmneziaWG')]
awg-import file iface="awg0":
    #!/usr/bin/env bash
    set -euo pipefail
    src="{{ file }}"
    dest="/etc/amnezia/amneziawg/{{ iface }}.conf"
    [ -r "$src" ] || { echo "cannot read $src"; exit 1; }
    grep -q '^\[Interface\]' "$src" || { echo "$src has no [Interface] section"; exit 1; }
    if grep -qE '^[[:space:]]*DNS[[:space:]]*=' "$src"; then
        echo "WARNING: this config sets DNS=. awg-quick handles that by calling"
        echo "         resolvconf, which on this host is the masked resolvectl."
        echo "         Comment it out and use PostUp/PreDown with"
        echo "         /usr/libexec/fromelicks-awg-dns instead -- see docs/amneziawg.md."
        echo ""
    fi
    if [ -e "$dest" ]; then
        printf 'overwrite existing %s? [y/N] ' "$dest"
        read -r reply
        case "$reply" in [yY]*) ;; *) echo "aborted"; exit 1 ;; esac
    fi
    run0 install -Dm600 "$src" "$dest"
    echo "installed -> $dest"
    echo "bring it up with: ujust awg-up {{ iface }}"

# Bring a tunnel up now (does not survive reboot; see awg-enable).
[group('AmneziaWG')]
awg-up iface="awg0":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -e "/etc/amnezia/amneziawg/{{ iface }}.conf" ] || {
        echo "no config at /etc/amnezia/amneziawg/{{ iface }}.conf"
        echo "import one with: ujust awg-import <file> {{ iface }}"
        exit 1
    }
    run0 systemctl start "awg-quick@{{ iface }}"
    echo ""
    ujust awg-status {{ iface }}

# Tear a tunnel down.
[group('AmneziaWG')]
awg-down iface="awg0":
    run0 systemctl stop "awg-quick@{{ iface }}"

# Start the tunnel at every boot.
[group('AmneziaWG')]
awg-enable iface="awg0":
    run0 systemctl enable --now "awg-quick@{{ iface }}"

# Stop starting the tunnel at boot.
[group('AmneziaWG')]
awg-disable iface="awg0":
    run0 systemctl disable --now "awg-quick@{{ iface }}"

# Show tunnel, routing and DNS state.
[group('AmneziaWG')]
awg-status iface="awg0":
    #!/usr/bin/env bash
    set -uo pipefail
    echo "--- unit ---"
    systemctl is-active "awg-quick@{{ iface }}" 2>/dev/null || true
    if ! ip link show "{{ iface }}" >/dev/null 2>&1; then
        echo ""
        echo "interface {{ iface }} does not exist -- tunnel is down"
        exit 0
    fi
    echo ""
    echo "--- peer ---"
    # Handshake and transfer counters are the only proof traffic is flowing.
    run0 awg show "{{ iface }}" || true
    echo ""
    echo "--- address / mtu ---"
    ip -br addr show "{{ iface }}"
    echo ""
    echo "--- default routes ---"
    ip route show default
    ip rule | grep -E 'suppress_prefixlength|fwmark' || true
    echo ""
    echo "--- dns ---"
    dnsconfd status 2>/dev/null | sed -n '1,12p' || cat /etc/resolv.conf

# Check the AmneziaWG stack is installed and consistent.
[group('AmneziaWG')]
awg-check:
    #!/usr/bin/env bash
    set -uo pipefail
    fail=0
    echo "--- binaries ---"
    for b in /usr/bin/awg /usr/bin/awg-quick /usr/bin/amneziawg-go; do
        if [ -x "$b" ]; then echo "ok: $b"; else echo "MISSING: $b"; fail=1; fi
    done
    echo ""
    echo "--- datapath ---"
    if [ -e /sys/module/amneziawg ]; then
        echo "kernel module present (awg-quick will prefer it)"
    else
        echo "no kernel module -- awg-quick falls back to amneziawg-go (expected here)"
    fi
    echo ""
    echo "--- unit template ---"
    if [ -f /usr/lib/systemd/system/awg-quick@.service ]; then
        echo "ok: awg-quick@.service"
    else
        echo "MISSING: awg-quick@.service"; fail=1
    fi
    echo ""
    echo "--- configs ---"
    shopt -s nullglob
    found=0
    for c in /etc/amnezia/amneziawg/*.conf; do
        found=1
        name="$(basename "$c" .conf)"
        # A world-readable config makes awg-quick refuse to start.
        perms="$(stat -c '%a' "$c")"
        if [ "$perms" = "600" ] || [ "$perms" = "400" ]; then
            echo "ok: $name ($perms)"
        else
            echo "WARNING: $name is mode $perms; awg-quick wants 600"
        fi
    done
    [ "$found" -eq 1 ] || echo "none in /etc/amnezia/amneziawg/"
    echo ""
    echo "--- dns integration ---"
    if systemctl is-active --quiet dnsconfd; then
        echo "ok: dnsconfd active (PostUp/PreDown hook will work)"
    else
        echo "WARNING: dnsconfd inactive -- the DNS hook refuses to bring a tunnel up"
    fi
    if systemctl is-active --quiet systemd-resolved; then
        echo "note: systemd-resolved active, so awg-quick's own DNS= would work too"
    else
        echo "ok: systemd-resolved inactive -- do not use DNS= in tunnel configs"
    fi
    exit "$fail"
