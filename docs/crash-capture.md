# Crash capture

Why the 2026-08-26 22:35 spontaneous reboot could not be diagnosed, and what
this image now does so the next one can be.

## The incident

At 22:35:08 the screen flashed green, went black, and the machine rebooted
instantly. The journal for that boot ends mid-stride:

```
Aug 26 22:35:08.647834 runuser[56669]: pam_unix(runuser:session): session opened for user licks(uid=1000)
Aug 26 22:35:08.665547 runuser[56669]: pam_unix(runuser:session): session closed for user licks
<nothing>
```

That last pair is the GNOME hang monitor's routine 30-second probe. There is no
`Stopping...`, no `Reached target Shutdown`, no unmount sequence — so this was
not a reboot request. Compare the boots either side: 2026-08-24 and earlier end
with `Unmounting var-home.mount`; this one just stops.

The machine was idle. Last interactive activity was 22:24:02 (a terminal
closing); after that only the monitor's probes every 30 seconds. Temperatures
were normal, the AC adapter was on-line, and there was no OOM, no `NVRM: Xid`,
no DRM reset, no thermal warning, and no soft lockup anywhere in the boot.

## Why there was no evidence — and could not have been

| Capture path | State on this image | Consequence |
|---|---|---|
| Panic message on screen | `kernel.panic=-1` (secureblue `/usr/lib/sysctl.d/55-hardening.conf:97`) | Reboot with **zero** delay. On a KMS console that is a colour flash, not a readable message. |
| `pstore` / EFI | `efi_pstore.pstore_disable=Y` (Fedora default) | Nothing written to EFI NVRAM. |
| `pstore` / ramoops | module present, never loaded, no reserved region | Nothing written to RAM. |
| ACPI firmware error record | no `BERT`/`HEST` tables on this firmware | A fatal machine check would also leave no trace. |
| `kdump` | not configured | No vmcore. |

So `/sys/fs/pstore` was empty and `systemd-pstore.service` skipped on
`ConditionDirectoryNotEmpty`. **Every** capture path was closed. The cause is
genuinely unknown and not recoverable after the fact.

What can be said: with `kernel.panic=-1`, a kernel panic on this machine reboots
in zero seconds, which matches the observed symptom exactly. A firmware- or
hardware-level reset (EC, VRM protection, fatal MCE) produces the same symptom
and is not distinguishable without one of the paths above. `panic_on_oops` is 0
here, so an ordinary oops would *not* reboot — the panic paths that remain are
fatal exceptions in interrupt context, stack guard violations, a triple fault,
or hardware.

One thing worth noting for next time: `NVRM: GPU0 ... PlatformRequestHandler
failed to get target temp from SBIOS` and `failed to get platform power mode
from SBIOS` appear at every boot. The NVIDIA driver cannot read platform thermal
and power state from this Legion's BIOS, so its power arbitration is running
blind. That is not proof of anything, but it is the one standing anomaly in the
GPU/power path, and the green flash points at the display pipeline.

## What the image does now

### The panic stays on screen

`etc/sysctl.d/99-fromelicks-panic-visibility.conf` sets `kernel.panic = 30`.
It overrides secureblue's `-1` because of the **numeric prefix**, not the
directory. `sysctl.d(5)` sorts every file across `/etc`, `/run` and `/usr/lib`
by basename and the lexicographically last one wins; `/etc` only takes
precedence over `/usr/lib` for a file of the *same name*. `99-` sorts after
`55-hardening.conf`, which is what makes this work — so do not renumber it
downwards.

The hardening intent is preserved — the machine still always reboots and never
keeps running on a panicked kernel. It just becomes readable: 30 seconds is
enough to photograph the trace. Delete the file to restore `-1`.

**This makes `ujust audit-secureblue` fail, permanently and by design.**
`audit_secureblue.py:audit_sysctl()` parses every key of `55-hardening.conf` and
compares it against `/proc/sys`; `audit_utils.validate_sysctl` special-cases only
`kernel.sysrq` and `kernel.yama.ptrace_scope`, so `kernel.panic` falls through to
exact equality and the "Ensuring no sysctl overrides" check reports:

```
kernel.panic should be -1, but is actually 30.
```

That is the accepted cost of being able to diagnose a crash at all. Any *other*
sysctl reported by that check is genuine drift and should be investigated —
don't let this one line train you to skim past it.

### The panic is written to RAM and archived

The recipe adds:

```
reserve_mem=2M:4096:oops
ramoops.mem_name=oops
ramoops.ecc=1
```

