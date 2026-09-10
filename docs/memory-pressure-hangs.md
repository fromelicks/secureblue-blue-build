# Memory pressure hangs

How this image keeps the graphical session alive when an application's working
set exceeds RAM, why the CPU/IO priority work in
[`desktop-responsiveness.md`](desktop-responsiveness.md) does not help with this
failure, and how to run a job that deliberately needs more memory than the
machine has.

## The incident this came from

On 2026-09-07 the desktop was unusable for roughly fifteen minutes and recovered
only when the kernel killed the offending process. Unlike the 2026-08-26
starvation incident, this one left plenty of evidence.

- 08:58 — Zed opened from a Ptyxis terminal, landing in
  `app-…/ptyxis-spawn-c85a1f7d-….scope` under `app.slice`.
- Over the next 12h24m it grew without bound. Final scope accounting:
  `Consumed 4h 25min 42s CPU over 12h 24min 38s wall clock time, 23.4G memory
  peak, 5.4G memory swap peak`.
- 21:21:08 — `systemd-oomd` fired and killed **Trivalent** (2.7 GiB) for
  `app.slice` pressure at `83.17% > 80.00%`. The browser was thrashing *because*
  of Zed; oomd killed the symptom and left the cause running.
- 21:23:02 — the kernel's own OOM killer fired:

  ```
  kernel: Out of memory: Killed process 18230 (zed-editor)
      total-vm:170449216kB  anon-rss:22285840kB  pgtables:57368kB
  kernel: Free swap  = 120kB
  kernel: Total swap = 8388604kB
  ```

Zed held **21.26 GiB resident + 5.05 GiB swapped ≈ 26.3 GiB** on a 31 GiB
machine, and swap was **100.0% full — 120 kB free of 8 GiB**. Note this was a
*global* OOM (`constraint=CONSTRAINT_NONE … global_oom`), not a cgroup one: the
machine genuinely had nowhere left to put a page.

### Which process actually held the memory

Worth pinning down, because the obvious suspect is a language server rather than
the editor. On **2026-08-26** the Julia LSP *was* the culprit — see
[`desktop-responsiveness.md`](desktop-responsiveness.md), where an editor opened
a worktree of 23,745 entries across 69 nested git repositories and started a
Julia language server with `--thread=auto`. Indexing a large Julia project is
known to reach tens of gigabytes here.

That is **not** what happened on 2026-09-07. The kernel's OOM dump names every
process, and the memory was in the editor itself:

| `comm` | rss | swapped |
|---|---|---|
| `zed-editor` | 21.26 GiB | 5.05 GiB |
| `julia` | 0.35 GiB | 0.15 GiB |
| `lazygit` | 1.66 GiB | 0.00 GiB |

There was exactly one `julia` process and it held 0.35 GiB. No Julia process was
killed earlier in the window either — the only prior kill was oomd taking
Trivalent at 21:21:08 — so the LSP was not a large process that had already been
reaped. Whether Zed leaked on its own or was driven there by something it was
doing on the LSP's behalf is not established by this evidence; what is
established is that the 21.26 GiB resident was charged to `zed-editor`.

Either way it is an application problem, not a tuning problem. Everything below
is about containing the blast radius, not about making that allocation succeed.

**Consequence for the recipes:** an editor's language servers are spawned as its
children and therefore land in the editor's cgroup. `ujust burst-run 20G 28G zed`
bounds the editor *and* its language servers together, which is usually what you
want — but it also means a 60 GiB Julia indexing pass cannot succeed under that
ceiling. If that is the goal, either launch the editor via `ujust heavy-run`
instead, accepting that it is then uncapped, or raise the burst ceilings for that
session. The two cases genuinely conflict: the same mechanism that stops a
runaway editor from hanging the desktop also stops a legitimate large index.

## Why the CPU and I/O priority work did not help

`session.slice` already carries `CPUWeight=5000` against `app.slice`'s `50`, and
the desktop still froze. Three independent reasons:

**1. Those are the wrong controllers.** CPU and I/O weights arbitrate who wins
when two cgroups want the runqueue or the disk. GNOME Shell was waiting for
neither — it was in **direct reclaim** inside the kernel. From oomd's records,
`Pgscan` advanced `285,612,769 → 306,214,615`: **20.6 million pages scanned in
about 20 seconds**, freeing essentially nothing because swap was full. No
scheduler weight helps a task that is not on the runqueue.

