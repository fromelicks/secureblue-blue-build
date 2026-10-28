# Niri

GNOME remains the primary desktop and GDM remains the display manager. The
image also installs Niri, which adds a `Niri` choice to GDM without changing
the selected/default session. The shell and its configuration belong in the
user layer.

## DMS removal

DankMaterialShell (DMS) was removed from the image in October 2026. The last
successful scheduled build on October 20 installed DMS 1.6.3. Starting on
October 21, the COPR supplied DMS 2.0.0 and all three hunks of our lock-screen
patch failed. The patch intentionally used `--forward -F0`, so each build
stopped rather than silently dropping the empty-password submission guard.

The image no longer installs DMS, its COPR, Quickshell, or the QML development
package used for DMS linting. The lock-screen patch, CLI policy, and
`niri.service` drop-in that started `dms.service` are also removed.

Before using Niri with a replacement shell, update the user configuration:
remove DMS commands and includes of DMS-generated fragments from
`~/.config/niri/config.kdl`, and configure the replacement shell's startup,
bindings, and screen locker. Image updates do not migrate home-directory
configuration or delete DMS's old settings and generated files.

Touchpad/libinput settings belong in Niri's `input {}` block. Niri's touchpad
gestures (three-finger workspace switch, four-finger overview) are hardcoded
and not rebindable.

## Rollout and checks

After the image build has been published:

```sh
run0 bootc upgrade
systemctl reboot
```

Select **Niri** in GDM's session chooser for a test login. Select **GNOME**
there to return to the primary desktop.

From a Niri session:

```sh
niri validate
systemctl --user status niri.service
niri msg outputs
```

On this hybrid Intel/NVIDIA machine, leave the render device automatic first.
Only add a `render-drm-device` override after checking `niri msg outputs` and
the journal if the first Niri login produces a black screen.

Niri is a native Wayland compositor. X11 applications in Niri remain
unavailable while secureblue's Xwayland support is disabled. If needed for
Steam or another X11-only application, run `ujust set-xwayland on` and log out
and back in.

An intermittent boot-time HDA/PipeWire failure was reproduced in both Niri
and GNOME and cleared by rebooting. If speaker audio is quiet, noisy, or
choppy, follow [`hda-pipewire-xruns.md`](hda-pipewire-xruns.md) before changing
the Niri configuration.
