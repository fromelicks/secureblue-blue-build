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
stays pending until that thread's kernel call returns, and a fatal signal needs
every thread to exit. `ps` also shows `TASK_KILLABLE` waits as `D`, and SIGKILL
*does* end those, but SIGTERM never does.
`nvkms_ioctl_from_kapi_try_pmlock` is where nvidia-drm calls into
nvidia-modeset. The thread was waiting there for a lock inside the driver that
something else held and never released. The recovery at the time (SIGCONT +
SIGTERM, never SIGKILL) was correct for a userspace hang and useless here.
Whether a SIGKILL would have freed it is unknown. If the wait was truly
uninterruptible, nothing short of a reboot could.

The monitor's own diagnostic reads of `/sys/kernel/debug/dri/*/state` also
blocked. That produced the repeated `Killed timeout -k 1s 3s head -n 1000`
lines, because reading nvidia-drm's atomic state takes the same locks.

## Root cause: a DIFR prefetch holds the nvkms lock

Identified on **2026-09-23**, the third occurrence and the first with the
recovery in this document deployed. Its sysrq dump caught both sides.

The victim is a display modeset, waiting on a **semaphore** — `down()`, not the
GPU:

```
down+0x47/0x60
nvkms_ioctl_from_kapi_try_pmlock+0x4a/0xa0 [nvidia_modeset]
ApplyModeSetConfig+0x174/0xe30 [nvidia_modeset]
nv_drm_atomic_apply_modeset_config+0x5dd/0x6a0 [nvidia_drm]
drm_atomic_check_only → drm_atomic_commit → drm_mode_atomic_ioctl → ioctl
```

The holder is the driver's own kthread, and it is **running, not blocked**:

```
CPU: 11  PID: 553  Comm: nvidia-modeset/
RIP: nvWriteGpEntry+0x40/0x3f0 [nvidia_modeset]
 nvPushKickoff
 PrefetchHelperSurfaceEvo
 nvDIFRPrefetchSurfaces            ← DIFR = Display Idle Frame Refresh
 DifrPrefetchEventDeferredWork
 nvkms_kthread_q_callback
 _main_loop → kthread
```

DIFR is NVIDIA's display idle power-saving path. A prefetch takes the global
nvkms lock and wedges while pushing GPU commands, and every compositor modeset
then queues behind it — which is why each occurrence coincides with the display
blanking or waking.

**`sysrq-l` is what found it, not `sysrq-w`.** The holder was running, so the
blocked-task dump alone would have shown the victim a third time. That key was
added during review of the same PR that shipped the dump.

**SIGKILL does not help.** The 2026-09-23 run escalated on schedule and the
thread stayed in `D`, so this is a genuinely uninterruptible wait rather than a
`TASK_KILLABLE` one.

**No driver-side off switch that I can confirm.** `nvidia_modeset` exposes no
DIFR parameter, and `nvidia.ko` only carries the RM control names
(`subdeviceCtrlCmdLpwrDifrCtrl`, `subdeviceCtrlCmdLpwrDifrPrefetchResponse`),
so DIFR is governed inside GSP firmware. Do not invent a registry key for it.
Not blanking the display remains the only workaround backed by evidence.

Still open: whether the "hangs on the lock screen" from before this document
were the same bug. The boots preceding 2026-09-21 contain neither the wait
channel nor a `PowerSaveMode` timeout.

**Not fixed by the Fedora 45 rebase or a newer driver.** The same stack
reproduced twice on 2026-11-09 under `nvidia-open` **620.70.06** and kernel
**7.2.15-300.secureblue.1.fc45**, with the frame addresses barely moved
(`nvWriteGpEntry+0x112` and `+0x10e`, `nvDIFRPrefetchSurfaces+0x155` both
times). Four driver/kernel combinations now carry it:

