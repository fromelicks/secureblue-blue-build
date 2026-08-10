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

For each consecutive failure, the monitor records a full snapshot under the
`gnome-diagnostics` journal identifier:

- GNOME Shell process and per-thread state, kernel wait channels, syscalls, and
  kernel stacks;
- best-effort userspace backtraces from `eu-stack`;
- user-session and inhibitor state;
- DRM cards, connector state, runtime power state, and bounded `nvidia-smi`
  output;
- every process holding a DRM device, including its SELinux domain and DRM
  client/engine/memory accounting from `/proc/*/fdinfo`;
- recent display, suspend/resume, and SELinux denial events from the system
  journal;
- recent kernel warnings and user-session logs.

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
