# Niri with DankMaterialShell

GNOME remains the primary desktop and GDM remains the display manager. The
image also installs Niri and DankMaterialShell (DMS), which adds a `Niri`
choice to GDM without changing the selected/default session.

## Ownership

- Image: the `niri` and `dms` packages, the system-wide
  `niri.service.d/10-dms.conf` integration, DMS CLI policy, and the
  lock-screen QML patch.
- User layer (chezmoi): a minimal `~/.config/niri/config.kdl` integration file
  (including all touchpad/libinput settings, which belong to Niri and have no
  DMS equivalent) and the initial `~/.config/DankMaterialShell/settings.json`.
- Runtime: DMS-generated fragments under `~/.config/niri/dms`, wallpaper
  cache, DMS state, and changes made through DMS settings.

The image drop-in adds `Wants=dms.service` to `niri.service`. This is the
declarative equivalent of `systemctl --user add-wants niri.service dms` and
does not globally enable DMS. In particular, DMS does not start in GNOME or in
GDM's greeter user manager.

The recipe installs AvengeMedia's `quickshell` package explicitly. DMS's RPM
dependency accepts any provider of the virtual `quickshell` capability, which
can otherwise resolve to Terra's `noctalia-qs`. That fork can render the bar,
but its IPC target and display handling is incompatible with DMS.

DMS owns its generated Niri fragments. Chezmoi contains the stable include
points but neither seeds nor overwrites those fragments.

The distro build of DMS normally blocks the entire `dms setup` command tree on
an OSTree system. This includes the component generators even though they only
write user configuration. The image supplies `/usr/share/dms/cli-policy.json`
after the DMS package is installed, retaining the greeter/system-operation
blocks while permitting the component generators. The current policy format
cannot distinguish the interactive parent command from its component
subcommands: do not run bare `dms setup`, because it can request privilege
escalation and add the user to the broad `input` group.

## Lock-screen patch

One defect in `Modules/Lock/LockScreenContent.qml`, not yet fixed upstream as
of DMS 1.6.0.

**Empty submit spends a PAM attempt.** Enter (or the enter button) on an empty
password field calls `pam.passwd.start()`. It cannot succeed, and it consumes a
`pam_faillock` attempt, so a stray Enter moves the session towards a real
lockout for nothing. A new `canSubmitPassword()` guards both submit paths.