| Date | Kernel | Driver | Holder |
|---|---|---|---|
| 2026-09-21 | 7.2.5-200.fc44 | 615.71.09 | not captured (dump not yet deployed) |
| 2026-09-22 | 7.2.7-200.fc44 | 615.71.09 | not captured |
| 2026-09-23 | 7.2.7-200.fc44 | 615.71.09 | PID 553 `nvWriteGpEntry+0x40` |
| 2026-10-13 | 7.2.9-200.fc44 | 615.71.09 | PID 553 `nvWriteGpEntry+0x109` |
| 2026-11-09 11:07 | 7.2.15-300.fc45 | 620.70.06 | PID 568 `nvWriteGpEntry+0x112` |
| 2026-11-09 17:14 | 7.2.15-300.fc45 | 620.70.06 | PID 569 `nvWriteGpEntry+0x10e` |

That consistency across versions is what an upstream NVIDIA report needs, and
it also means waiting for a driver update is not a strategy.

## What the image now does

`gnome-hang-monitor.service` handles this case explicitly. On the attempt that
triggers recovery (third consecutive failure on a responsive machine):

1. **Kernel dump, before any signal.** If any gnome-shell thread is in `D`, the
   monitor runs `fromelicks-sysrq-show-blocked.service` and waits for it
   (bounded to 10 s). That unit writes two sysrq keys:
   - `w` prints the stack of every task in `D`, which catches a lock holder
     that is itself blocked;
   - `l` prints a backtrace of every CPU, which catches a holder that is
     running or spinning.

   A holder sleeping *interruptibly* shows up in neither. `t` (every task)
   would catch it, but it can overrun the kernel log buffer. It is a separate
   unit because the monitor runs with `ProtectKernelTunables=yes`, which makes
   the trigger file read-only for it. The trigger-file path bypasses the
   `kernel.sysrq` keyboard mask and is not blocked by `lockdown=confidentiality`
   (verified for the dump class with `m`, see
   [`crash-capture.md`](crash-capture.md)). The dump runs once per compositor
   PID. A failed attempt is retried on the next recovery cycle.
2. **SIGCONT + SIGTERM** as before. The driver-wedge steps below run only if
   this signal was actually sent. If recovery is disabled or the PID has
   changed, nothing further happens.
3. **Driver-wedge check.** This uses the blocked-thread scan taken before the
   signal. If one of those threads was waiting on an NVIDIA symbol, the monitor
   re-checks every 5 s:
   - if the shell exits or leaves the driver, the pending signal does its job
     and nothing more happens;
   - after `DRIVER_WEDGE_KILL_AFTER_SECONDS` (15) it sends **SIGKILL**, which
     ends a `TASK_KILLABLE` wait. The session is lost either way, and one
     process is far cheaper than a reboot;
   - if the thread is still stuck after `DRIVER_WEDGE_GRACE_SECONDS` (60), it
     runs an orderly `systemctl reboot`.

**"NVIDIA symbol" means module ownership, not a name prefix.** The driver's
real lock and wait primitives are `os_acquire_mutex`,
`os_acquire_rwlock_write`, `os_wait_uninterruptible`, `rm_acquire_gpu_lock` and
similar, so no prefix list covers them. Meanwhile `nv_*` also matches amdgpu.
The unit's privileged `ExecStartPre=+…nvidia-symbols` reads `/proc/kallsyms`,
which the sandbox masks. It collects every text symbol in an `[nvidia*]` module
and drops names that also exist in another module or in the core kernel, since
a wait channel is a bare name. On 615.71.09 that is 27,761 names, with 24
excluded. The list lives at `/run/gnome-diagnostics/nvidia-wchan-symbols`. If
it is missing, detection is off and the monitor says so at startup. The dump
and SIGTERM still happen, but there is no SIGKILL escalation and no reboot.

**Config drift cannot shorten the wait.** A non-integer grace (such as `60s`)
falls back to 60, the grace is clamped to at least 30 s, and the kill step is
kept inside the grace. An unknown action is treated as `log`.

Worst-case time from freeze to the reboot being *ordered* is about 90 s of
failed probes, the 60 s grace, and up to 30 s for the `systemctl reboot` call
itself. What happens after that is in "Bounding the reboot" below.

### Opting out

- `DRIVER_WEDGE_ACTION=log` in a drop-in for `gnome-hang-monitor.service`
  records the wedge and stops there: no SIGKILL escalation, no reboot.
