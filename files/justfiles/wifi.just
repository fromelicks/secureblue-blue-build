# ── Intel CNVi Wi-Fi diagnostics and recovery ──────────────────────────────

# Print a human-readable status report for the Intel CNVi Wi-Fi function.
[group('Wi-Fi')]
wifi-status:
    #!/usr/bin/env bash
    set -uo pipefail

    PCI_BDF="0000:00:14.3"
    PCI_SYS="/sys/bus/pci/devices/${PCI_BDF}"
    STATUS_CODE=0

    read_attr() {
        local path="$1"
        if [[ -r "$path" ]]; then
            tr -d '\n' < "$path"
        else
            printf 'unavailable'
        fi
    }

    printf '=== Intel CNVi Wi-Fi status ===\n'
    printf 'Timestamp:     %s\n' "$(date -Iseconds)"
    printf 'Kernel:        %s\n' "$(uname -r)"
    printf 'PCI function:  %s\n' "$PCI_BDF"

    if [[ ! -d "$PCI_SYS" ]]; then
        printf 'Overall:       FAILED — PCI function is not enumerated\n'
        printf '\nThe Intel CNVi device is absent from sysfs. A PCI FLR cannot be used.\n'
        printf 'Try a complete shutdown/power cycle and inspect the firmware/UEFI state.\n'
        exit 2
    fi

    VENDOR=$(read_attr "$PCI_SYS/vendor")
    DEVICE=$(read_attr "$PCI_SYS/device")
    printf 'PCI ID:        %s:%s\n' "${VENDOR#0x}" "${DEVICE#0x}"

    if [[ -L "$PCI_SYS/driver" ]]; then
        DRIVER=$(basename "$(readlink -f "$PCI_SYS/driver")")
    else
        DRIVER="unbound"
    fi

    printf 'Driver:        %s\n' "$DRIVER"
    printf 'Power state:   %s\n' "$(read_attr "$PCI_SYS/power_state")"
    printf 'Enabled:       %s\n' "$(read_attr "$PCI_SYS/enable")"
    printf 'D3cold allowed:%s\n' " $(read_attr "$PCI_SYS/d3cold_allowed")"
    printf 'Runtime PM:    %s (%s)\n' \
        "$(read_attr "$PCI_SYS/power/control")" \
        "$(read_attr "$PCI_SYS/power/runtime_status")"
    printf 'Reset methods: %s\n' "$(read_attr "$PCI_SYS/reset_method")"

    mapfile -t INTERFACES < <(
        find "$PCI_SYS/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
    )

    printf '\n--- Network interfaces ---\n'
    if (( ${#INTERFACES[@]} == 0 )); then
        printf 'None are associated with %s.\n' "$PCI_BDF"
    else
        for interface in "${INTERFACES[@]}"; do
            printf '%s\n' "$interface"

            if command -v ethtool >/dev/null 2>&1; then
                FIRMWARE=$(ethtool -i "$interface" 2>/dev/null \
                    | awk -F': ' '$1 == "firmware-version" { print $2 }')
                [[ -n "$FIRMWARE" ]] && printf '  Firmware:    %s\n' "$FIRMWARE"
            fi

            if command -v nmcli >/dev/null 2>&1; then
                NM_STATE=$(LC_ALL=C nmcli -g GENERAL.STATE device show "$interface" 2>/dev/null || true)
                NM_CONNECTION=$(LC_ALL=C nmcli -g GENERAL.CONNECTION device show "$interface" 2>/dev/null || true)
                [[ -n "$NM_STATE" ]] && printf '  NM state:    %s\n' "$NM_STATE"
                [[ -n "$NM_CONNECTION" && "$NM_CONNECTION" != "--" ]] \
                    && printf '  Connection:  %s\n' "$NM_CONNECTION"
            fi
        done
    fi

    printf '\n--- Radio block state ---\n'
    if command -v rfkill >/dev/null 2>&1; then
        RFKILL=$(rfkill list wifi 2>&1 || true)
        if [[ -n "$RFKILL" ]]; then
            sed 's/^/  /' <<< "$RFKILL"
        else
            printf 'No Wi-Fi rfkill entry is present.\n'
        fi
    else
        printf 'rfkill is unavailable.\n'
    fi

    printf '\n--- Recent relevant kernel messages ---\n'
    RECENT_LOGS=$(journalctl -b -k --no-pager -n 500 2>/dev/null \
        | grep -Ei 'iwlwifi|iwlmvm|00:14\.3|NMI_INTERRUPT|FSEQ_ERROR_CODE' \
        | tail -n 30 || true)
    if [[ -n "$RECENT_LOGS" ]]; then
        printf '%s\n' "$RECENT_LOGS"
    else
        printf 'No matching messages are visible to the current user.\n'
        printf 'For the full kernel journal, run: run0 -i journalctl -b -k\n'
    fi

    printf '\n--- Interpretation ---\n'
    if [[ "$DRIVER" == "unbound" ]]; then
        printf 'Overall: FAILED — the PCI function is present but has no driver.\n'
        printf 'This matches the pre-firmware probe-timeout failure mode.\n'
        printf 'Recovery: ujust wifi-pci-flr\n'
        STATUS_CODE=1
    elif [[ "$DRIVER" != "iwlwifi" ]]; then
        printf 'Overall: FAILED — unexpected driver "%s" is bound.\n' "$DRIVER"
        STATUS_CODE=1
    elif (( ${#INTERFACES[@]} == 0 )); then
        printf 'Overall: DEGRADED — iwlwifi is bound but no WLAN interface exists.\n'
        STATUS_CODE=1
    else
        printf 'Overall: READY — iwlwifi is bound and a WLAN interface exists.\n'
    fi

    if [[ "$(read_attr "$PCI_SYS/d3cold_allowed")" != "0" ]]; then
        printf 'Warning: d3cold_allowed is not 0; the suspend mitigation is missing.\n'
        STATUS_CODE=1
    fi

    exit "$STATUS_CODE"

# Recover the pre-firmware failure by issuing one PCI FLR and re-probing iwlwifi.
[group('Wi-Fi')]
wifi-pci-flr:
    #!/usr/bin/env bash
    set -euo pipefail

    PCI_BDF="0000:00:14.3"
    PCI_SYS="/sys/bus/pci/devices/${PCI_BDF}"
    EXPECTED_VENDOR="0x8086"
    EXPECTED_DEVICE="0x7a70"

    fail() {
        printf 'ERROR: %s\n' "$*" >&2
        exit 1
    }

    [[ -d "$PCI_SYS" ]] \
        || fail "$PCI_BDF is not enumerated; PCI FLR is unavailable."

    VENDOR=$(tr -d '\n' < "$PCI_SYS/vendor")
    DEVICE=$(tr -d '\n' < "$PCI_SYS/device")
    [[ "$VENDOR" == "$EXPECTED_VENDOR" && "$DEVICE" == "$EXPECTED_DEVICE" ]] \
        || fail "refusing to reset unexpected PCI device ${VENDOR}:${DEVICE} at $PCI_BDF."

    if [[ -L "$PCI_SYS/driver" ]]; then
        DRIVER=$(basename "$(readlink -f "$PCI_SYS/driver")")
        printf '%s is already bound to %s; no reset was performed.\n' "$PCI_BDF" "$DRIVER"
        printf 'This recipe only recovers the pre-firmware, unbound-device failure mode.\n'
        printf 'Run "ujust wifi-status" for current diagnostics.\n'
        exit 0
    fi

    [[ -e "$PCI_SYS/reset" ]] \
        || fail "$PCI_BDF does not expose a PCI reset control."

    RESET_METHODS=$(tr -d '\n' < "$PCI_SYS/reset_method" 2>/dev/null || true)
    [[ " $RESET_METHODS " == *" flr "* ]] \
        || fail "$PCI_BDF does not advertise Function Level Reset (methods: ${RESET_METHODS:-none})."

    printf 'Recovering Intel CNVi Wi-Fi at %s\n' "$PCI_BDF"
    printf '1/3 Issuing PCI Function Level Reset...\n'
    printf '1\n' | run0 -i tee "$PCI_SYS/reset" >/dev/null

    printf '2/3 Ensuring iwlwifi is loaded...\n'
    run0 -i modprobe iwlwifi

    if [[ ! -L "$PCI_SYS/driver" ]]; then
        DRIVER_BIND="/sys/bus/pci/drivers/iwlwifi/bind"
        [[ -e "$DRIVER_BIND" ]] \
            || fail "iwlwifi loaded but its PCI bind control is unavailable."

        printf '3/3 Re-probing iwlwifi...\n'
        if ! printf '%s\n' "$PCI_BDF" | run0 -i tee "$DRIVER_BIND" >/dev/null; then
            printf '\nThe FLR completed, but iwlwifi failed to bind.\n' >&2
            printf 'Run "ujust wifi-status" to inspect the new failure signature.\n' >&2
            exit 1
        fi
    else
        printf '3/3 iwlwifi bound automatically after module loading.\n'
    fi

    for _ in {1..20}; do
        [[ -L "$PCI_SYS/driver" && -d "$PCI_SYS/net" ]] && break
        sleep 0.25
    done

    [[ -L "$PCI_SYS/driver" ]] \
        || fail "FLR completed, but the PCI function remains unbound."

    DRIVER=$(basename "$(readlink -f "$PCI_SYS/driver")")
    [[ "$DRIVER" == "iwlwifi" ]] \
        || fail "FLR completed, but unexpected driver '$DRIVER' is bound."

    mapfile -t INTERFACES < <(
        find "$PCI_SYS/net" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort
    )
    (( ${#INTERFACES[@]} > 0 )) \
        || fail "iwlwifi is bound, but no WLAN interface appeared."

    printf '\nWi-Fi PCI recovery succeeded.\n'
    printf 'Driver:     %s\n' "$DRIVER"
    printf 'Interfaces: %s\n' "${INTERFACES[*]}"
    printf 'D3cold:     %s\n' "$(tr -d '\n' < "$PCI_SYS/d3cold_allowed")"

    if command -v nmcli >/dev/null 2>&1; then
        sleep 1
        LC_ALL=C nmcli device status 2>/dev/null \
            | awk 'NR == 1 || $2 == "wifi" || $2 == "wifi-p2p"' || true
    fi
