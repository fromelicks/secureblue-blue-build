# ── Desktop responsiveness / CPU and I/O priority ──────────────────────────

# Report whether the machine is currently resource-starved, with the evidence.
[group('Performance')]
check-system-load:
    #!/usr/bin/env bash
    set -uo pipefail
    /usr/libexec/fromelicks-gnome-hang-monitor classify
    STATUS=$?
    echo ""
    echo "--- pressure stall information (avg10 = last 10 seconds) ---"
    for r in cpu io memory irq; do
        printf '%-8s %s\n' "$r" "$(head -n1 /proc/pressure/$r 2>/dev/null)"
    done
    echo ""
    echo "loadavg: $(cat /proc/loadavg)"
    exit $STATUS

# Show the effective CPU/IO priority of the session against user applications.
[group('Performance')]
show-resource-priority:
    #!/usr/bin/env bash
    set -uo pipefail
    BASE="/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service"
    if [ ! -d "$BASE" ]; then
        echo "ERROR: no delegated user manager cgroup at $BASE"
        exit 1
    fi
    printf '%-18s %-12s %-18s\n' SLICE CPU.WEIGHT IO.WEIGHT
    for s in session.slice app.slice background.slice; do
        [ -d "$BASE/$s" ] || continue
        printf '%-18s %-12s %-18s\n' \
            "$s" \
            "$(cat "$BASE/$s/cpu.weight" 2>/dev/null || echo '-')" \
            "$(cat "$BASE/$s/io.weight" 2>/dev/null || echo '-')"
    done
    echo ""
    echo "Higher CPU.WEIGHT wins the runqueue when both want the CPU at once."
    echo "Weights are work-conserving: an idle session leaves the whole machine to apps."
    echo ""
    echo "--- io.cost (required for IO.WEIGHT to have any effect on NVMe) ---"
    # NB: cgroup kernfs files always report st_size 0, so [ -s ] is false even
    # when the file has content. Test the content itself.
    QOS=$(cat /sys/fs/cgroup/io.cost.qos 2>/dev/null || true)
    if [ -n "$QOS" ]; then
        echo "$QOS"
    else
        echo "not enabled -- IO.WEIGHT above is inert"
        echo "check: systemctl status fromelicks-io-cost.service"
    fi

# Capture a starvation snapshot now (top cgroups, fork rate, PSI) into the journal.
[group('Performance')]
collect-starvation-diag:
    #!/usr/bin/env bash
    set -euo pipefail
    START=$(date -Iseconds)
    run0 -i /usr/libexec/fromelicks-gnome-hang-monitor \
        starvation-snapshot "manual starvation snapshot" "requested by operator" 180
    journalctl -b -t gnome-diagnostics --since "$START" --no-pager

# Useful for the terminal you need responsive while something else saturates the
# box. Example: ujust boost-app ghostty
# Raise one running application's CPU/IO priority for the rest of this session.
[group('Performance')]
boost-app PATTERN:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t UNITS < <(systemctl --user list-units --type=scope --type=service \
        --state=running --plain --no-legend --no-pager \
        | awk '{ print $1 }' | grep -i -- '{{ PATTERN }}' || true)
    if [ "${#UNITS[@]}" -eq 0 ]; then
        echo "No running user scope or service matches '{{ PATTERN }}'."
        echo "List candidates with: systemctl --user list-units --type=scope --state=running"
        exit 1
    fi
    for u in "${UNITS[@]}"; do
        systemctl --user set-property --runtime "$u" CPUWeight=2000 IOWeight=500
        echo "boosted $u (CPUWeight=2000 IOWeight=500, until logout)"
    done

# QUOTA is a systemd CPUQuota value such as 400% (four cores' worth).
# Example: ujust throttle-app zed 400%
# Lower one running application's CPU/IO priority, optionally with a hard CPU cap.
[group('Performance')]
throttle-app PATTERN QUOTA="":
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t UNITS < <(systemctl --user list-units --type=scope --type=service \
        --state=running --plain --no-legend --no-pager \
        | awk '{ print $1 }' | grep -i -- '{{ PATTERN }}' || true)
    if [ "${#UNITS[@]}" -eq 0 ]; then
        echo "No running user scope or service matches '{{ PATTERN }}'."
        exit 1
    fi
    PROPS=(CPUWeight=1 IOWeight=1)
    if [ -n '{{ QUOTA }}' ]; then
        PROPS+=(CPUQuota='{{ QUOTA }}')
    fi
    for u in "${UNITS[@]}"; do
        systemctl --user set-property --runtime "$u" "${PROPS[@]}"
        echo "throttled $u (${PROPS[*]}, until logout)"
    done

# Undo boost-app / throttle-app for a running application.
[group('Performance')]
reset-app-priority PATTERN:
    #!/usr/bin/env bash
    set -euo pipefail
    mapfile -t UNITS < <(systemctl --user list-units --type=scope --type=service \
        --state=running --plain --no-legend --no-pager \
        | awk '{ print $1 }' | grep -i -- '{{ PATTERN }}' || true)
    if [ "${#UNITS[@]}" -eq 0 ]; then
        echo "No running user scope or service matches '{{ PATTERN }}'."
        exit 1
    fi
    for u in "${UNITS[@]}"; do
        systemctl --user set-property --runtime "$u" CPUWeight= IOWeight= CPUQuota=
        echo "reset $u to slice defaults"
    done

# Without io.cost, every IOWeight= setting on this system is inert.
# Turn the io.cost I/O controller on or off until the next boot.
[group('Performance')]
set-io-cost ACTION="status":
    #!/usr/bin/env bash
    set -euo pipefail
    case '{{ ACTION }}' in
        on|enable)   run0 -i /usr/libexec/fromelicks-io-cost enable ;;
        off|disable) run0 -i /usr/libexec/fromelicks-io-cost disable ;;
        status)      /usr/libexec/fromelicks-io-cost status ;;
        *) echo "usage: ujust set-io-cost [on|off|status]"; exit 2 ;;
    esac
