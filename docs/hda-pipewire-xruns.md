# Intermittent HDA/PipeWire speaker xruns

**Hardware:** Intel PCH HDA controller (`8086:7a50`, PCI `00:1f.3`, subsystem
`17aa:3832`) with a Realtek ALC257 codec (codec subsystem `17aa:3cb8`) on the
Lenovo Legion 5 16IRX9.

**Incident:** On 2026-08-30, all output through the internal speakers was
quiet, noisy, choppy, and repeatedly sputtered. The problem was first noticed
after installing and entering Niri with DankMaterialShell (DMS), but it was
later reproduced unchanged in GNOME. A normal reboot restored clean audio in
both GNOME and Niri without any configuration change.

This is currently an **intermittent boot-time failure**, not a permanent image
workaround. Do not attribute it to Niri or enable the workaround below merely
because it happened once.

---

## What was observed

The PipeWire client stream remained healthy, but the physical ALSA sink
accumulated errors continuously during playback:

```text
S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME
R   61   2048  48000  17.3us  36.4us  0.00  0.00  116 S32LE 2 48000  alsa_output.pci-0000_00_1f.3.analog-stereo
```

PipeWire debug logging showed the sink buffer draining and being restarted
roughly every 0.6 seconds:

```text
pw.node ... XRun!
spa.alsa ... snd_pcm_drop
spa.alsa ... do_prepare
spa.alsa ... snd_pcm_start
```

The bad boot used PipeWire's normal timer-based ALSA scheduling:

```text
api.alsa.disable-tsched = false
api.alsa.period-size = 0
api.alsa.headroom = 0
api.alsa.htimestamp = false
```

The HDA driver also used its automatic defaults:

```text
snd_hda_intel.position_fix = -1
snd_hda_intel.bdl_pos_adj = -1
snd_hda_intel.enable_msi = -1
snd_hda_intel.power_save = 10
snd_hda_intel.power_save_controller = Y
```

After reboot, the same PipeWire and kernel settings played the same test at
48 kHz/S32LE/2048 frames with `ERR=0`. Logging out of the working GNOME
session and into Niri without rebooting also remained at clean quality.

---

## What was ruled out

- **Niri and DMS:** The failure persisted with DMS stopped. PipeWire and
  WirePlumber were also restarted while DMS remained stopped; errors still
  increased from `0` to `5` during a four-second test. After the recovery
  reboot, both GNOME and Niri were clean.
- **GNOME vs. Niri configuration:** The bad audio was reproduced in GNOME on
  the same boot. There are no user or system PipeWire/WirePlumber overrides.
- **SELinux:** No relevant AVC denials were recorded. PipeWire, WirePlumber,
  DMS, and Quickshell had normal access to the audio graph.
- **CPU or realtime starvation:** PipeWire's data loop ran as `SCHED_RR` at
  priority 20. Processing took tens of microseconds against a multi-millisecond
  quantum, with no material CPU or IO pressure.
- **Buffer/quantum sizing:** Forcing a 1024-frame graph quantum did not stop
  the xruns.
- **ACP profile or `front:0`:** The Pro Audio profile failed in the same way.
- **The raw ALSA/hardware path:** Direct `aplay` through `hw:0,0` completed
  without underruns using both `RW_INTERLEAVED` and `MMAP_INTERLEAVED`. The
  mmap test also succeeded with PipeWire's 1024-frame hardware period and
  32768-frame hardware buffer.
- **A contemporaneous image, kernel, or BIOS update:** The last working GNOME
  boot and the first Niri test used OSTree deployment `f26a54c...`, kernel
  `7.1.10-200.secureblue.1.fc44.x86_64`, and BIOS `NMCN34WW`. One retained
  boot contained GNOME followed by Niri without a reboot. The same BIOS had
  been recorded since at least June, and `fwupdmgr get-history` was empty.

Windows can deliver system and device firmware through UEFI capsules, so an
unrecorded Windows-delivered device-firmware change cannot be disproved in
general. It is a poor explanation for this incident: the failure/recovery
tracked Linux boots, not a firmware-version change, and clean GNOME and Niri
were demonstrated within one boot after recovery.

---

## Working hypothesis

The most likely mechanism is a transient HDA controller/codec initialization
state in which PipeWire's timer scheduler receives inaccurate or badly phased
hardware-position information. PipeWire then predicts the next wakeup too
late, drains the ALSA ring buffer, drops and prepares the PCM, and repeats.