`reserve_mem=` (kernel ≥ 6.14; this image runs 7.1) declares a *named* 2 MiB
region, and `ramoops.mem_name=` attaches to it by name — so no physical address
is hard-coded, which is what makes blind ramoops configuration dangerous.
`etc/modules-load.d/fromelicks-ramoops.conf` loads the module at boot, since the
`reserve_mem` route has no autoload alias.

Getting those three onto the command line is not as simple as putting them in
the recipe: `kargs.d` is a bootc-only interface and bootc applies it as a delta.
[`kernel-arguments.md`](kernel-arguments.md) has the whole story; the short
version is *update with `bootc upgrade` and verify `/proc/cmdline`*.

The region survives a warm reboot, and `systemd-pstore.service` (already enabled)
archives the record to `/var/lib/systemd/pstore` on the next boot.

EFI pstore is deliberately left disabled: writing panic records into EFI NVRAM is
a known way to brick some firmware. ramoops touches only RAM.

Caveat: ramoops is best-effort. Firmware that clears RAM on reset, or a reset so
abrupt the kernel never runs its panic handler, still captures nothing. That is
why the on-screen path is fixed as well — the two fail in different ways.

### A note on /sys/fs/pstore's mount options

Earlier revisions of this document claimed `/sys/fs/pstore` was mounted `ro` and
would need remounting before `systemd-pstore` could unlink archived records.
**That was wrong**, and the way it was wrong is worth recording.

It is mounted `rw`:

```
$ grep pstore /proc/self/mountinfo
55 46 0:30 / /sys/fs/pstore rw,nosuid,nodev,noexec,relatime shared:11 - pstore none rw,seclabel
```

The `ro` reading came from inspecting `/proc/mounts` inside an agent sandbox that
rbinds `/sys` read-only. In that view `/sys/fs/cgroup` and
`/sys/firmware/efi/efivars` also report `ro`, which is impossible on a running
systemd host — that is the tell. `ujust check-crash-capture` already prints
`findmnt -no OPTIONS /sys/fs/pstore`, which refutes it in one line.

So there is nothing to fix here: `systemd-pstore.service` can copy a record to
`/var/lib/systemd/pstore` *and* unlink it, and the 2 MiB region is cleared
normally after each archive.

The general lesson, since this cost a shipped commit: **never characterise a
mount, a namespace or a `/sys` or `/proc` attribute from inside a sandbox.**
Check it unsandboxed, and cross-check against something whose value you already
know.

### systemd-pstore is not ordered after the ramoops module load

A real gap, found while the above was being disproved.
`systemd-pstore.service` is `DefaultDependencies=no`, `Before=sysinit.target`,
and orders only `After=modprobe@efi_pstore.service`.
`systemd-modules-load.service` — which inserts ramoops from
`etc/modules-load.d/fromelicks-ramoops.conf` — is *also* `DefaultDependencies=no`
and `Before=sysinit.target`, with no ordering relative to it. The two are
scheduled concurrently.

Records only appear in `/sys/fs/pstore` once the ramoops backend registers. If
`systemd-pstore.service` evaluates `ConditionDirectoryNotEmpty` first, it is
skipped and the crash record is lost on the next boot. On the boot where this
was checked, ramoops was inserted at monotonic 45.567 and the condition
evaluated at 47.459 — correct by luck, not by dependency.

The fix mirrors the pattern the unit already uses for EFI pstore:

```ini
[Unit]
Wants=modprobe@ramoops.service
After=modprobe@ramoops.service
```

### ramoops keeps only part 1 of a dump

Found the hard way on **2026-08-31**, when the chain above finally fired for
real. A panic in `skb_clone` was captured, archived, and survived the reboot —
the feature worked. It was still not enough to identify the crash, and the
records said why:

```
pstore: backend (ramoops) writing error (-28)
```

`-28` is `ENOSPC`, but nothing had run out of space: the region is 2 MiB and each
record held about 6 KB. `fs/pstore/ram.c` returns `-ENOSPC` for any record whose
part number is not 1, on an assumption its own comment states — that one record
is larger than pstore's per-dump budget. That assumption did not hold here.
`pstore.kmsg_bytes` is 10240 and ramoops' default `record_size` is 4096, so
`pstore_dump()` split each crash into three parts and ramoops accepted only the
first.

Part 1 is the *oldest* slice of the dump, so what survived was the **tail** of the
backtrace. Everything that identifies a crash is at the top and was dropped:

