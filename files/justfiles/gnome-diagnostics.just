# ── GNOME suspend/resume hang diagnostics ──────────────────────────────────

# Check whether gnome-shell is currently responding to D-Bus.
[group('Diagnostics')]
check-gnome-health:
    #!/usr/bin/env bash
    set -euo pipefail
    if dbus-send --session \
        --dest=org.gnome.Shell \
        --print-reply \
        /org/gnome/Shell \
        org.gnome.Shell.Eval \
        string:'1+1' >/dev/null 2>&1; then
        echo "gnome-shell is responding"
    else
        echo "ERROR: gnome-shell is NOT responding"
        exit 1
    fi

# Collect and print a gnome-shell diagnostic snapshot right now.
[group('Diagnostics')]
collect-gnome-diag:
    #!/usr/bin/env bash
    set -euo pipefail
    GNOME_PID=$(systemctl --user show "org.gnome.Shell@user.service" -p MainPID --value 2>/dev/null || true)
    echo "=== gnome-shell diagnostic snapshot at $(date -Iseconds) ==="
    echo "PID: ${GNOME_PID:-unknown}"
    if [ -n "$GNOME_PID" ] && [ -d "/proc/$GNOME_PID" ]; then
        echo "--- wchan ---"
        cat "/proc/$GNOME_PID/wchan" 2>/dev/null || echo "(unavailable)"
        echo ""
        echo "--- status ---"
        cat "/proc/$GNOME_PID/status" 2>/dev/null || echo "(unavailable)"
        echo "--- kernel stack (may require elevated ptrace scope) ---"
        cat "/proc/$GNOME_PID/stack" 2>/dev/null || echo "(unavailable)"
    fi
    echo "--- recent gnome-shell journal (last 50 lines) ---"
    journalctl --user --no-pager -n 50 2>/dev/null || true

# Show all hang-detection log entries captured by the sleep hook.
[group('Diagnostics')]
show-resume-diagnostics:
    journalctl -t gnome-diagnostics --no-pager -n 200

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
    if [ -x /etc/systemd/system-sleep/99-gnome-diagnostics ]; then
        run0 -i /etc/systemd/system-sleep/99-gnome-diagnostics post suspend
    fi
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
