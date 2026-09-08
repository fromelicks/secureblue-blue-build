# GDM greeter on the external monitor

**Hardware:** Lenovo Legion 5 16IRX9. Built-in AUO `B160QAN03.L` panel
(2560x1600, `eDP-1` on the i915 card) sits closed on a shelf; the only display
actually used is a CHD `24MC635` (1920x1080@75) on the NVIDIA card's HDMI
output, which the kernel names `card0-HDMI-A-5` and mutter names `HDMI-5`.

**Symptom:** the GNOME session and Niri both honour the external-only layout,
but the GDM greeter draws on the built-in panel on every boot, so unlocking at
the login screen means opening the laptop.

---

## Why the greeter ignores the session layout

The greeter is a separate mutter instance with its own configuration. With no
`monitors.xml` of its own it applies mutter's built-in default: enable every
connected output and make the laptop panel primary. The login dialog lives on
the primary logical monitor, so it lands on `eDP-1`.

There is no dconf key, no `custom.conf` option and no `gsettings` toggle for
this. Giving the greeter a `monitors.xml` is the only supported mechanism.

## The path is not `/var/lib/gdm/.config`

Practically every guide online says to copy `~/.config/monitors.xml` to
`/var/lib/gdm/.config/monitors.xml`. On GDM 50 (Fedora 44 / GNOME 50) that
directory **does not exist and is not read**.

The greeter no longer runs as the static `gdm` account (uid 42, still present in
`/usr/lib/sysusers.d/gdm.conf`). It runs as a *dynamic* user — `gdm-greeter`,
uid 60578 on this machine, the same one that makes globally enabled user units
start before login (see AGENTS.md constraint 11) — and GDM sets that session's
`XDG_CONFIG_HOME` to a per-seat directory:

```console
$ strings /usr/sbin/gdm | grep -E 'XDG_CONFIG_HOME|/var/lib/gdm'
XDG_CONFIG_HOME
/var/lib/gdm
/var/lib/gdm/.config
/var/lib/gdm/.migrated-dyn-users
/var/lib/gdm/seat0/config
/var/lib/gdm/seat0/state
```

`/var/lib/gdm/.config` survives in the binary only as the pre-migration path
that `.migrated-dyn-users` records having moved away from. The live path is:

```text
/var/lib/gdm/seat0/config/monitors.xml
```

Because mutter resolves it through `g_get_user_config_dir()`, a file at the old
location is not a fallback — it is simply never opened, silently.

## Why this needs a boot-time unit, not the files module

`/var/lib/gdm` is under `/var`, which an ostree/bootc image only populates at
install time; content added there later in the image is never applied to an
existing system. So the layout ships read-only in `/usr` and is copied into
place at boot:

| Path | Role |
|---|---|
| `files/rootfs/usr/share/fromelicks/gdm-monitors.xml` | the layout itself |
| `files/rootfs/usr/libexec/fromelicks-gdm-monitors` | copies it into every `/var/lib/gdm/seat*/config` |
| `files/rootfs/usr/lib/systemd/system/fromelicks-gdm-monitors.service` | oneshot, `Before=gdm.service`, `WantedBy=graphical.target` |

The greeter's uid is allocated dynamically, so the installer makes no assumption
about ownership: the file goes in `0644` and inherits the config directory's
owner via `chown --reference`, which stays readable whether GDM has chowned that
directory to the dynamic user or left it to root. It is relabelled with
`restorecon` so it gets `xdm_var_lib_t` rather than the `/usr/share` context.

## How mutter matches a configuration block

A `<configuration>` applies only when the set of connected monitors matches it
exactly, comparing all four `<monitorspec>` fields — `connector`, `vendor`,
`product`, `serial`. Consequences worth knowing:

- Moving the cable from HDMI to DisplayPort renames the connector (`HDMI-5` →
  `DP-4`) and stops matching. The shipped file therefore repeats the layout for
  `HDMI-5`, `DP-4` and `DP-3`, which are the ports this display has used.
- Closing the lid makes `eDP-1` *disconnected*, not merely disabled, which is a
  different monitor set again — hence the second group of blocks listing the
  external display alone.
- **No match is safe.** Mutter falls back to its default (all outputs on, panel
  primary), so booting with the external display unplugged still gives a usable
  greeter on the laptop panel.

`<product>` is the EDID monitor-name descriptor when the display supplies one
(`24MC635`), not the numeric product code (`0x2380`) that shows up for displays
without that descriptor, such as the internal panel (`0xc1a5`).

## Keeping it in sync with the session

The shipped file mirrors the session layout in `~/.config/monitors.xml`:
external primary at 1920x1080@75, `eDP-1` in `<disabled>`. If the session layout
changes — a new display, a different port, a different mode — regenerate the
greeter copy from it, since nothing keeps the two in step automatically.

Note that `~/.config/monitors.xml` is per-user runtime state (user layer, not
image); only the greeter copy is declarative.

## Verifying

After a rebuild and `bootc upgrade` + reboot:

```console
$ systemctl status fromelicks-gdm-monitors.service
$ run0 cat /var/lib/gdm/seat0/config/monitors.xml   # should match /usr/share
$ journalctl -t fromelicks-gdm-monitors -b
```

Then reboot once more and confirm the login screen appears on the external
display. If it does not, the usual cause is a connector name that no longer
matches. Mutter derives its name from the DRM connector by dropping the `-A`
suffix of the type: kernel `card0-HDMI-A-5` becomes `HDMI-5`, while
`card0-DP-4` stays `DP-4`. List what is currently attached with:

```console
$ for c in /sys/class/drm/card*-*; do
    printf '%s\t%s\n' "${c##*/}" "$(cat "$c/status")"
  done
$ niri msg outputs        # names and modes as the session sees them
```