**2. `MemoryLow` is advisory and it did not hold.** The protection chain was
already opened down to `session.slice` (that is what the `user.slice`,
`user-.slice` and `user@.service` drop-ins are for — effective `memory.low` is
capped by *every* ancestor). It was still breached, and the kernel counts it:

```
session.slice memory.events:  low 19985
```

That counter is "times this cgroup was reclaimed **despite** its `memory.low`".
Nearly 20,000 breaches. Under global pressure the kernel reclaims straight
through `memory.low` rather than OOM. Only `memory.min` is a hard floor.

**3. Nothing capped `app.slice`.** `memory.high` was `max` and `memory.low` was
`0`. A single application was structurally permitted to take the whole machine.

## Why `MemoryMax` is the wrong tool

The obvious fix — `systemd-run --user --scope -p MemoryMax=16G zed` — makes
things *worse*, and was tried: Zed hard-hangs after 15–25 minutes.

`MemoryMax` is `memory.max`. On hitting it the kernel runs **direct reclaim
against that cgroup**, and OOM-kills only if reclaim *fails*. With swap
available reclaim keeps nominally succeeding, so the kill path is never reached.
A working set parked above the limit therefore thrashes **indefinitely** instead
of dying. `MemoryMax` is a thrash limit, not a burst limit.

The usable pattern is both knobs, far apart:

- **`MemoryHigh`** — soft throttle, never kills. Where pushback begins.
- **`MemoryMax`** — backstop set well above it, so a genuine runaway dies in
  seconds rather than hanging for twenty minutes.

That is what `ujust burst-run` wires up.

## The missing tier

The single largest difference between this machine and the same hardware running
Windows is not tuning. It is that Fedora had **no disk swap at all** — only
8 GiB of zram, which is a compression layer, not a storage tier. *Every page in
zram is still resident in RAM.* zram multiplies capacity by its compression
ratio; it cannot create capacity, and it cannot return a cold page to the
system. Windows ships memory compression *and* a dynamically growing pagefile.

The second difference is containment: WSL2 is a VM with a bounded memory budget,
so a runaway workload there structurally cannot hang the host desktop. The
`MemoryHigh` on `app.slice` is the cgroup equivalent of that boundary.

**The swapfile is per-machine runtime state, not image content** (AGENTS.md
bucket 2) — `/var` cannot ship in the image. Create it once per machine:

```bash
# swapctl is a chezmoi user dotfile in ~/.local/bin, so it is NOT on root's
# PATH -- `run0 swapctl ...` fails with a bare exit 203. Invoke it explicitly:
run0 bash ~/.local/bin/swapctl create 64G     # defaults to /var/swapfile

# Or without it, using only what the image ships:
run0 btrfs filesystem mkswapfile --size 64g /var/swapfile
run0 swapon /var/swapfile
# then add to /etc/fstab:  /var/swapfile none swap sw 0 0
```

`swapctl` is in the chezmoi dotfiles and handles the btrfs requirements: a btrfs
swap file must be NOCOW, uncompressed, and backed by *real* extents, so the
usual `fallocate` + `mkswap` recipe produces a file `swapon` rejects with
`EINVAL` ("swapfile must not be preallocated"). It uses
`btrfs filesystem mkswapfile` instead, and verifies the result before activating
— `mkswapfile` can print an error and still exit 0, leaving a zero-length file.

Everything below depends on this existing. **`MemoryHigh` without a disk tier is
actively harmful**: throttling with nowhere to reclaim to is the same reclaim
treadmill that caused the hang.

## What the image does now

