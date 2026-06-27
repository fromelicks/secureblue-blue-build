# WiFi and S2Idle suspend — findings and fix

**Hardware:** Intel Wireless-AC 9560 (CNVi, PCI `8086:7a70`, `00:14.3`) on
Lenovo Legion 5 16IRX9 (Raptor Lake-HX, Intel 700-series PCH).
**Symptom investigated:** WiFi completely absent from GNOME after normal boot,
following an earlier session that used S2Idle suspend.

---

## What happened (root cause chain)

1. **S2Idle sends the CNVi into D3cold.** D3cold is the deepest PCIe power
   state — even PCIe auxiliary power is cut. For this chipset the RF module
   (CNVR, connected to the host-side CNVi over a proprietary bus) loses power
   completely.

2. **CNVR voltage sequencer fails on resume.** When the system wakes, the
   FSEQ (firmware sequencer) on the CNVi tries to bring CNVR back up, but the
   power re-sequencing doesn't complete.  The driver reports this as:
   ```
   CNVR_SCU_SD_REGS_SD_REG_ACTIVE_VDIG_MIRROR: 0x0BADCAFE
   FSEQ_ERROR_CODE: 0x60000000
   NMI_INTERRUPT_UNKNOWN (0x84)
   ```
   `0x0BADCAFE` is the driver's own "never initialized" sentinel — the register
   was never written because the CNVR never came back.

3. **The firmware NMI leaves the device in a stuck-reset state.** The PCIe
   device retains the `CSR_RESET = 0x10` bit across a warm reboot (the PCH
   holds that state until power is cut).  On the next boot the driver times
   out probing (`-ETIMEDOUT / error -110`) because the chip never exits reset.
   WiFi is silently absent — no interface, no error in GNOME settings.

---

## Tradeoff: S2Idle vs S3 on this machine

This image uses `SuspendState=freeze` (S2Idle) configured in
`files/system/etc/systemd/sleep.conf.d/s2idle.conf`. The reason it was chosen
over S3 (deep) is that S3 triggers an NVIDIA DRM re-init race on resume that
causes `EPERM` on `drmModeAtomicCommit` — the display driver transiently fails
to commit a modeset, which manifests as a brief black screen or session glitch.

| Suspend mode | WiFi on resume | NVIDIA DRM on resume |
|---|---|---|
| **S3 (deep)** | Clean — PCIe fully reset | Race: EPERM on drmModeAtomicCommit |
| **S2Idle (freeze)** | Firmware NMI (see below) | Fine |

Neither mode is perfect on this hardware combination.  The current choice is
S2Idle + the D3cold mitigation described below.

---

## Fix applied

### Why D3cold is the lever

D3cold is optional for PCIe devices; the kernel exposes it per-device via
`/sys/bus/pci/devices/<addr>/d3cold_allowed`. Setting it to `0` forces the
device to stay in **D3hot** during suspend — PCIe aux power is maintained, the
PCIe link is preserved, and the CNVR can resume cleanly without re-sequencing
from a dead-power state.

### Files

**`files/system/etc/udev/rules.d/10-intel-wifi-d3cold.rules`**
```
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x8086", ATTR{device}=="0x7a70", ATTR{d3cold_allowed}="0"
```
Sets `d3cold_allowed=0` every time the device is detected — covers boot and S3
cold-resume (where udev re-fires on device re-enumeration).

**`files/system/usr/lib/systemd/system-sleep/10-iwlwifi-d3cold`**
```bash
case "$1" in
  post) echo 0 > /sys/bus/pci/devices/0000:00:14.3/d3cold_allowed ;;
esac
```
Re-applies after every S2Idle wakeup. udev does *not* re-trigger on S2Idle
resume because the device stays enumerated throughout; the sleep hook fills
that gap.

### Observed outcome

After the fix, the firmware NMI on resume **still fires** (same instruction
address: `branchlink2: 0x004D2A06`, NMI code `0x84`), but the device is now
in a state where the iwlmvm firmware-restart mechanism can execute:

- Driver detects the NMI, dumps register state, resets and reloads firmware
- NetworkManager sees the interface momentarily disappear and reconnects
- WiFi is back within ~8 seconds of resume
- No cold reboot required

Before the fix, D3cold left the CNVR in a state where the firmware restart
could not complete — the `CSR_RESET` bit stayed stuck and the device was
unrecoverable until a full power-off.

---

## Residual firmware bug

The NMI at `branchlink2: 0x004D2A06` / `data1: 0x00011F5A` is deterministic
and fires on every resume (and also twice during boot initialization before the
driver succeeds on the third attempt). This is a bug in
`so-a0-jf-b0-77.ucode` (the firmware for the JF/Jeffersonville RF module).
The system ships versions 72, 73, 74, and 77; the driver always picks the
highest. Downgrading to 74 (by removing the 77 file) may eliminate the crash
entirely and give a clean resume with no reconnect delay — not yet tried.

---

## What was tried and reverted

**Modprobe hook** (`files/system/usr/lib/systemd/system-sleep/10-iwlwifi-s2idle`,
committed as `2d51bcf`, reverted in `3fae8e2`):
```bash
pre)  modprobe -r iwlwifi ;;
post) modprobe iwlwifi ;;
```
This works as a workaround — forcing a clean driver reload on every
suspend/resume avoids the stuck-reset state. But it disconnects WiFi for the
full module-reload cycle (~5–10 s), loses any in-progress connections
gracefully rather than abruptly, and is a band-aid over the D3cold issue
rather than a targeted fix. Replaced by the udev rule + sleep hook above.

---

## References and related issues

- [Arch Linux: iwlwifi crashloop resuming from suspend \[SOLVED\]](https://bbs.archlinux.org/viewtopic.php?id=293404) — same symptom on Meteor Lake; workaround is modprobe remove/reload hook
- [kernel.org bugzilla #219597 — iwlmvm: Intel AX200 crashes on resume](https://bugzilla.kernel.org/show_bug.cgi?id=219597) — upstream tracking bug; access gated but referenced widely
- [Ubuntu bug #1987312 — IWLMEI may cause device down at s2idle resume](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/1987312) — IWLMEI (Intel ME WiFi co-management) was the culprit for some kernels; marked broken in v6.0 (`8997f5c8a627`)
- [GitHub gist: Intel BE200 Wi-Fi Resume Fix (D3cold approach)](https://gist.github.com/gornostal/192e2ae29af3da1baeea384d0f19252d) — same D3cold fix applied to newer Intel WiFi 7 generation; confirms the pattern is chipset-family-wide
- [linux-surface #1973 — iwlwifi crash on resume, Alder Lake-P CNVi](https://github.com/linux-surface/linux-surface/issues/1973) — same device class, similar symptom
- [iwlwifi driver documentation](https://wireless.docs.kernel.org/en/latest/en/users/drivers/iwlwifi.html) — `iwlmvm.power_scheme=1` disables runtime power management entirely (blunter alternative; more battery drain)
