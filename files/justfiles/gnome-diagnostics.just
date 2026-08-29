# ── GNOME suspend/resume hang diagnostics ──────────────────────────────────

# Check whether gnome-shell's main loop is currently responding to D-Bus.
[group('Diagnostics')]
check-gnome-health:
    #!/usr/bin/env bash
    set -euo pipefail
    if timeout 5 dbus-send --session \
        --dest=org.gnome.Shell \
        --print-reply \
        /org/gnome/Shell \
        org.gnome.Shell.Eval \
        string:true >/dev/null 2>&1; then
        echo "gnome-shell is responding"
    else
        echo "ERROR: gnome-shell is NOT responding"
        exit 1
    fi

# Collect a full root-level gnome-shell/DRM diagnostic snapshot right now.
[group('Diagnostics')]
collect-gnome-diag:
    #!/usr/bin/env bash
    set -euo pipefail
    UID_ACTIVE=$(id -u)
    GNOME_PID=$(systemctl --user show "org.gnome.Shell@user.service" -p MainPID --value 2>/dev/null || true)
    [ -n "$GNOME_PID" ] && [ "$GNOME_PID" != "0" ] || {
        echo "ERROR: no user gnome-shell process found"
        exit 1
    }
    run0 -i /usr/libexec/fromelicks-gnome-hang-monitor \
        snapshot "manual diagnostic snapshot" "$UID_ACTIVE" "$GNOME_PID" 180 full
    echo "Snapshot written to journald."
    journalctl -b -t gnome-diagnostics --since '2 minutes ago' --no-pager

# Show continuous monitor and suspend/resume diagnostic entries.
[group('Diagnostics')]
show-resume-diagnostics:
    journalctl -b -t gnome-diagnostics --no-pager -n 400

# Show the continuous GNOME hang monitor's service status.
[group('Diagnostics')]
status-gnome-hang-monitor:
    systemctl status gnome-hang-monitor.service --no-pager

# Archive the obsolete local sleep-hook copy created by older diagnostics.
# Run once after rebasing to an image containing gnome-hang-monitor.service.
[group('Diagnostics')]
retire-old-gnome-sleep-hook:
    #!/usr/bin/env bash
    set -euo pipefail
    OLD=/etc/systemd/system-sleep/99-gnome-diagnostics
    ARCHIVE=/var/lib/fromelicks/retired-system-sleep-hooks
    if [ ! -e "$OLD" ]; then
        echo "No obsolete local sleep hook is present."
        exit 0
    fi
    STAMP=$(date -u +%Y%m%dT%H%M%SZ)
    TARGET="$ARCHIVE/99-gnome-diagnostics.$STAMP"
    run0 -i install -d -m 0700 "$ARCHIVE"
    run0 -i mv -- "$OLD" "$TARGET"
    echo "Archived obsolete hook at $TARGET"

# Temporarily enable coredumps for GNOME Shell crash debugging.
[group('Diagnostics')]
enable-gnome-coredumps:
    #!/usr/bin/env bash
    # Overrides secureblue's runtime coredump hardening only until disabled or rebooted.
    set -euo pipefail
    HANDLER='|/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h %d %F'
    printf '%s\n' "$HANDLER" | run0 -i tee /proc/sys/kernel/core_pattern >/dev/null
    DROPIN=~/.config/systemd/user/org.gnome.Shell@user.service.d
    mkdir -p "$DROPIN"
    printf '[Service]\nLimitCORE=infinity\n' > "$DROPIN/99-gnome-coredump-local.conf"
    systemctl --user daemon-reload
    GNOME_PID=$(systemctl --user show "org.gnome.Shell@user.service" -p MainPID --value 2>/dev/null || true)
    if [ -n "$GNOME_PID" ] && [ "$GNOME_PID" != "0" ]; then
        run0 -i prlimit --pid "$GNOME_PID" --core=unlimited || true
    fi
    echo "Temporary GNOME Shell coredumps enabled."
    echo "Current core_pattern: $(cat /proc/sys/kernel/core_pattern)"
    echo "Current GNOME core limit: $(grep -i '^Max core file size' /proc/${GNOME_PID}/limits 2>/dev/null || echo unknown)"
    echo "For future GNOME Shell instances, log out and back in if needed."

# Disable temporary GNOME Shell coredump collection again.
[group('Diagnostics')]
disable-gnome-coredumps:
    #!/usr/bin/env bash
    set -euo pipefail
    printf '%s\n' '|/bin/false' | run0 -i tee /proc/sys/kernel/core_pattern >/dev/null
    rm -f ~/.config/systemd/user/org.gnome.Shell@user.service.d/99-gnome-coredump-local.conf
    systemctl --user daemon-reload
    GNOME_PID=$(systemctl --user show "org.gnome.Shell@user.service" -p MainPID --value 2>/dev/null || true)
    if [ -n "$GNOME_PID" ] && [ "$GNOME_PID" != "0" ]; then
        run0 -i prlimit --pid "$GNOME_PID" --core=0 || true
    fi
    echo "Temporary GNOME Shell coredumps disabled."
    echo "Current core_pattern: $(cat /proc/sys/kernel/core_pattern)"