| In part 1 (kept) | In part 2 (lost) |
|---|---|
| lower stack frames, `Modules linked in`, `end trace` | `Oops:` / `BUG:` line |
| register dump, `Kernel panic - not syncing` | `CPU`/`PID`/**`Comm`** — the process name |
| | faulting `RIP` and the top stack frames |

So the 2026-08-31 panic is diagnosable down to "`skb_clone` on a corrupt `skb`,
in softirq, during local delivery of a locally-generated UDP packet" — and no
further. Which process triggered it is not recoverable from what was stored.

The fix is the condition `ram.c` already assumes: make one record bigger than
`kmsg_bytes`, in `files/rootfs/etc/modprobe.d/ramoops-record-size.conf`:

```
options ramoops record_size=32768
```

Two things to note about that file:

- It is a **modprobe.d option, not a recipe karg**. ramoops is a module, so
  modprobe applies it at load time. That sidesteps the `kargs.d` delta trap in
  [`kernel-arguments.md`](kernel-arguments.md) entirely — no BLS surgery, no
  `bootc`-only path, it lands on the next boot after the image updates. Do not
  "consolidate" it into the `kargs` block.
- Changing `record_size` changes the zone geometry, so the first boot after it
  ships reformats the region and logs `ramoops: error in header`. Any record not
  yet archived at that point is discarded. Harmless once, expected once.
- **The kernel command line beats modprobe.d.** kmod parses `/proc/cmdline`
  itself — that is how `ramoops.mem_name=` and `ramoops.ecc=` reach a *loadable*
  module — and it emits modprobe.d options first, cmdline options last.
  `module_param` takes the last assignment, so a `ramoops.record_size=` karg
  would silently override this file. Verified:

  ```
  $ modprobe -C <dir with 'options ramoops record_size=32768 ecc=99'> -c | grep ramoops
  options ramoops record_size=32768 ecc=99   # the file
  options ramoops mem_name=oops              # /proc/cmdline
  options ramoops ecc=1                      # /proc/cmdline -- this one wins
  ```

  Nothing sets `record_size` on the cmdline today. But note that a BLS
  `x-options-source` pin survives deletion from the recipe, so a karg can
  outlive the recipe line that introduced it and quietly win from there.

### Why the other ramoops settings stay kargs

Only `record_size` moved, and the split is the real boundary rather than an
inconsistency:

| setting | where | why |
|---|---|---|
| `reserve_mem=2M:4096:oops` | karg | core kernel early-boot reservation; absent from `/sys/module/ramoops/parameters/`, and it must happen before any module loads |
| `ramoops.mem_name=oops` | karg | a real module param, but coupled to `reserve_mem` by the literal string `oops` — keeping the pair adjacent stops a rename half-applying |
| `ramoops.ecc=1` | karg | a real module param; could move, but would be a no-op while the BLS pin keeps it on the cmdline, since the cmdline wins |
| `ramoops.record_size` | modprobe.d | never was a karg — it sat at the 4096 default, and nothing on the cmdline contests it |

Raising `pstore.kmsg_bytes` above 10240 is worth considering as well — the
`Modules linked in` list alone is about 3.5 KiB of that budget, and it is printed
twice. But `pstore` is built into the kernel, not a module: `/sys/module/pstore`
has no `initstate`, it is absent from `/proc/modules`, and
`parameters/kmsg_bytes` is `r--r--r--`. There is no modprobe.d or runtime route
to it, only a karg — with everything that implies. `record_size` alone is enough
to make a dump single-part, which is the actual bug.

`ujust check-crash-capture` now compares the two numbers directly, so this is
visible before the next panic rather than after it.

## Checking and reading crash records

```bash
ujust check-crash-capture     # is each capture path actually armed?
ujust show-crash-records      # print anything ramoops preserved
```

`kernel.panic = 30` takes effect on the first boot after the update — it comes
from a `sysctl.d` file, which needs nothing but the new `/usr`.

The ramoops region does **not**. Those three settings are kernel arguments, and
a karg declared in the recipe only reaches the boot loader entry if the
deployment was created by `bootc` — and even then only as a delta against the
booted deployment's `kargs.d`. They were stranded for days by exactly this. If
`ujust check-crash-capture` reports the kargs missing after an update, read
[`kernel-arguments.md`](kernel-arguments.md); it is not a crash-capture problem.

`ramoops: error in header` messages at boot are expected, not a fault. With
`ecc=1` the driver ECC-scans every zone when it attaches, and on first use those
zones hold uninitialized RAM; there were 51 on the first boot with the region
reserved. They stop once each zone has been written.

Note also that `check-crash-capture` counts records with `run0 -i find` on
`/sys/fs/pstore` and `/var/lib/systemd/pstore`. If you dismiss or fail those
polkit prompts it reports `0 entr(ies)` — a confident false negative, not a
blank. Its guard for this was dead code until recently — the `if` tested the
exit status of `wc -l` at the end of the pipeline, which is always 0, so the
"unreadable (needs root)" branch could never run. It now captures `run0`'s own
status first and counts afterwards. Authenticate the prompts either way, or read
the paths directly as root.

To read records by hand:

```bash
ls /sys/fs/pstore/                 # records from the crash just before this boot
ls /var/lib/systemd/pstore/        # archived records, kept 14 days
run0 -i cat /sys/fs/pstore/dmesg-ramoops-0
```

Records are removed from `/sys/fs/pstore` once archived. `kernel.dmesg_restrict=1`
means reading them needs root.

## Testing the whole chain deliberately

Nothing here can be proven by inspection. `systemd-pstore.service` carries
`ConditionDirectoryNotEmpty=/sys/fs/pstore`, so the archive and the unlink are
unreachable until a record actually exists — which means until a crash. If you
would rather find a flaw now than after the next real one, force a panic.

**This is a real crash of a working machine.** Save everything, close what
matters, and expect to lose anything still in the page cache that the sync does
not catch.

```bash
run0 --pipe bash -c 'echo s > /proc/sysrq-trigger'
journalctl -k -n5 | grep "Emergency Sync complete"    # wait for this
run0 --pipe bash -c 'echo u > /proc/sysrq-trigger; echo c > /proc/sysrq-trigger'
```

`s` schedules an emergency sync and returns *immediately* — it is asynchronous,
which is why you wait for `Emergency Sync complete` in dmesg rather than sleeping
a fixed interval. `u` then remounts everything read-only, and `c` dereferences a
NULL pointer to panic on purpose. Both `s` (16) and `u` (32) are already in the
enabled mask.

You should get a trace on screen that stays for 30 seconds — that alone verifies
the `kernel.panic = 30` half — then a reboot.

After it comes back up, three checks in this order:

```bash
journalctl -b -u systemd-pstore.service   # did it run, or hit its condition?
run0 -i ls /var/lib/systemd/pstore/       # the archived copy
run0 -i ls /sys/fs/pstore/                # should now be empty
```

Do **not** expect to see the record in `/sys/fs/pstore` yourself — by the time
you have a shell, `systemd-pstore.service` has already archived and unlinked it,
so an empty directory there is the success case. That a record existed at all is
established by the journal and by the archived copy, never by looking at
`/sys/fs/pstore` after the fact.

The failure worth watching for is the journal reporting `skipped, unmet
condition check ConditionDirectoryNotEmpty=/sys/fs/pstore` on a boot that
followed a real panic — that is the ordering race described above, not a ramoops
failure.

`/var/lib/systemd/pstore` is created by the unit's `StateDirectory=`, so on a
machine that has never archived anything it does not exist and `ls` will say so.
That is expected, not a fault.

Caveats, in the order they are likely to bite:

- **`sysrq-c` is not in the keyboard mask.**
  `etc/sysctl.d/99-sysrq-debug.conf` sets `kernel.sysrq = 176` (sync 16 +
  remount-ro 32 + reboot 128); the crash key needs the debug-dump bit (8). That
  mask governs the *keyboard* combination. Writes to `/proc/sysrq-trigger` are
  supposed to bypass it — `write_sysrq_trigger()` calls `__handle_sysrq()` with
  mask checking off — which is why the recipe above uses the trigger file and not
  Alt+SysRq. Untested here.
- **If the trigger write does nothing, do not just raise the mask.**
  `99-sysrq-debug.conf` states that memory-dump and kernel-debug keys are blocked
  by `lockdown=confidentiality` regardless of the mask, and lockdown is on
  `/proc/cmdline`. Whether that covers `c` specifically has not been established.
  If it does, raising `kernel.sysrq` to 184 achieves nothing while widening the
  mask, so establish which of the two is stopping it before changing anything —
  check `dmesg` for a lockdown denial after the write.
- **ramoops is best-effort even when everything is configured.** A deliberate
  panic is the most favourable case — the kernel reaches its panic handler
  cleanly. A pass here does not guarantee capture from a firmware-level reset.

## If it recurs and ramoops still captures nothing

The next step is `netconsole`, which streams kernel messages over UDP to another
machine and does not depend on anything surviving on the crashing host:

```bash
run0 -i modprobe netconsole \
  netconsole=6665@<this-ip>/<iface>,6666@<remote-ip>/<remote-mac>
# on the receiver:  nc -u -l 6666
```

That is not baked into the image because it needs a second always-on machine on
the same network, but it is the definitive answer if the panic never reaches RAM.
