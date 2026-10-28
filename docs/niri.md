# Niri

GNOME remains the primary desktop and GDM remains the display manager. The
image keeps Niri installed, but hides its session from GDM until a replacement
for DMS is configured and tested. DMS supplied the locker and idle/suspend
locking; offering the old session without them would allow an unlocked resume.

The replacement shell, locker, notification daemon, polkit agent, PAM files,
and systemd unit definitions belong in the declarative image. Their user
configuration and per-user service enablement belong in the user layer.
Keep local rpm-ostree layering at zero.

## DMS removal

DankMaterialShell (DMS) was removed from the image in October 2026. The last
successful scheduled build on October 20 installed DMS 1.6.3. Starting on
October 21, the COPR supplied DMS 2.0.0 and all three hunks of our lock-screen
patch failed. The patch intentionally used `--forward -F0`, so each build
stopped rather than silently dropping the empty-password submission guard.

The image no longer installs DMS, its COPR, Quickshell, or the QML development
package used for DMS linting. The lock-screen patch, CLI policy, and
`niri.service` drop-in that started `dms.service` are also removed.

## Preparing the replacement session

Keep using GNOME while preparing the replacement. The image overlay at
`files/niri-session-policy/usr/share/wayland-sessions/niri.desktop` sets
`Hidden=true`, which [GDM checks when resolving a session
command](https://github.com/GNOME/gdm/blob/main/daemon/gdm-session.c), as well
as when listing sessions. Remove that overlay and its recipe module in the
change that supplies the tested replacement session.

Migrate `~/.config/niri/config.kdl` before logging into Niri. First copy the
bindings and other settings you want to keep from `~/.config/niri/dms/` into
user-owned configuration, replacing DMS commands with their new equivalents.
Only then remove the old includes. In the existing configuration,
`dms/binds.kdl` contains nearly all bindings, including terminal, exit, and
window management; deleting its include first leaves the session unusable.
Retain at least terminal and exit bindings in the main `binds` block:

```kdl
binds {
    Mod+T { spawn "ghostty"; }
    Mod+Shift+E { quit; }
    Mod+Q { close-window; }
    Mod+Left { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Up { focus-window-up; }
    Mod+Down { focus-window-down; }
}
```

Merge these with the existing block rather than duplicating bindings. The
replacement session must provide:

- A locker, a working manual lock binding, idle locking, and locking before
  suspend that waits until the lock is established. Explicitly install the
  locker and idle manager in the recipe; a weak dependency is insufficient.
  For swaylock, use [`swaylock -e`
  (`--ignore-empty-password`)](https://github.com/swaywm/swaylock/blob/master/swaylock.1.scd) so stray Enter
  presses do not spend PAM faillock attempts. An idle/suspend integration
  using swayidle must use its waiting mode and `swaylock -f -e` so the sleep
  inhibitor is held until the locker is ready (within logind's inhibitor
  delay limit; see the [swayidle manual](https://github.com/swaywm/swayidle/blob/master/swayidle.1.scd)).
  An equivalent replacement must preserve both readiness and empty-password
  behavior.
- A notification daemon owning `org.freedesktop.Notifications` and a polkit
  authentication agent, both started with the Niri session.
- Shell startup, launcher and window-management bindings, and working portals.

Image updates do not migrate home-directory configuration or delete DMS's
old settings and generated files. Validate the migrated config before login:

```sh
niri validate
```

Touchpad/libinput settings belong in Niri's `input {}` block. Niri's touchpad
gestures (three-finger workspace switch, four-finger overview) are hardcoded
and not rebindable.

## Rollout and checks

After the image build has been published:

```sh
ujust update-fromelicks
systemctl reboot
```

This removal keeps **Niri hidden** in GDM. Once a follow-up image provides
the replacement components and restores the session entry, test manual and
idle locking, lock-before-suspend and resume, empty Enter at the lock screen,
notifications, polkit prompts, and the retained key bindings before relying
on the session. Select **GNOME** to return to the primary desktop.

From a Niri session:

```sh
niri validate
systemctl --user status niri.service
niri msg outputs
```

On this hybrid Intel/NVIDIA machine, leave the render device automatic first.
Only add a `render-drm-device` override after checking `niri msg outputs` and
the journal if the first Niri login produces a black screen.

## Xwayland policy

On Silverblue, secureblue's `ujust set-xwayland` changes only the GNOME Shell
service override. It does not control Niri. Since 25.08, Niri creates X11
sockets, exports `DISPLAY`, and starts xwayland-satellite on demand when the
binary is available. This image installs xwayland-satellite, and Niri 26.04
requires version 0.7 or newer. See the [upstream Xwayland
documentation](https://niri-wm.github.io/niri/Xwayland.html).

To keep X11 disabled in the replacement Niri session, add this top-level
block to `~/.config/niri/config.kdl` before starting it:

```kdl
xwayland-satellite {
    off
}
```

Also remove any manual satellite startup or `DISPLAY` override left in the
user configuration. Validate the config and start a fresh session; check that
the Niri journal does not announce an X11 listening socket and that new
applications have no `DISPLAY`. An absent satellite process alone is not
proof: automatic startup is on demand. Removing `off` is a separate opt-in
to X11 for Niri; the GNOME toggle has no effect on that decision.

An intermittent boot-time HDA/PipeWire failure was reproduced in both Niri
and GNOME and cleared by rebooting. If speaker audio is quiet, noisy, or
choppy, follow [`hda-pipewire-xruns.md`](hda-pipewire-xruns.md) before changing
the Niri configuration.
