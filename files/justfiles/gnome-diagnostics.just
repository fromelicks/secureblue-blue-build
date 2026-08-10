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
