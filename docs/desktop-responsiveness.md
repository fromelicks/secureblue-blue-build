# Desktop responsiveness under load

How this image keeps the graphical session usable when an application saturates
the machine, and how the hang monitor tells "GNOME Shell is wedged" apart from
"the whole machine is starved".

## The incident this came from

On 2026-08-26 the desktop became unusable and needed a hard reset. The journal
showed no OOM kill, no kernel hung-task, no soft lockup, no NVIDIA `Xid`, and
exactly one kernel message across the whole ten-minute window. It was not a
kernel or GPU fault. It was userspace starvation:

- 21:42:24 — an editor opened a worktree with 23,745 entries and **69 nested git
  repositories**, and started a Julia language server with `--thread=auto`.
- 21:42:24 → 21:44:50 — the global PID counter advanced from 67,020 to 86,929:
  roughly **20,000 process creations in 150 seconds** (~130/s), sampled via the
  hang monitor's own 30-second probes.
- 21:45:06 — `gnome-shell: libinput error: ... your system is too slow`.
- 21:47:06 — a `runuser` that normally completes in ~20 ms took 8.9 s.
- 21:48:44 — `NetworkManager-dispatcher.service: start operation timed out`.

The hardening in this image amplifies exactly this workload. Measured on an idle
system here, one `fork`+`exec` of `/usr/bin/true` costs **~3.3 ms**; a stock
kernel is 0.5–1 ms. `slab_debug=FZ`, `slab_nomerge`, `init_on_alloc=1`,
`init_on_free=1`, `pti=on` and `iommu.strict=1` make process creation and the
dentry/inode/inotify slab churn several times more expensive, so a git-per-repo
scan loop that is merely sluggish on stock Fedora becomes terminal here.

## What the image does about it

### CPU and I/O priority

Upstream systemd ships every user slice at `CPUWeight=100`, so the compositor
competes on equal terms with an application scope spawning thousands of
processes. These drop-ins change that:

| Slice | CPUWeight | IOWeight | Holds |
|---|---|---|---|
| `session.slice` | 5000 | 1000 | gnome-shell, pipewire, wireplumber, dbus-broker, xdg portals |
| `app.slice` | 50 | 100 | everything launched from the shell or a terminal |
| `background.slice` | 10 | 20 | background user tasks |

Weights are **work-conserving**: this is a priority, not a cap. When the session
is idle, applications still get the entire machine; the weights only decide who
wins when both want the CPU in the same instant. A `make -j24` is not slowed
down in any way you will notice.

`session.slice` also carries `MemoryLow=1G` so the compositor's and the audio
stack's pages are protected first under reclaim. That only works because the
whole ancestor chain is opened up as well: cgroup v2 caps a cgroup's *effective*
`memory.low` by that of every ancestor, and upstream leaves `user.slice`,
`user-<uid>.slice` and `user@<uid>.service` all at 0 — so a `MemoryLow=` set only
on `session.slice` is silently effective-zero and protects nothing. Matching
drop-ins under `usr/lib/systemd/system/{user.slice,user-.slice,user@.service}.d/`
carry the same 1 G. Verify with:

```bash
cat /sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/session.slice/memory.low
```

`gnome-hang-monitor.service` runs at `Nice=-15` with `CPUWeight=10000` and
`OOMScoreAdjust=-900`, because a watchdog that cannot be scheduled during the
event it watches for is not a watchdog.

### Making IOWeight actually work

NVMe defaults to the `none` I/O scheduler, where `io.weight` is **inert** — every
`IOWeight=` setting is silently ignored. `fromelicks-io-cost.service` enables the
cgroup v2 `io.cost` controller with `ctrl=auto` on each physical disk, which
models device capacity below the scheduler and makes the weights above apply
without the throughput cost of switching to `bfq`.

This is the most speculative piece here; it has not been benchmarked on this
hardware. Turn it off at runtime with `ujust set-io-cost off` and check status
with `ujust show-resource-priority`.

### Escape hatches

```bash
ujust check-system-load          # starved or merely busy, with the evidence
ujust show-resource-priority     # effective weights + io.cost state
ujust collect-starvation-diag    # top cgroups, fork rate, PSI, into the journal
ujust boost-app ghostty          # make one running app's scope high priority
ujust throttle-app zed 400%      # deprioritise one app, optionally hard-cap it
ujust reset-app-priority zed     # undo either of the above
```

`boost-app` matters because your terminal also lives in `app.slice`: it is
prioritised the same as the runaway you would use it to kill.

`Alt+SysRq+S`/`U`/`B` remain available as a last resort (see
`etc/sysctl.d/99-sysrq-debug.conf`); they sync, remount read-only, and reboot
without the filesystem damage of a power cut.

## Starvation vs. a hung shell

The monitor's health check is a D-Bus call to `org.gnome.Shell.Eval` with a
5-second timeout. A failure only proves that no reply arrived, which happens
both when the compositor's main loop is wedged **and** when the machine is too
contended to schedule the probe at all. The two need opposite responses: killing
GNOME Shell recovers the first, and merely destroys a working session during the
second without returning any CPU to the machine.

Before acting on a failed probe the monitor now classifies the machine:

