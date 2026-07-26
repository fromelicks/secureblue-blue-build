# ── Bluetooth device recovery ──────────────────────────────────────────────

# Remove a stale bond, rediscover the device, pair it, trust it, and connect it.
# Pass an exact paired-device name or MAC, or omit it for a numbered prompt.
[group('Bluetooth')]
repair-bluetooth device="":
    #!/usr/bin/env bash
    set -euo pipefail

    DEVICE_QUERY={{ quote(device) }}
    DISCOVERY_STARTED=0

    fail() {
        printf 'ERROR: %s\n' "$*" >&2
        exit 1
    }

    stop_discovery() {
        if (( DISCOVERY_STARTED )); then
            bluetoothctl scan off >/dev/null 2>&1 || true
        fi
    }

    parse_devices() {
        local line mac name
        DEVICE_ADDRESSES=()
        DEVICE_NAMES=()

        while IFS= read -r line; do
            if [[ "$line" =~ ^Device[[:space:]]+([[:xdigit:]:]{17})[[:space:]]+(.+)$ ]]; then
                mac="${BASH_REMATCH[1]^^}"
                name="${BASH_REMATCH[2]}"
                DEVICE_ADDRESSES+=("$mac")
                DEVICE_NAMES+=("$name")
            fi
        done
    }

    prompt_for_index() {
        local prompt="$1"
        local maximum="$2"
        local choice

        while true; do
            read -r -p "$prompt" choice
            if [[ "$choice" =~ ^[0-9]+$ ]] \
                && (( choice >= 1 && choice <= maximum )); then
                CHOSEN_INDEX=$((choice - 1))
                return
            fi
            printf 'Enter a number from 1 to %d.\n' "$maximum" >&2
        done
    }

    print_devices() {
        local index
        for index in "${!DEVICE_ADDRESSES[@]}"; do
            printf '  %d) %s  [%s]\n' \
                "$((index + 1))" \
                "${DEVICE_NAMES[$index]}" \
                "${DEVICE_ADDRESSES[$index]}"
        done
    }

    command -v bluetoothctl >/dev/null 2>&1 \
        || fail "bluetoothctl is not installed."
    [[ -t 0 ]] || fail "this repair recipe requires an interactive terminal."

    printf '%s\n' \
        'Bluetooth repair removes the existing bond and creates a new one.' \
        'Have the device nearby and be ready to put it into pairing mode.' \
        ''

    mapfile -t PAIRED_LINES < <(LC_ALL=C bluetoothctl devices Paired)
    (( ${#PAIRED_LINES[@]} > 0 )) || fail "no paired Bluetooth devices were found."

    parse_devices < <(printf '%s\n' "${PAIRED_LINES[@]}")
    PAIRED_ADDRESSES=("${DEVICE_ADDRESSES[@]}")
    PAIRED_NAMES=("${DEVICE_NAMES[@]}")

    if [[ -z "$DEVICE_QUERY" ]]; then
        printf 'Paired devices:\n'
        print_devices
        prompt_for_index 'Select the device to repair: ' "${#DEVICE_ADDRESSES[@]}"
    else
        MATCHES=()
        for index in "${!DEVICE_ADDRESSES[@]}"; do
            if [[ "${DEVICE_ADDRESSES[$index],,}" == "${DEVICE_QUERY,,}" \
                || "${DEVICE_NAMES[$index],,}" == "${DEVICE_QUERY,,}" ]]; then
                MATCHES+=("$index")
            fi
        done

        (( ${#MATCHES[@]} > 0 )) \
            || fail "no paired device exactly matches '$DEVICE_QUERY'."

        if (( ${#MATCHES[@]} == 1 )); then
            CHOSEN_INDEX="${MATCHES[0]}"
        else
            DEVICE_ADDRESSES=()
            DEVICE_NAMES=()
            for index in "${MATCHES[@]}"; do
                DEVICE_ADDRESSES+=("${PAIRED_ADDRESSES[$index]}")
                DEVICE_NAMES+=("${PAIRED_NAMES[$index]}")
            done
            printf 'More than one paired device has that name:\n'
            print_devices
            prompt_for_index 'Select the device to repair: ' "${#DEVICE_ADDRESSES[@]}"
        fi
    fi

    OLD_ADDRESS="${DEVICE_ADDRESSES[$CHOSEN_INDEX]}"
    OLD_NAME="${DEVICE_NAMES[$CHOSEN_INDEX]}"

    printf '\nSelected: %s [%s]\n\n' "$OLD_NAME" "$OLD_ADDRESS"
    printf '%s\n' \
        'IMPORTANT: Put this device into pairing mode now.' \
        'For multi-device peripherals, select the same device slot first.'
    read -r -p 'Press Enter only after its pairing indicator is active... '

    printf '\nOld bond to remove: %s [%s]\n' "$OLD_NAME" "$OLD_ADDRESS"
    printf 'The replacement pairing identity will be selected after removal.\n'
    read -r -p 'Remove this bond and continue? [y/N] ' CONFIRM
    [[ "${CONFIRM,,}" == "y" || "${CONFIRM,,}" == "yes" ]] \
        || fail "repair cancelled; the old bond was not changed."

    printf '\nRemoving old bond...\n'
    bluetoothctl remove "$OLD_ADDRESS"

    if ! LC_ALL=C bluetoothctl show | grep -q 'Discovering: yes'; then
        bluetoothctl scan on >/dev/null
        DISCOVERY_STARTED=1
    fi
    trap stop_discovery EXIT

    printf 'Scanning for pairing-mode devices for 12 seconds...\n'
    sleep 12

    mapfile -t VISIBLE_LINES < <(LC_ALL=C bluetoothctl devices)
    parse_devices < <(printf '%s\n' "${VISIBLE_LINES[@]}")

    FRIENDLY_ADDRESSES=()
    FRIENDLY_NAMES=()
    for index in "${!DEVICE_ADDRESSES[@]}"; do
        MAC_AS_NAME="${DEVICE_ADDRESSES[$index]//:/-}"
        if [[ "${DEVICE_NAMES[$index],,}" != "${MAC_AS_NAME,,}" ]]; then
            FRIENDLY_ADDRESSES+=("${DEVICE_ADDRESSES[$index]}")
            FRIENDLY_NAMES+=("${DEVICE_NAMES[$index]}")
        fi
    done

    (( ${#FRIENDLY_ADDRESSES[@]} > 0 )) \
        || fail "no named pairing-mode device was discovered; check pairing mode and try again."

    DEVICE_ADDRESSES=("${FRIENDLY_ADDRESSES[@]}")
    DEVICE_NAMES=("${FRIENDLY_NAMES[@]}")

    printf '\nVisible named devices:\n'
    print_devices
    printf '\nSelect the pairing-mode identity for "%s".\n' "$OLD_NAME"
    printf 'Its name or address may differ from the old bond.\n'
    prompt_for_index 'Pair with device number: ' "${#DEVICE_ADDRESSES[@]}"

    NEW_ADDRESS="${DEVICE_ADDRESSES[$CHOSEN_INDEX]}"
    NEW_NAME="${DEVICE_NAMES[$CHOSEN_INDEX]}"

    printf '\nPairing target: %s [%s]\n' "$NEW_NAME" "$NEW_ADDRESS"
    printf 'Pairing with %s...\n' "$NEW_ADDRESS"
    bluetoothctl --agent KeyboardDisplay pair "$NEW_ADDRESS"

    printf 'Trusting and connecting...\n'
    bluetoothctl trust "$NEW_ADDRESS"
    bluetoothctl connect "$NEW_ADDRESS"

    INFO=$(LC_ALL=C bluetoothctl info "$NEW_ADDRESS")
    grep -q 'Paired: yes' <<< "$INFO" || fail "pairing did not persist."
    grep -q 'Bonded: yes' <<< "$INFO" || fail "the device is paired but not bonded."
    grep -q 'Trusted: yes' <<< "$INFO" || fail "the device was not marked trusted."
    grep -q 'Connected: yes' <<< "$INFO" || fail "the device did not remain connected."

    printf '\nBluetooth repair succeeded.\n'
    printf '%s\n' "$INFO" \
        | grep -E '^[[:space:]]*(Name|Alias|Paired|Bonded|Trusted|Connected):'