- `run0 -i touch /run/gnome-diagnostics/no-recovery` suppresses the SIGTERM,
  the SIGKILL and the reboot. The file lives in the service's
  `RuntimeDirectory`, so it lasts only until the service **restarts or
  stops**, not until the next boot. `Restart=always` brings the monitor back
  with an empty directory, and the opt-out is gone. When inspecting a frozen
  machine, check the file is still there before relying on it.

### Why an orderly reboot and not `reboot -f`

The point is to keep the evidence. An orderly shutdown flushes journald and
unmounts filesystems, so the sysrq dump and the monitor's snapshots survive
into the next boot.

There is deliberately no explicit `sync` first. `sync(2)` sleeps
uninterruptibly while waiting for writeback, so on a stuck FUSE, network or USB
mount it would never return. `timeout(1)` waits for its child even after
SIGKILL, so the reboot would never be reached. The orderly reboot does its own
flush and unmount, and systemd-shutdown bounds its final sync.

### The orderly reboot did not finish, and why it does now

On 2026-09-23 the reboot was ordered at 17:47:12 and the machine was still
frozen 10-20 minutes later, ending in a hard power-off anyway. It never reached
the final shutdown stage; it crawled through per-unit kill ladders:

```
17:47:39  org.gnome.Shell@user.service: State 'final-watchdog' timed out. Killing.
17:47:44  org.gnome.Shell@user.service: Processes still around after final SIGKILL.
17:47:58  gnome-hang-monitor.service: State 'final-sigterm' timed out. Aborting.
17:48:43  gnome-hang-monitor.service: State 'final-watchdog' timed out. Killing.
17:48:58  user@1000.service: Processes still around after final SIGKILL.
17:49:28  gnome-hang-monitor.service: Processes still around after final SIGKILL.
17:49:28  Stopping systemd-logind.service...        ← last entry before power-off
```

Two causes, both of them ours, both now fixed:

1. **The monitor's own diagnostics were part of the jam.** Nine `head`
   processes reading `/sys/kernel/debug/dri/*/state` sat in `D`. That read takes
   `drm_modeset_lock_all()` — the lock the wedge is holding — and once blocked it
   cannot be killed, so each snapshot leaked one more. The monitor now skips
   that read whenever the compositor has a thread inside the NVIDIA driver, and
   keeps the harmless `clients` read. The unit also sets `TimeoutStopSec=10s`,
   so a leftover child costs 10 s per stop rung rather than 45.
2. **Nothing bounded the reboot itself.** `reboot.target` keeps systemd's
   default `JobTimeoutSec` of 30 minutes, and `RebootWatchdogSec=5min` cannot
   help, because it only arms in the `systemd-shutdown` stage that this reboot
   never reached. See "Bounding the reboot".

### Bounding the reboot