| Where | Setting | Purpose |
|---|---|---|
| `user.slice` | `MemoryMin=2G`, `MemoryLow=2.5G` | Headroom above the children. `user-.slice.d` also applies to the GDM greeter's dynamic-user slice (AGENTS.md constraint 11); when siblings' protection exceeds the parent's, each share is scaled down, quietly shrinking the session's "hard" floor during login, lock and user-switch. |
| `user-.slice`, `user@.service` | `MemoryMin=1.5G`, `MemoryLow=2G` | Open the chain. Effective min/low are capped by every ancestor, so protection on `session.slice` alone is effective-0. |
| `session.slice` | `MemoryMin=1.5G`, `MemoryLow=2G` | `MemoryMin` is the hard floor the 19,985 `low` breaches showed was missing. `MemoryLow` sits just above the observed ~1.4 GiB working set — see the recursive-protection note below. |
| `app.slice` | `MemoryHigh=65%`, `ManagedOOMMemoryPressureLimit=95%` | Containment (20.2 GiB here), plus stopping oomd killing on pressure the throttle itself creates. |
| `workload.slice` (new) | no cap, `CPUWeight=20`, and `ManagedOOMMemoryPressure=auto` via `workload.slice.d/50-fromelicks-oomd.conf` | Escape hatch for jobs *expected* to exceed RAM. |

Note which of these are absolute and which are relative, because it is not
arbitrary. `MemoryHigh` on `app.slice` is a percentage: containment is a question
of how much the application slice may hold before it gives memory back, and that
scales with the machine — a hard 24G would cap applications at 37% of a 64 GiB
box and make them swap against idle RAM. `MemoryMin`/`MemoryLow` stay absolute:
the compositor's working set is ~1.2–1.5 GiB regardless of installed RAM, so a
percentage would over-protect a large machine and under-protect a small one.

systemd resolves percentages against physical RAM natively, but has no
expression language — there is no way to write `min(ram * 0.75, 24G)` in a unit
file.

**65%, not 75%, because zram's cost is invisible to cgroups.** Pages swapped to
zram leave `app.slice`'s `memory.current` but stay resident in RAM as unaccounted
kernel memory, so the slice ceiling and zram's footprint are *additive*. With
16 GiB of zram (~6 GiB of RAM when full), a 75% ceiling would leave under 2 GiB
for `session.slice`, the system slice and the kernel combined.

**Two traps in the protection numbers**, both verified on this machine:

- `/sys/fs/cgroup` is mounted with **`memory_recursiveprot`**. A child claims
  only `min(usage, setting)`, and the parent's *unclaimed* protection is
  redistributed to its siblings in proportion to their unprotected usage. An
  earlier draft set 3G across the chain; since `session.slice` only uses
  ~1.4 GiB, that donated ~1.6 GiB of reclaim protection to `app.slice` — the
  cgroup it was meant to reclaim from. Keep ancestors near the real ceiling.
- The chain is **not uniform**. `user.slice` needs headroom above
  `session.slice`, because `user-.slice.d` also applies to the greeter's user
  manager and siblings' protection is scaled down when it exceeds the parent's.

### Running a job that needs more memory than the machine has

A 60 GiB Julia run on a 32 GiB machine cannot be made to fit; it can be made to
*complete* without taking the desktop with it. `workload.slice` is outside
`app.slice`'s cap:

```bash
ujust heavy-run julia --project=. bigmodel.jl
```

It will stream through the swapfile and be slow. The desktop stays up because
`session.slice` holds a hard `MemoryMin`.

### Applications that legitimately burst

```bash
ujust burst-run 20G 28G zed
```

Throttles at 20 GiB, kills at 28 GiB. Indexing bursts through the first;
a runaway dies quickly at the second instead of wedging the machine.

## systemd-oomd needs handling separately

Several things about oomd here are easy to get wrong; earlier drafts of this
work got most of them wrong.

**Fedora monitors every user slice, and an override must sort after it.**
`/usr/lib/systemd/user/slice.d/10-oomd-per-slice-defaults.conf` sets
`ManagedOOMMemoryPressure=kill` at `80%` for *every* `.slice` in the user
manager. Drop-ins with different names apply in lexicographic order **across all
directories**; a type-level file only loses to a unit-level file of the *same*
name (systemd.unit(5)). An override in `app.slice.d/10-fromelicks-priority.conf`
sorts before Fedora's file and is silently reset to 80% — an earlier draft
shipped exactly that. Both overrides therefore live in `50-fromelicks-oomd.conf`.

**The values are `auto|kill`; there is no `none`.** An invalid value is logged
(`Invalid syntax, ignoring: none`) and otherwise ignored, and
`systemd-analyze verify` does not fail on it, so the kill silently stays in
force. `auto` is the correct "leave this cgroup alone". `workload.slice` needs
it, or a long `heavy-run` job is killed for holding pressure high — which is the
job working as designed.