| Signal | Threshold | Why |
|---|---|---|
| `fork`+`exec` of `/usr/bin/true`, **median of 3** | ≥ 250 ms | Directly measures what collapsed in the incident. Idle baseline here is ~3–7 ms; during the incident even a plain `runuser` took seconds. Median, not a single sample, so one scheduling outlier cannot flip the verdict on its own. |
| `/proc/pressure/cpu` `some avg10` | ≥ 90% | Sustained runqueue contention. |
| `/proc/pressure/io` `full avg10` | ≥ 60% | Everything blocked on storage. |
| `/proc/pressure/memory` `full avg10` | ≥ 25% | Reclaim thrash without an OOM kill. |

The spawn-latency probe is the primary signal: PSI alone is too blunt, because a
legitimate parallel build pushes `cpu some avg10` well up without the desktop
becoming unusable. Verified here: 48 busy loops on 24 CPUs produced
`cpu_some=31%` and a 9 ms spawn latency, correctly classified **responsive**.

**Known bias.** That probe is spawned by the monitor, which runs at `Nice=-15`
and `CPUWeight=10000`, so it is scheduled sooner than anything in `app.slice`
and therefore *under*-reports what the session actually experiences. The four
signals are OR'd and PSI is read from `/proc/pressure`, which is machine-wide and
not process-local, so PSI remains the backstop when the boosted spawn looks
healthy. The 250 ms threshold sits 35–80× above the idle baseline precisely to
stay meaningful despite the boost — during the real incident a `runuser` took
8.9 s. Measuring inside `app.slice` instead would need a `runuser` +
`systemd-run --user` round-trip on every tick, which can itself block on a
starved machine; that trade is deliberate, not an oversight.

When the verdict is `starved`, the monitor:

- logs `health probe failed under system-wide resource starvation ... not
  treating this as a shell hang`, naming the evidence;
- writes a starvation snapshot (PSI, load, fork rate, top cgroups by CPU, top
  processes, tasks in `D` state, per-slice weights and `cpu.stat`) on the first
  tick and every fourth thereafter;
- **never** counts the tick towards `FAILURE_LIMIT`, so it never kills the
  compositor.

Once the machine recovers it logs `system load recovered after N starved
tick(s)` and resumes ordinary shell-hang accounting.

## Snapshots no longer delay recovery

Previously `collect_state` ran **synchronously inside the check loop** at `full`
detail on every attempt — `eu-stack`, per-thread `/proc/*/stack` reads, and a
walk of every `/proc/[0-9]*/fd` looking for DRM clients. On a starved machine
that took over two minutes per attempt, so the intended 90 seconds to recovery
(3 × 30 s) stretched past seven minutes. During the incident the machine was
hard-reset at about five minutes, and recovery never fired.

Now:

- snapshots run **detached** from the loop, and are reniced to +19 (and ionice
  idle) so the collector never outbids the compositor it is diagnosing;
- routine snapshots are bounded by `SNAPSHOT_TIMEOUT_SECONDS=25` plus a 3 s
  `timeout -k` grace, deliberately **below** the 30 s check interval, so a
  collection can never still hold the single in-flight slot when the next tick
  needs it — and the script clamps the budget to the interval minus the grace,
  because trusting the unit is what let a stale `45` drop every second
  snapshot;
- only one may be in flight and a second is dropped — *except* the pre-recovery
  snapshot, which pre-empts the in-flight one and gets
  `FULL_SNAPSHOT_TIMEOUT_SECONDS=60`. It is the last chance to capture this
  compositor before it is signalled, and after recovery the loop stops probing
  the old PID anyway, so its overrun cannot delay anything;
- every snapshot captures per-thread `wchan`, `syscall` and kernel stacks — those
  are plain `/proc` reads and are what identify where the main loop is blocked.
  Only `eu-stack` (which stops the target to unwind it) and the system-wide DRM
  client walk are reserved for `full`, so a hang that self-resolves before
  recovery still leaves usable evidence;
- compositor state is collected **first**, before `systemd-inhibit` and the
  `runuser` round-trip, each of which can burn its 5 s timeout on a starved
  machine — otherwise the pre-recovery snapshot's two-second head start would
  expire in the preamble and record a process already tearing down;
- `collect_drm_clients` is bounded to 20 seconds / 4000 processes, and the
  trailing `journalctl` reads to 10 s each;
- the loop sleeps until the next **wall-clock** tick boundary, with a 5 s floor:
  without one, a tick that overran its own interval would sleep zero and spin at
  `Nice=-15`, worsening the starvation it exists to measure.

Verified with a harness: a snapshot taking 9 s against a 2 s interval no longer
delays anything, and recovery still fires on the third tick exactly.

## Verifying after a rebase

```bash
ujust show-resource-priority
# expect session.slice 5000, app.slice 50, background.slice 10
# expect a non-empty io.cost.qos line per NVMe device

systemctl status fromelicks-io-cost.service
systemctl show gnome-hang-monitor.service -p Nice -p CPUWeight -p OOMScoreAdjust

ujust check-system-load          # 'responsive' on an idle machine
/usr/libexec/fromelicks-gnome-hang-monitor classify
```

To confirm the classifier does not misfire on ordinary heavy work, load the
machine and re-run `ujust check-system-load`; a parallel build should still
report `responsive`.
