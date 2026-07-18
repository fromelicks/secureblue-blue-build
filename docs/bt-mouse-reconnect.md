# Bluetooth mouse slow reconnect after S2Idle suspend

**Hardware:** Logi POP Mouse (BLE HID, `046D:B030`), Intel AX201 BT adapter
(`8087:0aaa`, USB `1-14`) on Lenovo Legion 5 16IRX9.

**Symptom:** After a short suspend (< ~1 min) the mouse reconnects in ~10 s.
After a long suspend (several hours) the mouse takes 3+ minutes to reconnect,
or appears not to reconnect until moved.

---

## Root cause chain

1. **Mouse enters slow-advertising mode during suspend.** When the BLE
   connection is lost (the laptop suspends), the mouse detects a supervision
   timeout (~20 s) and begins advertising. It fast-advertises (~100 ms interval)
   for ~30 s, then switches to slow advertising (~2 s interval) or stops
   advertising entirely and enters a deep-sleep mode.

2. **After a long suspend, the fast-advertising window is long gone.** By the
   time the laptop resumes hours later, the mouse is in slow-advertising or
   dormant mode. It resumes advertising only when physically moved.

3. **BlueZ passive scanning misses slow advertisements.** After resume, BlueZ's
   auto-connect mechanism actively scans for ~60 s (`AutoConnectTimeout`), then
   falls back to lower-rate background scanning. The combination of a 2+ second
   advertisement interval and conservative background scan parameters means
   BlueZ may not catch an advertisement for minutes.

4. **WiFi/BT coexistence on the Intel CNVi makes it worse.** The WiFi and BT
   share the same silicon. Immediately after resume, WiFi is reconnecting
   (higher traffic) and the coexistence arbiter may suppress BLE scan slots,
   further reducing the chance of catching early advertisements.

---

## Fixes applied

### `files/system/etc/modprobe.d/btusb-no-autosuspend.conf`

```
options btusb enable_autosuspend=0
```

Prevents `btusb` from calling `usb_enable_autosuspend()` on the Intel BT USB
adapter. Without this, the adapter can enter USB runtime autosuspend after 2 s
of idle. BLE HID devices cannot issue a USB remote-wakeup, so if the adapter
suspends it never recovers without a reboot. This is a separate issue from the
slow-reconnect problem above but addresses the permanent-disconnect case.

### `files/system/usr/lib/systemd/system-sleep/20-bt-reconnect`

Before suspend: saves the list of currently connected BT devices to
`/run/bluetooth-connected-before-suspend`.

After resume: issues `bluetoothctl connect <mac>` for each saved device in a
background subshell, retrying 3 times with 30-second gaps. This triggers an
explicit `HCI_LE_Create_Connection` rather than waiting for passive scanning to
catch a slow advertisement. Only devices that were connected at suspend time are
reconnected — not all paired devices.

---

## Observed reconnect times

| Suspend duration | Reconnect time before fix | Expected after fix |
|---|---|---|
| Short (< 1 min) | ~10 s | ~5–10 s (no change) |
| Long (several hours) | 3–5 min (requires moving mouse) | ~5–35 s after moving mouse |

The fix doesn't change when the mouse starts advertising — that still requires
moving the mouse. It makes the host catch that first advertisement immediately
instead of potentially missing several slow-interval cycles.

---

## What was investigated

- **USB autosuspend** (`/sys/bus/usb/.../power/runtime_status`): confirmed
  `active` during the second-set disconnect — not the cause of slow reconnect.
- **btmon HCI capture**: `le-connection-abort-by-local` (0x44) seen once due to
  stale bond after user put mouse into pairing mode; resolved by re-pairing.
- **D3cold (WiFi PCIe)**: `d3cold_allowed=0` controls the PCIe power state of
  the WiFi CNVi interface, not the BT USB adapter (`1-14`). Not a factor for
  BT reconnect speed.
- **BlueZ `AutoConnectTimeout`**: Default 60 s is not the bottleneck — the
  mouse's slow-advertising rate and background scan miss probability are.
  Leaving at default.

---

## Continuous HCI capture for the mid-session disconnect

`btmon-capture.service` records controller `hci0` continuously so the next
random disconnect retains the HCI reason and preceding encryption events. It
starts a new btsnoop file daily under `/var/lib/bluetooth-captures/`; files are
root-only and inactive captures are deleted after 14 days.

The capture covers the whole Bluetooth controller, not only the mouse, and can
contain sensitive HID or other Bluetooth traffic. After reproducing the fault:

```bash
sudo systemctl stop btmon-capture.service
sudo ls -lh /var/lib/bluetooth-captures/
sudo btmon --read /var/lib/bluetooth-captures/<capture>.btsnoop
```

Stop the service promptly after reproduction to preserve the relevant file and
avoid collecting unrelated traffic. Remove it from the recipe once diagnosis
is complete.