**`ManagedOOMPreference=omit` does not work on user cgroups.**
systemd.resource-control(5): "systemd-oomd will only respect these extended
attributes if the unit's cgroup is **owned by root**." Everything under
`user@%U.service` is owned by the user, so the xattr is ignored for both the
swap and the memory-pressure candidate calculations. `omit` on a user slice
reads like an exemption and is not one.

**`MemoryHigh` manufactures the pressure oomd kills on.** `memory.high` works by
stalling allocations and forcing reclaim — that is, by generating memory PSI. At
the stock 80% limit, `app.slice` would sit above the threshold for the whole
throttled period and hand oomd a reason to kill. Hence
`ManagedOOMMemoryPressureLimit=95%` alongside it: oomd stays a last resort, and
the throttle band below it is usable. Both kills observed on 2026-09-07
(83.17% and 89.10%) fall below 95%.

**`ManagedOOMSwap=kill` is still not enabled.** It selects by swap usage, so it
would have picked Zed (5.4 GiB swapped) over Trivalent — but during a large
`heavy-run` job the highest-swap cgroup *is that job by definition*, and the
`omit` exemption that would have protected it does not work here. Enabling it
would reliably kill the workload it most needs to leave alone.

## Verifying after a rebase

```bash
ujust show-memory-protection
```

Expect: a non-zero `MIN` on every row of the chain (a `0` anywhere caps
everything below it), `user.slice` **above** its children rather than equal to
them, a `memory.high` near 65% of RAM on `app.slice` (20.2 GiB here), and **two**
entries in the swap hierarchy — zram at priority 100 and `/var/swapfile` below
it. The recipe prints whether `memory_recursiveprot` is on and warns explicitly
if the disk tier is missing.

Confirm the oomd overrides actually landed — a mis-named drop-in or an invalid
value fails silently. The limit prints as a fraction of 2³²: `4080218930` is
95%, `3435973836` means Fedora's 80% won:

```bash
systemctl --user show app.slice -p ManagedOOMMemoryPressureLimit   # expect 4080218930
systemctl --user show workload.slice -p ManagedOOMMemoryPressure   # expect auto
```

Check that the protection is actually holding over time:

```bash
# 'low' should stay near zero in normal use; it counts reclaims that walked
# through the protection. 19985 is what a bad day looks like.
cat /sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/session.slice/memory.events
```

## `vm.page-cluster`: considered and deliberately not shipped

Swap read-ahead (`vm.page-cluster`, default `3` = 8 pages per fault) is the
obvious next knob, and an earlier draft shipped `0`. It was removed.

The argument for `0` is zram-shaped: zram is random-access, so read-ahead buys
no seek saving and costs seven extra decompressions per fault, and under
pressure the pages it guesses wrong about are charged to RAM that is already
scarce. The argument against is that `page-cluster` is **global** — there is no
per-device knob — and the `/var/swapfile` tier is exactly where read-ahead pays.
`ujust heavy-run` streaming a 60 GiB heap through NVMe is this design's headline
workload, and `0` turns each 32 KiB swap-in into eight separate 4 KiB reads.

Since the two tiers want opposite settings, the tie-breaker should be a
measurement, and there isn't one: the zram read-ahead advice is largely folklore
that predates MGLRU (enabled here, `/sys/kernel/mm/lru_gen/enabled` = `0x0007`).
Shipping an unmeasured change that pessimises the main workload is worse than
shipping nothing, so the kernel default stands.

To test it on a specific workload:

```bash
# baseline
cat /proc/vmstat | grep -E 'pswpin|pswpout'
# ...run the workload, re-read, then:
run0 sysctl vm.page-cluster=0
# ...run it again and compare pswpin against wall-clock time.
```

`pswpin` rising far faster than useful work indicates read-ahead is guessing
wrong. If a value proves out, ship it as `/etc/sysctl.d/99-fromelicks-swap.conf`
— note that `sysctl.d(5)` sorts by **basename** across `/etc`, `/run` and
`/usr/lib`, so the `99-` prefix is what makes it win, not the directory
(AGENTS.md constraint 10).
