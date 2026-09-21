# Lock-screen freeze: gnome-shell wedged in the NVIDIA driver on display blank

On 2026-09-21 the Legion froze on the GNOME lock screen. The last frame stayed on
the panel, keyboard and mouse did nothing, and only a hard power-off got the
machine back. **No suspend happened.** gnome-shell's KMS thread blocked inside
the NVIDIA kernel driver at the moment GNOME tried to blank the display, and
nothing in userspace could release it.

## Timeline (boot `6684ae3e`, all times CEST)

| Time | Event |
|---|---|
| 10:01:23 | `gnome-shell: Created gbm renderer for '/dev/dri/card0'` — card0 is the NVIDIA dGPU (`0000:01:00.0`, `nvidia-drm`). The external monitor is on `card0-HDMI-A-5`; the built-in `card1-eDP-1` (i915) is disabled. |
| 10:12:08 | Screen locked (`#PaperWM disabled` marks the lock screen's session-mode change). |
| 10:22:12 | `gsd-power: Error setting property 'PowerSaveMode' on interface org.gnome.Mutter.DisplayConfig: Timeout was reached`. This is the idle blank (DPMS off). Mutter never answered. |
| 10:22:14 | `gnome-hang-monitor`: `gnome-shell PID 6550 unresponsive (attempt 1/3); system responsive (spawn=6ms cpu_some=0% io_full=0% mem_full=0%)`. |
| 10:23:17, 10:25:16, 10:27:17 | `sending SIGCONT+SIGTERM to gnome-shell PID 6550`. Each time, the same PID was tracked again 20 s later. The signal had no effect. |
| 10:28:14 | Last journal entry before the power-off. |

Every snapshot from the hang monitor shows the same thread:

```
   PID     TID PSR STAT WCHAN                                    %CPU COMMAND
  6550    6583   8 D<sl nvkms_ioctl_from_kapi_try_pmlock          2.0 KMS thread
```

All other gnome-shell threads were in ordinary `futex`/`poll` waits. The main
thread was waiting on the KMS thread, so the whole compositor (lock screen,
input, the D-Bus reply to gsd-power) stopped with it.

## What was ruled out

- **Not a suspend/resume failure.** There is no `PM: suspend entry`, no
  `PrepareForSleep`, and the sleep marker was never set. The user's "around
  suspend" impression comes from the screen having locked.
- **Not a kernel panic.** Ramoops was armed (`reserve_mem=…:oops` on the
  cmdline) and `/var/lib/systemd/pstore` is empty. The kernel logged nothing
  at all after 10:12. This kernel has no hung-task detector
  (`/proc/sys/kernel/hung_task_timeout_secs` does not exist), so a blocked task
  generates no warning either.
- **Not starvation or memory pressure.** The classifier measured 5–6 ms spawn
  latency and 0 % CPU/IO/memory PSI on every tick. See
  [`desktop-responsiveness.md`](desktop-responsiveness.md) and
  [`memory-pressure-hangs.md`](memory-pressure-hangs.md) for those failure modes.
- **Not the WiFi firmware crash.** iwlwifi hit `NMI_INTERRUPT_UNKNOWN` at
  10:01:55 but restarted by itself in under a second, 20 minutes before the hang.

## Why SIGTERM could not recover it

`D` is uninterruptible sleep. A signal sent to a process with a thread in `D`
stays pending until that thread's kernel call returns. That includes SIGKILL,
and fatal signals need every thread to exit. `nvkms_ioctl_from_kapi_try_pmlock`
is where nvidia-drm calls into nvidia-modeset. The thread was waiting there for
a lock inside the driver that something else held and never released. From
userspace, nothing short of a reboot can undo that. The existing recovery
(SIGCONT + SIGTERM, never SIGKILL) was correct for a userspace hang and useless
here.

The monitor's own diagnostic reads of `/sys/kernel/debug/dri/*/state` also
blocked. That produced the repeated `Killed timeout -k 1s 3s head -n 1000`
lines, because reading nvidia-drm's atomic state takes the same locks.

## What is still unknown

**Which task held the lock.** The snapshot's kernel stacks all read
`(read failed)`. `/proc/<pid>/stack` needs `CAP_SYS_ADMIN`, which the monitor
deliberately does not hold, and it lists only gnome-shell's threads anyway. The
holder could be an NVIDIA kernel worker, a runtime-PM transition of the dGPU
(`Runtime D3 status: Enabled (fine-grained)`), or another DRM client.

**Whether earlier "hangs on the lock screen" were the same bug.** The ten
previous boots contain neither this wait channel nor a `PowerSaveMode` timeout.

Driver at the time: `nvidia-open` 615.71.09, kernel 7.2.5-200.secureblue.1.fc44.

## What the image now does

`gnome-hang-monitor.service` handles this case explicitly. On the attempt that
triggers recovery (third consecutive failure on a responsive machine):

1. **Blocked-task dump.** If any gnome-shell thread is in `D`, the monitor
   starts `fromelicks-sysrq-show-blocked.service` before signalling. That unit
   writes `w` to `/proc/sysrq-trigger`, and the kernel prints the stack of
   *every* blocked task to its log, lock holder included. It is a separate unit
   because the monitor runs with `ProtectKernelTunables=yes`, which makes the
   trigger file read-only for it. The trigger-file path bypasses the
   `kernel.sysrq` keyboard mask and is not blocked by `lockdown=confidentiality`
   (verified for the dump class with `m`, see
   [`crash-capture.md`](crash-capture.md)). The dump runs once per compositor
   PID.
2. **SIGCONT + SIGTERM** as before.
3. **Driver-wedge check.** If a gnome-shell thread is in `D` with a wait
   channel in the NVIDIA modules (`nvkms_*`, `nvidia_*`, `nv_*`, `_nv<digits>`),
   the monitor re-checks every 5 s for `DRIVER_WEDGE_GRACE_SECONDS` (60). If the
   shell exits or leaves the driver, the pending SIGTERM does its job and
   nothing more happens. If the thread is still stuck, it runs `sync` (bounded
   to 60 s) and then an orderly `systemctl reboot`.

The match is deliberately narrow: an i915 or generic DRM wait never triggers a
reboot. Worst-case time from freeze to reboot is about 90 s of failed probes
plus the 60 s grace.

### Opting out

- `DRIVER_WEDGE_ACTION=log` in a drop-in for `gnome-hang-monitor.service`
  records the wedge and leaves the machine frozen.
- `run0 -i touch /run/gnome-diagnostics/no-recovery` suppresses both the
  SIGTERM and the reboot until the next boot. Use this when the frozen state
  itself needs inspecting.

### Why an orderly reboot and not `reboot -f`

The point is to keep the evidence. An orderly shutdown flushes journald and
unmounts filesystems, so the sysrq-w dump and the monitor's snapshots survive
into the next boot. The wedged process cannot be killed, but systemd stops
waiting for it after `user@.service`'s stop timeout (1 min here) and carries on.
If the driver also blocks the final device shutdown, `RebootWatchdogSec=5min`
(`etc/systemd/system.conf.d/10-watchdog.conf`) and `reboot.target`'s
`JobTimeoutAction=reboot-force` are the backstops.

**Untested end to end:** nobody has yet watched this path reboot a genuinely
wedged machine. If the orderly reboot itself hangs on the NVIDIA device, the
power button is still the fallback. In that case the next boot's journal shows
how far shutdown got.

## After the next occurrence

```bash
# The monitor's decisions: wedge detected, grace, reboot
journalctl -b -1 -t gnome-diagnostics --no-pager | grep -E 'monitor:'
# The sysrq-w dump: look for the task holding nvkms / nvidia locks
journalctl -b -1 -k --no-pager | grep -A40 -E 'sysrq: Show Blocked State'
```

Look for a task other than gnome-shell with frames in `nvkms_*`, `nv_*`,
`os_acquire_*` or `rm_*`. That is the lock holder, and it is what an upstream
NVIDIA bug report needs.

To check the detection by hand against a live shell:

```bash
/usr/libexec/fromelicks-gnome-hang-monitor blocked "$(pgrep -xo gnome-shell)"
# prints "tid wchan comm [nvidia]" per D-state thread; exits 1 on an NVIDIA wedge
```

## Reproducing and working around

The trigger looks like *blanking a display driven by the NVIDIA GPU* while the
dGPU runs with fine-grained runtime D3. To test it deliberately with an external
monitor on the NVIDIA card, lock the screen and wait out the blank delay. Or
blank immediately:

```bash
busctl --user set-property org.gnome.Mutter.DisplayConfig \
  /org/gnome/Mutter/DisplayConfig org.gnome.Mutter.DisplayConfig PowerSaveMode i 3
```

If it reproduces, possible workarounds, none applied yet:

- Do not blank the screen while docked. Set
  `org.gnome.desktop.session idle-delay` to 0, or keep the external display
  on a port wired to the Intel iGPU if the chassis has one.
- Test a newer nvidia-open driver when secureblue ships one.
- As a diagnostic, disable fine-grained runtime D3 for the dGPU
  (`NVreg_DynamicPowerManagement=0x00`) to see whether the lock involves a
  runtime-PM transition. This costs idle battery life and is not a fix.
