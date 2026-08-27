# GNOME hang monitor

`gnome-hang-monitor.service` continuously checks the logged-in user's GNOME
Shell, including while the screen is locked or powered down. It replaces the
resume-only watchdog previously embedded in `90-gnome-diagnostics`.

## Detection and recovery

The service calls GNOME Shell's own D-Bus `org.gnome.Shell.Eval` handler every
30 seconds with the side-effect-free expression `true`. Unlike the generic
`Peer.Ping` handled by GDBus, this method is dispatched through Shell's
JavaScript main context. A compositor process that is alive but whose UI loop
is deadlocked therefore fails the check. Evaluation is disabled in the
hardened production session and normally returns `false`; receiving that reply
still proves that Shell dispatched the method.

A failed probe only proves that no reply arrived within the timeout, which also
happens when the machine is too contended to schedule the probe at all. Before
acting, the monitor classifies the machine as `starved` or `responsive` using
the wall time of one `fork`+`exec` plus the PSI files under `/proc/pressure`.
A starved tick is logged and snapshotted but **never** counted towards the
failure limit, so a system-wide overload cannot cause the compositor to be
killed. It does not *clear* the count either: on an intermittently loaded
machine, ticks alternating starved and responsive would otherwise keep resetting
the counter and a genuinely wedged shell could never reach the limit. A starved
tick does not count; it does not forgive the ticks that did. See [`desktop-responsiveness.md`](desktop-responsiveness.md) for the
thresholds and the resource-priority settings that reduce starvation in the
first place.

For each consecutive failure that is *not* attributable to starvation, the
monitor records a snapshot under the `gnome-diagnostics` journal identifier:

- GNOME Shell process and per-thread state, kernel wait channels, syscalls, and
  kernel stacks;
- best-effort userspace backtraces from `eu-stack`;
- user-session and inhibitor state;
- DRM cards, connector state, runtime power state, and bounded `nvidia-smi`
  output;
- every process holding a DRM device, including its SELinux domain and DRM
  client/engine/memory accounting from `/proc/*/fdinfo` (bounded to 20 seconds
  and 4000 processes);
- recent display, suspend/resume, and SELinux denial events from the system
  journal;
- recent kernel warnings and user-session logs.

Snapshots run **detached from the check loop**, reniced to +19, one at a time,
and the loop sleeps to the next wall-clock tick boundary (with a 5 s floor). A
slow collection therefore cannot delay recovery, which was the defect that
prevented recovery during the 2026-08-26 incident.

Routine collections are bounded by `SNAPSHOT_TIMEOUT_SECONDS` (25 s), below the
30 s check interval so one can never still occupy the single in-flight slot when
the next tick needs it. The pre-recovery collection is the exception: it
**pre-empts** whatever is in flight and gets `FULL_SNAPSHOT_TIMEOUT_SECONDS`
(60 s), because it is the last chance to capture this compositor before it is
signalled.

Per-thread wait channels, syscalls and kernel stacks are captured at *every*
detail level — they are plain `/proc` reads. Only `eu-stack` and the system-wide
DRM client walk are reserved for `full`, which is used on the attempt that
triggers recovery. A hang that resolves on its own before the limit therefore
still leaves enough to find where the main loop was blocked.

After three failed checks, it sends `SIGCONT` followed by `SIGTERM` to the same
validated GNOME Shell PID. This lets GDM recover the graphical session without
hard-powering off the machine, but the graphical session and its applications
will be lost. It never escalates to `SIGKILL`.

For a diagnostic run where the hung process must remain available for manual
inspection, create the runtime opt-out before reproducing:

```bash
run0 -i touch /run/gnome-diagnostics/no-recovery
```

Remove it to restore automatic recovery:

```bash
run0 -i rm /run/gnome-diagnostics/no-recovery
```

The opt-out is ephemeral and is cleared when the service restarts or the
machine reboots.

The monitor pauses while the system sleep hook is active. The sleep hook still
captures immediate pre-suspend and post-resume state, but no longer launches a
background watchdog process.

## Operator commands

```bash
just check-gnome-health
just status-gnome-hang-monitor
just show-resume-diagnostics
just collect-gnome-diag
just check-system-load        # starved vs. merely busy, with the evidence
just collect-starvation-diag  # who is consuming the machine right now
```

Older deployments may retain the former runtime hook at
`/etc/systemd/system-sleep/99-gnome-diagnostics`. After rebasing to the new
image, archive it so it does not duplicate the image-owned hook:

```bash
just retire-old-gnome-sleep-hook
```

The recipe moves the old file into a root-only directory under `/var/lib`; it
does not delete it.

To inspect a recovered incident from the previous boot:

```bash
journalctl -b -1 -t gnome-diagnostics --no-pager
journalctl -b -1 -u gnome-hang-monitor.service --no-pager
```
