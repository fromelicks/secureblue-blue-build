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

# ── Memory pressure / swap ─────────────────────────────────────────────────
# See docs/memory-pressure-hangs.md.

# Succeeds if a swap device other than zram is active. zram is not somewhere to
# reclaim to: every page it holds is still in RAM.
_has-disk-swap:
    #!/usr/bin/env bash
    set -uo pipefail
    swapon --show=NAME,TYPE --noheadings 2>/dev/null \
        | awk '$2 == "file" || $1 !~ /zram/ { found = 1 } END { exit found ? 0 : 1 }'

_warn-no-disk-swap:
    #!/usr/bin/env bash
    echo "WARNING: no disk swap tier is active." >&2
    echo "MemoryHigh on app.slice has nowhere to reclaim to and degenerates" >&2
    echo "into a reclaim treadmill; heavy jobs hit the global OOM killer." >&2
    echo "Create one -- see docs/memory-pressure-hangs.md:" >&2
    echo "  run0 btrfs filesystem mkswapfile --size 64g /var/swapfile" >&2
    echo "  run0 swapon /var/swapfile   # and add it to /etc/fstab" >&2

# Show session memory protection, app.slice containment and the swap tiers.
[group('Performance')]
show-memory-protection:
    #!/usr/bin/env bash
    set -uo pipefail
    UID_=$(id -u)
    BASE="/sys/fs/cgroup/user.slice/user-${UID_}.slice/user@${UID_}.service"
    human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }
    echo "--- protection chain (effective min/low are capped by EVERY ancestor) ---"
    printf '%-24s %10s %10s %10s\n' CGROUP MIN LOW CURRENT
    for c in /sys/fs/cgroup/user.slice \
             "/sys/fs/cgroup/user.slice/user-${UID_}.slice" \
             "$BASE" "$BASE/session.slice" "$BASE/app.slice" "$BASE/workload.slice"; do
        [ -d "$c" ] || continue
        printf '%-24s %10s %10s %10s\n' \
            "$(basename "$c")" \
            "$(human "$(cat "$c/memory.min" 2>/dev/null || echo 0)")" \
            "$(human "$(cat "$c/memory.low" 2>/dev/null || echo 0)")" \
            "$(human "$(cat "$c/memory.current" 2>/dev/null || echo 0)")"
    done
    echo ""
    echo "NB: memory_recursiveprot is $(findmnt -no OPTIONS /sys/fs/cgroup | grep -q memory_recursiveprot && echo ON || echo off)."
    echo "When ON, protection a child cannot claim is redistributed to its siblings,"
    echo "so an ancestor set well above session.slice's usage leaks it to app.slice."
    echo ""
    echo "--- app.slice containment ---"
    printf 'memory.high  %s\n' "$(cat "$BASE/app.slice/memory.high" 2>/dev/null || echo '-')"
    echo ""
    echo "--- reclaim events (low = times protection was breached anyway) ---"
    for s in session.slice app.slice workload.slice; do
        [ -d "$BASE/$s" ] || continue
        printf '%-16s %s\n' "$s" "$(tr '\n' ' ' < "$BASE/$s/memory.events" 2>/dev/null)"
    done
    echo ""
    echo "--- swap hierarchy (higher PRIO is used first) ---"
    swapon --show
    echo ""
    just -f "{{ justfile() }}" _has-disk-swap || just -f "{{ justfile() }}" _warn-no-disk-swap

# Example: ujust heavy-run julia --project=. bigmodel.jl
# Run a job expected to exceed RAM in workload.slice: no memory cap, no oomd.
[group('Performance')]
[positional-arguments]
heavy-run +ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    just -f "{{ justfile() }}" _has-disk-swap || just -f "{{ justfile() }}" _warn-no-disk-swap
    echo "Running in workload.slice (uncapped memory, oomd monitoring off)."
    echo "The desktop stays protected by MemoryMin on session.slice."
    echo ""
    # --expand-environment=no: systemd-run would otherwise substitute ${VAR}
    # (and whole-argument $VAR) in the job's arguments itself.
    exec systemd-run --user --slice=workload --scope --collect \
        --expand-environment=no --unit="heavy-$$" -- "$@"

# HIGH throttles (memory.high), MAX kills (memory.max). Keep MAX well above
# HIGH: memory.max only kills once reclaim fails, so a working set parked just
# above it thrashes instead of dying.
# Example: ujust burst-run 20G 28G zed
# Run a command that bursts: throttle at HIGH, kill at MAX.
[group('Performance')]
[positional-arguments]
burst-run HIGH MAX +ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    high=$1 max=$2
    shift 2
    # No --slice: systemd-run --user already places scopes in app.slice.
    # --expand-environment=no: pass arguments verbatim, as in heavy-run.
    exec systemd-run --user --scope --collect --expand-environment=no \
        --unit="burst-$$" -p MemoryHigh="$high" -p MemoryMax="$max" -- "$@"
