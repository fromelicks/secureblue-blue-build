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

**Verify after the first update that actually applies the kargs** (see
[`kernel-arguments.md`](kernel-arguments.md) — this is not automatic):
`/sys/fs/pstore` is currently mounted `ro`,
with no fstab entry, no mount unit, and nothing in secureblue that remounts it —
so this is the kernel's own doing while no writable backend is registered. It
should become `rw` once ramoops attaches. If `ujust check-crash-capture` still
shows `ro` once the region is reserved, `systemd-pstore.service` will be able to copy
records but not unlink them, so the 2 MiB region will fill up and stop capturing
after the first crash. The fix in that case is a `systemd-pstore.service`
drop-in that remounts it first:

```ini
[Service]
ExecStartPre=/usr/bin/mount -o remount,rw /sys/fs/pstore
```

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

Note also that `check-crash-capture` uses `run0 -i find` on `/sys/fs/pstore` and
`/var/lib/systemd/pstore`. If you dismiss or fail those polkit prompts, those
sections print nothing — which looks identical to "no records".

To read records by hand:

```bash
ls /sys/fs/pstore/                 # records from the crash just before this boot
ls /var/lib/systemd/pstore/        # archived records, kept 14 days
run0 -i cat /sys/fs/pstore/dmesg-ramoops-0
```

Records are removed from `/sys/fs/pstore` once archived. `kernel.dmesg_restrict=1`
means reading them needs root.

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