# Deliberately run one suspend/resume cycle and show the captured diagnostics.
[group('Diagnostics')]
debug-suspend-cycle:
    #!/usr/bin/env bash
    set -euo pipefail
    START=$(date -Iseconds)
    MARK="manual suspend-cycle ${START}"
    systemd-cat -t gnome-diagnostics -p warning <<< "manual: starting ${MARK}"
    run0 -i systemctl suspend
    sleep 10
    systemd-cat -t gnome-diagnostics -p warning <<< "manual: resumed ${MARK}"
    journalctl -b -t gnome-diagnostics --since "$START" --no-pager

# Enable verbose mutter/KMS/DRM debug logging (writes a user-local drop-in).
# Takes effect after: systemctl --user restart "org.gnome.Shell@user.service"
# WARNING: fills journal rapidly; disable after capturing the needed data.
[group('Diagnostics')]
enable-mutter-debug:
    #!/usr/bin/env bash
    set -euo pipefail
    DROPIN=~/.config/systemd/user/org.gnome.Shell@user.service.d
    mkdir -p "$DROPIN"
    printf '[Service]\nEnvironment="G_MESSAGES_DEBUG=mutter"\n' \
        > "$DROPIN/99-mutter-debug-local.conf"
    systemctl --user daemon-reload
    echo "Mutter debug logging enabled."
    echo "Restart gnome-shell to apply: systemctl --user restart 'org.gnome.Shell@user.service'"
    echo "Or log out and back in."

# Disable verbose mutter/KMS/DRM debug logging.
[group('Diagnostics')]
disable-mutter-debug:
    #!/usr/bin/env bash
    set -euo pipefail
    DROPIN=~/.config/systemd/user/org.gnome.Shell@user.service.d/99-mutter-debug-local.conf
    rm -f "$DROPIN"
    systemctl --user daemon-reload
    echo "Mutter debug logging disabled."

# Report whether each kernel-crash capture path is actually armed.
[group('Diagnostics')]
check-crash-capture:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "--- panic behaviour ---"
    P=$(cat /proc/sys/kernel/panic)
    if [ "$P" = "-1" ]; then
        echo "kernel.panic = -1  ** reboots instantly; a panic leaves no readable message **"
    else
        echo "kernel.panic = $P seconds on screen before reboot"
    fi
    printf 'kernel.panic_on_oops = %s\n' "$(cat /proc/sys/kernel/panic_on_oops)"
    echo ""
    echo "--- ramoops (RAM-backed, survives warm reboot) ---"
    if grep -q 'ramoops.mem_name' /proc/cmdline; then
        echo "kargs:   $(grep -o 'reserve_mem=[^ ]*\|ramoops\.[^ ]*' /proc/cmdline | tr '\n' ' ')"
    else
        echo "kargs:   MISSING -- reserve_mem=/ramoops.mem_name= not on the command line"
    fi
    if [ -d /sys/module/ramoops ]; then
        echo "module:  loaded"
    else
        echo "module:  NOT loaded"
    fi
    echo ""
    echo "--- pstore ---"
    echo "mount:   $(findmnt -no OPTIONS /sys/fs/pstore 2>/dev/null || echo 'not mounted')"
    echo "efi:     pstore_disable=$(cat /sys/module/efi_pstore/parameters/pstore_disable 2>/dev/null || echo '?') (Y is expected; EFI NVRAM writes are deliberately avoided)"
    echo ""
    echo "--- firmware error records ---"
    ls /sys/firmware/acpi/tables/ 2>/dev/null | grep -qE 'BERT' \
        && echo "BERT:    present" \
        || echo "BERT:    absent -- this firmware records no hardware error reports"
    echo ""
    echo "--- records on hand ---"
    # /sys/fs/pstore is drwxr-x--- root:root, so an unprivileged ls returns
    # nothing and would report "0 entr(ies)" whether or not a record exists --
    # the exact false negative this check is meant to rule out. Count as root,
    # and say so when the count could not be taken.
    #
    # Do NOT pipe run0 into wc here: the `if` would then test wc's status, which
    # is always 0, the else branch would be unreachable, and a dismissed polkit
    # prompt would print a confident "0 entr(ies)" -- reintroducing the very
    # false negative this block exists to prevent. Capture run0's own status
    # first, then count.
    for d in /sys/fs/pstore /var/lib/systemd/pstore; do
        if OUT=$(run0 -i find "$d" -type f 2>/dev/null); then
            N=0
            [ -n "$OUT" ] && N=$(printf '%s\n' "$OUT" | wc -l)
            printf '%-24s %s entr(ies)\n' "$d:" "$N"
        else
            printf '%-24s unreadable (needs root, or the polkit prompt was declined)\n' "$d:"
        fi
    done

# Print any kernel crash record preserved from a previous boot.
[group('Diagnostics')]
show-crash-records:
    #!/usr/bin/env bash
    set -uo pipefail
    FOUND=0
    for d in /sys/fs/pstore /var/lib/systemd/pstore; do
        mapfile -t RECS < <(run0 -i find "$d" -type f 2>/dev/null | sort)
        [ "${#RECS[@]}" -gt 0 ] || continue
        FOUND=1
        for r in "${RECS[@]}"; do
            echo "════════ $r ════════"
            run0 -i cat "$r"
            echo ""
        done
    done
    if [ "$FOUND" -eq 0 ]; then
        echo "No crash records preserved."
        echo "Run 'ujust check-crash-capture' to confirm capture is actually armed."
    fi