The guard is deliberately not unconditional. It still allows an empty submit
when `lockPamExternallyManaged` is set or a custom `lockPamPath` is active,
because there DMS is not driving the stack: the PAM conversation itself may
prompt for an inline u2f or fingerprint touch, and Enter is how the user starts
it. DMS's own u2f path is unaffected either way — upstream resolved that with a
dedicated `lockScreenSecurityKeyShortcut` (issue #2982), not with bare Enter.
This machine runs the bundled `dankshell` PAM stack with u2f and fingerprint
off, so the guard always applies here.

Still present on upstream master as of 2026-09-06. Reported previously as a
different symptom in upstream #1430 ("Login screen loads forever on empty
password").

`canSubmitPassword()` is anchored right after upstream's own
`securityKeyShortcutMatches()`, the last function DMS defines before
`Component.onCompleted` in that block. DMS 1.6.0 added
`triggerSecurityKeyUnlock()` and `securityKeyShortcutMatches()` at the exact
spot this hunk used to target (straight after `canStartSecurityKeyUnlock()`),
which broke the 1.5.3-era patch on 2026-09-04's build — re-anchor here again
if a future release adds another function in the same place.

A second defect this patch used to carry — **Ctrl+Backspace deletes one
character** instead of the previous word, because it fell through to the
plain-Backspace case in the Ctrl branch of the key handler — was **fixed
upstream** in `262acda3`, *"fix(lock): handle ctrl-backspace"* (2026-08-18,
issue #3087), and shipped in DMS 1.6.0 (`case Qt.Key_W: case
Qt.Key_Backspace:` is now stock). That hunk is gone from
`dms-lockscreen.patch`; do not re-add it.

### Mechanics

`files/scripts/patch-dms-lockscreen.sh` applies
`files/scripts/dms-lockscreen.patch` after the dnf module installs `dms`, so
every build patches the version it shipped. The patch applies with
`--forward -F0`: a DMS release that reworks these hunks fails the build rather
than silently dropping the fix or corrupting the file. When that happens,
refresh the patch against the new source, or drop the hunks that landed
upstream. This is exactly what happened between 1.5.3 and 1.6.0: the scheduled
build failed daily from 2026-09-04 through 2026-09-06 until the patch was
rebased against 1.6.0's source layout (see above).

`/usr/share/quickshell/dms` is RPM-owned, so `rpm -V dms` reports
`Modules/Lock/LockScreenContent.qml` as modified. That is expected and is the
only entry it should report.

Touchpad settings are *not* part of this: every libinput setting belongs to
Niri's `input {}` block in the chezmoi-managed `~/.config/niri/config.kdl`, and
DMS exposes none of them. Niri's touchpad gestures (three-finger workspace
switch, four-finger overview) are hardcoded and not rebindable.

## Rollout

After the image build has been published:

1. Preview and apply the user configuration:

   ```sh
   chezmoi diff ~/.config/niri ~/.config/DankMaterialShell/settings.json
   chezmoi apply ~/.config/niri ~/.config/DankMaterialShell/settings.json
   ```

2. Deploy the new image and reboot:

   ```sh
   run0 bootc upgrade
   systemctl reboot
   ```

3. At GDM, use the session chooser to select **Niri** for a test login. Select
   **GNOME** there to return to the normal session. No GDM default is forced by
   this configuration.

   On a new profile, generate the DMS-owned fragments individually after
   booting the image that contains the CLI policy:

   ```sh
   dms setup binds
   dms setup layout
   dms setup colors
   dms setup alttab
   dms setup outputs
   dms setup cursor
   dms setup windowrules
   ```

   Each generator refuses to overwrite an existing non-empty fragment. DMS
   creates `wpblur.kdl` itself when its wallpaper-blur integration needs it.

Useful initial bindings include `Super+T` for Ghostty, `Super+Space` for the
DMS launcher, `Super+,` for DMS settings, `Super+Alt+L` to lock, and
`Super+Shift+E` to end the Niri session.

## Updates and secureblue constraints

DMS 1.5's built-in OSTree updater uses `rpm-ostree`. The initial DMS settings
disable its startup check and route its update action to
`run0 bootc upgrade`. Do not change the custom update action back to the
built-in one: this image requires bootc so recipe kernel arguments are handled
correctly.

Niri and DMS themselves are native Wayland applications. X11 applications in
Niri remain unavailable while secureblue's Xwayland support is disabled. If
needed for Steam or another X11-only application, run `ujust set-xwayland on`
and log out and back in.

## Checks

An intermittent boot-time HDA/PipeWire failure was first noticed after entering
Niri, but was subsequently reproduced in GNOME and cleared by rebooting. If
speaker audio is quiet, noisy, or choppy, do not assume DMS is responsible;
follow [`hda-pipewire-xruns.md`](hda-pipewire-xruns.md) before changing the
Niri or DMS configuration.

From a Niri session:

```sh
niri validate
systemctl --user status niri.service dms.service
niri msg outputs
dms doctor -v
dms ipc call spotlight toggle
```

`dms doctor -v` should report `Quickshell 0.3.1` from AvengeMedia's COPR, not
`noctalia-qs`. Verify the selected provider with:

```sh
rpm -q quickshell noctalia-qs
```

On this hybrid Intel/NVIDIA machine, leave the render device automatic first.
Only add a `render-drm-device` override after checking `niri msg outputs` and
the journal if the first Niri login produces a black screen.