The obvious fix — `JobTimeoutSec=180` with `JobTimeoutAction=reboot-force` in a
`reboot.target.d/` drop-in — is **wrong here, and was reverted before it ever
shipped.** That setting is machine-wide, and this image's update path reboots
too: `ostree-finalize-staged.service` finalizes a staged deployment in its
`ExecStop`, under a deliberate `TimeoutStopSec=5m` ("to handle cases with slow
rotational media"). It conflicts with `final.target`, so that stop job runs
inside the reboot job's window. A 180 s machine-wide bound can therefore cut a
`bootc upgrade` short and lose the update.

The bound is armed on the **recovery path only**. Before ordering the orderly
reboot, the monitor runs

```
systemd-run --unit=fromelicks-wedge-force-reboot --on-active=180s \
  --timer-property=DefaultDependencies=no --property=DefaultDependencies=no \
  … force-reboot
```

`DefaultDependencies=no` on both transient units keeps them out of the shutdown
transaction they exist to outlive, and being separate units puts them outside
`gnome-hang-monitor.service`'s cgroup, so stopping the monitor does not take
the backstop with it. When it fires, `force-reboot` waits while
`ostree-finalize-staged.service` is still `deactivating` (up to
`FINALIZE_WAIT_SECONDS`, 6 min) and only then runs `systemctl reboot --force`.

Note what `--force` actually is: `systemd.unit(5)` describes the equivalent
`reboot-force` as "a forced reboot which will terminate all processes forcibly
but should cause **no dirty file systems** on reboot". Only `reboot -ff` /
`reboot-immediate` calls `reboot(2)` directly. So this still enters
`systemd-shutdown`, which kills, unmounts and syncs — and arms
`RebootWatchdogSec=5min` as the last backstop.

Timings, end to end: ~90 s of failed probes, 60 s of wedge grace, up to 30 s
for the `systemctl reboot` call, then 180 s before the forced reboot, then up
to 5 minutes of `systemd-shutdown` under the watchdog. So **about 6 minutes to
the forced reboot and up to ~11 minutes absolute worst case**, against a wedge
that previously needed the power button. Add up to 6 more minutes if a staged
deployment is being finalized, which is the trade that keeps the update.

**Those timings assume PID 1 is still dispatching jobs. On 2026-11-09 it was
not, twice, and none of this ran** — see the three sections below. The
budget that actually bounds a wedge now is `RuntimeWatchdogSec=2min`.

The paths were exercised against a stubbed `systemctl`: finalize in progress
then finishing, finalize never finishing (capped), nothing finalizing, and the
forced reboot itself failing.

### The forced reboot was tested on real hardware, and it did not fire

2026-11-09 produced two wedges in one day, both with everything above
deployed. The recovery ladder ran perfectly each time, including the new
backstop:

```
17:14:38  has thread(s) in uninterruptible sleep: 5363 nvkms_ioctl_from_kapi_try_pmlock
17:14:38  3 consecutive health failures; sending SIGCONT+SIGTERM to gnome-shell PID 5347
17:14:53  ignored SIGTERM for 15s; sending SIGKILL
17:15:38  Started fromelicks-wedge-force-reboot.timer
17:15:38  monitor: a forced reboot is armed for 180s from now if the orderly one stalls
17:15:38  still blocked inside the NVIDIA driver after 60s …; rebooting
```

The timer was created with the right properties, was never stopped, and had no
staged deployment to wait on. **It left no trace of ever firing** — no
`Starting fromelicks-wedge-force-reboot.service`, no "the orderly reboot did
not finish within 180s", and not even the
`Requested transaction contradicts existing jobs` that systemd logs when it
refuses a start job mid-shutdown (`polkit.service` got exactly that message in
the same window, so the mechanism was working). The machine then sat dead for
**2 h 46 min**; the 11:07 wedge sat dead for **69 min**. Both ended with the
power button.

### Why: the reboot is blocked on plymouth, inside the same wedged driver

Both incidents end on the *same journal line*, and it is the last thing PID 1
ever says:

```
11:08:45.568  Starting plymouth-reboot.service - Show Plymouth Reboot Screen...
11:09:30.735  plymouth-reboot.service: start-post operation timed out. Terminating.
              ← nothing, ever again

17:15:40.1    (service started)
17:16:25.188  plymouth-reboot.service: start-post operation timed out. Terminating.
              ← nothing, ever again
```

45.17 s and 45.09 s after the service started, i.e. exactly
`DefaultTimeoutStartSec=45s`. `plymouth-reboot.service` is
`ExecStart=/usr/bin/plymouthd --mode=reboot --attach-to-session` with
`ExecStartPost=-/usr/bin/plymouth show-splash`, `Type=forking`, and — decisively
— `Before=systemd-reboot.service`. `plymouth show-splash` needs the DRM device
that the DIFR prefetch has locked, so it blocks uninterruptibly; `Terminating`
sends it a SIGTERM it cannot receive; the start job can never complete; and
`systemd-reboot.service` is ordered after it. **The reboot is structurally
unreachable.**

PID 1 also stops logging at that instant and never dispatches the force-reboot
timer two minutes later, while `systemd-journald` was never stopped (no
`Stopping systemd-journald`, and `NetworkManager` was still logging at
11:10:35) and had hours of idle NVMe to flush anything buffered. The most
likely reason is PID 1 blocking on `/dev/console`, which with
`nvidia-drm.fbdev=1` is the wedged device — but that is inference, not
evidence. It does not matter for the conclusion:

> Every backstop the image had lived inside PID 1. `reboot.target`'s
> `JobTimeoutAction=reboot-force`, the transient `systemd-run` force-reboot
> timer, and `RebootWatchdogSec=5min` all need PID 1 to still be dispatching
> jobs. All three were armed. None of them fired.

Earlier revisions of this document called `RebootWatchdogSec=5min` and
`reboot.target`'s `JobTimeoutAction=reboot-force` "two backstops" for a reboot
that stalls on the driver. That was wrong, and the two 2026-11-09 outages are
the proof.

### The hardware watchdog is the only backstop left

`files/rootfs/etc/systemd/system.conf.d/10-watchdog.conf` now also sets

```
RuntimeWatchdogSec=2min
```

which hands `/dev/watchdog` (`iTCO_wdt`, `timeout=30`, `nowayout=0`) to PID 1
for the whole uptime rather than only the final reboot phase. systemd programs
the hardware timeout to that value and pings at half the interval, so a PID 1
that stops dispatching for more than ~2 minutes gets the machine reset by
hardware — no userspace involvement, which is the entire point.

Two minutes is comfortably longer than any legitimate PID 1 stall (its own work
is milliseconds of event-loop dispatch, and `init.scope` carries `MemoryMin=`
so reclaim cannot push it out — see
[`memory-pressure-hangs.md`](memory-pressure-hangs.md)) and far shorter than
the 69-minute and 2 h 46-minute outages it replaces.

Deliberately **no** `RuntimeWatchdogPreSec=`/`RuntimeWatchdogPreGovernor=`: a
`panic` pretimeout would be the only way to capture what PID 1 was stuck on,
but `iTCO_wdt` exposes no `pretimeout` attribute under
`/sys/class/watchdog/watchdog0`, so the governor has nothing to drive. A plain
reset leaves no dump, so the evidence still has to come from the monitor's
snapshots taken before the reboot — which is why their rate limiting
(below) mattered enough to fix in the same change.

That also puts the snapshots on a clock. journald syncs the journal to disk
immediately only at priority `<= LOG_CRIT`; everything else waits for
`SyncIntervalSec` (5 min) plus kernel writeback, and a hardware reset two
minutes later takes the page cache with it. The previous failure mode gave
writeback 69 minutes; this one may not. The monitor therefore logs the two
lines that immediately precede a reboot at `crit`, which forces a sync of
everything written before them, the last snapshot included.

**Verify the hardware timeout, not the configured one.**
`systemctl show -p RuntimeWatchdogUSec` echoes what was parsed from
`system.conf.d`, and `/sys/class/watchdog/watchdog0/state` only reports that
`/dev/watchdog` is open; both read as success even when the device refused the
requested timeout. `max_timeout` and `min_timeout` are both `0` on this
device, so the real range check lives inside `iTCO_wdt_set_timeout()` and a
refusal leaves the previous value (30 s) in place with only a warning in the
journal. The check that proves it:

```bash
cat /sys/class/watchdog/watchdog0/timeout      # expect 120, not 30
journalctl -b -1 -u init.scope | grep -i 'hardware watchdog'
```

**Not yet observed firing.** Like the forced-reboot timer before it, the reset
itself is only proven by the next wedge. Unlike that timer, nothing in its path
runs in userspace.

**A wedge with a staged deployment pending now forfeits the update.** The
reboot-bounding design above went out of its way to avoid cutting
`ostree-finalize-staged.service` short, and `FINALIZE_WAIT_SECONDS` still holds
the *software* forced reboot for it. A hardware reset cannot be held for
anything. In practice this costs nothing that was not already lost: the
watchdog only fires once PID 1 has stopped dispatching, at which point the
finalize is not running either and the previous outcome was the power button —
but the sentence above about "6 more minutes … the trade that keeps the update"
describes the software path only, and does not survive into the watchdog case.

**A narrower fix exists and is not applied yet.** Masking
`plymouth-reboot.service` removes the specific start job that blocks the
reboot. The two are complementary, not alternatives, and the case for doing
both is strong: with the mask the common case reboots in seconds with a
flushed journal and an intact ostree finalization, whereas the watchdog alone
makes every future occurrence cost ~3 minutes, an unsynced journal and a
forfeited staged deployment. The objections are weaker than they first look —
the karg hazard applies to `plymouth.enable=0`, not to a `/dev/null` symlink
under `files/rootfs/etc/systemd/system/`, which is declarative and reversible;
and "`systemd-reboot.service` could equally block on another DRM consumer" is
an argument for keeping the watchdog as the backstop, not for leaving the one
blocker that actually fired twice. It is held only because the watchdog is the
change that makes the machine recoverable at all, and shipping one variable at
a time is what lets the next occurrence say which one worked.

### Snapshots were being thrown away by journald

All three of the 2026-10/11 incidents lost their display diagnostics to
journald's per-unit rate limit:

```
Suppressed 12325 messages from gnome-hang-monitor.service
Suppressed 12365 messages from gnome-hang-monitor.service
Suppressed 12404 messages from gnome-hang-monitor.service
```

The sections that survived are `process status`, `limits`, `threads` and
`memory map`. Everything *after* the memory map was dropped from every snapshot
of every incident: the **`eu-stack` userspace backtraces of every compositor
thread** — the most valuable section for a shell that is alive but not
dispatching, and the thing the memory map exists to annotate — then login
sessions, inhibitors, DRM devices, connector state, runtime power state,
`nvidia-smi`, the debugfs reads and the DRM client walk. A compositor's
`/proc/<pid>/maps` is 11,000-12,000 lines on its own, which exceeds the
10,000-message default burst in a single 30 s window.

Fixed from both ends: `gnome-hang-monitor.service` sets
`LogRateLimitIntervalSec=30s` with `LogRateLimitBurst=60000`, and the monitor
filters the map to the mappings that carry a pathname, capped at
`MEMORY_MAP_MAX_MAPPINGS` (1000), counting the anonymous ones instead of
printing them.

**Not a `head -n`.** That was the first attempt and it was backwards. The map
is address-sorted, so its head is the executable followed by hardened_malloc's
anonymous reservations — 350 of the first 400 lines even for a plain `bash` —
while every shared library sits at the end above `0x7f...`. A head would have
kept 400 lines of slab reserve and zero libraries, destroying the one thing
the section is read for: resolving an address from the `eu-stack` backtraces
printed immediately after it. The filter is also a single `awk` pass rather
than a `wc -l` plus a bounded read, because each read of `/proc/<pid>/maps`
walks every VMA under the target's `mmap_read_lock` — and a thread wedged in
an NVIDIA fault path holding `mmap_write_lock` is exactly the situation being
diagnosed.

## After the next occurrence

```bash
# The monitor's decisions: wedge detected, SIGKILL, grace, reboot
journalctl -b -1 -t gnome-diagnostics --no-pager | grep -E 'monitor:'
# The sysrq dump: blocked tasks, then every CPU's backtrace
journalctl -b -1 -k --no-pager | grep -A60 -E 'sysrq: (Show Blocked State|Show backtrace of all active CPUs)'
```

Look for a task other than gnome-shell with frames in `nvkms_*`, `nv_*`,
`os_acquire_*` or `rm_*`. That is the lock holder, and it is what an upstream
NVIDIA bug report needs. Check the **CPU backtraces** as well as the blocked
tasks: on 2026-09-23 the holder was running, so it appeared only there.

To confirm it is the same DIFR wedge, check whether the holder's stack contains
`nvDIFRPrefetchSurfaces`. A different holder means a different bug, and the
stack is worth keeping.

To check the detection by hand against a live shell (root, because the symbol
list is in the root-only runtime directory):

```bash
run0 /usr/libexec/fromelicks-gnome-hang-monitor blocked "$(pgrep -xo gnome-shell)"
# prints the D-state threads and the NVIDIA subset
# exit 0: no NVIDIA wedge, 1: NVIDIA wedge, 2: bad PID / no process / no symbol list
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