This is a mechanism-level diagnosis, not a proven kernel root cause. In
particular, no permanent `snd_hda_intel.position_fix` value has been tested.
Do not add a modprobe override without a recurrence and controlled comparison;
the wrong position method can create different timing faults.

PipeWire's IRQ scheduling avoids dependence on the failing timer prediction.
During the bad boot, changing only `api.alsa.disable-tsched` from `false` to
`true` produced a complete test with `ERR=0`. Reverting it immediately brought
the xruns back.

---

## Triage if it recurs

First verify that the physical sink, rather than only an application stream,
is accumulating errors. Start ordinary audio and run:

```sh
pw-top -b -n 5 | rg 'ERR|alsa_output\.pci-0000_00_1f\.3'
```

Resolve the current sink ID and inspect its scheduling mode:

```sh
sink_id=$(
  wpctl status -n |
    sed -n 's/^.*\* *\([0-9][0-9]*\)\. alsa_output\.pci-0000_00_1f\.3\.analog-stereo.*$/\1/p'
)
test -n "$sink_id"
pw-cli enum-params "$sink_id" Props |
  rg -A1 'period-size|headroom|disable-batch|disable-tsched|htimestamp'
```

Also capture the boot and driver state before changing anything:

```sh
uname -r
cat /sys/class/dmi/id/bios_version
journalctl -b -k --no-pager |
  rg 'snd_hda|hdaudio|ALC257|00:1f\.3'

for parameter in position_fix bdl_pos_adj enable_msi power_save power_save_controller; do
  printf '%s=' "$parameter"
  cat "/sys/module/snd_hda_intel/parameters/$parameter"
done
```

Recovery order:

1. Reboot normally and retest before changing configuration.
2. If a warm reboot does not help, power off fully, disconnect AC and USB
   devices, wait approximately 30 seconds, and boot again.
3. If the machine was last used in Windows, a one-time
   `shutdown /s /t 0` there excludes Windows Fast Startup's hybrid shutdown.
4. If the problem remains, test the runtime IRQ workaround below.

---

## Runtime IRQ workaround

This changes only the current PipeWire node and is lost when WirePlumber
recreates it:

```sh
sink_id=$(
  wpctl status -n |
    sed -n 's/^.*\* *\([0-9][0-9]*\)\. alsa_output\.pci-0000_00_1f\.3\.analog-stereo.*$/\1/p'
)
test -n "$sink_id"
pw-cli set-param "$sink_id" Props \
  '{ params = [ api.alsa.disable-tsched true ] }'

pw-cli enum-params "$sink_id" Props |
  rg -A1 'disable-tsched'
```

Play audio and confirm that the physical sink remains at `ERR=0` in `pw-top`.
To revert it without logging out:

```sh
pw-cli set-param "$sink_id" Props \
  '{ params = [ api.alsa.disable-tsched false ] }'
```

---

## Persistent fallback — not currently enabled

If this becomes frequent or survives cold boots, add an image-owned
WirePlumber fragment at:

```text
files/rootfs/usr/share/wireplumber/wireplumber.conf.d/99-fromelicks-legion-hda-irq.conf
```

```ini
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output[.]pci-0000_00_1f[.]3[.].*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.disable-tsched = true
      }
    }
  }
]
```

The rule is scoped to output nodes on the affected PCH controller and covers
both the Analog Stereo and Pro Audio node names. It belongs in the image, not
chezmoi: this is a machine-wide hardware compatibility policy. `/usr/share`
is appropriate for the custom image's vendor configuration and avoids
creating mutable `/etc` drift.

Do not enable it pre-emptively. IRQ scheduling was completely clean during
the incident, but timer scheduling was also completely clean after reboot.
Keeping the default avoids imposing a non-default scheduling mode and its
possible interrupt/power cost when the hardware initializes correctly.

---

## References

- [PipeWire ALSA node properties](https://pipewire.pages.freedesktop.org/pipewire/page_man_pipewire-props_7.html) — `api.alsa.disable-tsched`, `headroom`, timestamps, and buffer controls
- [WirePlumber ALSA configuration](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html) — timer scheduling, delayed hardware pointers, and `monitor.alsa.rules`
- [Microsoft: Fast Startup](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/fast-startup-causes-system-hibernation-shutdown-fail) — hybrid shutdown versus a full restart/shutdown
- [Microsoft: Windows UEFI firmware update platform](https://learn.microsoft.com/en-us/windows-hardware/drivers/bringup/windows-uefi-firmware-update-platform) — system and device firmware delivered through UEFI capsules
