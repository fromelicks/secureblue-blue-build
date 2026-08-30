# Niri with DankMaterialShell

GNOME remains the primary desktop and GDM remains the display manager. The
image also installs Niri and DankMaterialShell (DMS), which adds a `Niri`
choice to GDM without changing the selected/default session.

## Ownership

- Image: the `niri` and `dms` packages, the system-wide
  `niri.service.d/10-dms.conf` integration, and DMS CLI policy.
- User layer (chezmoi): a minimal `~/.config/niri/config.kdl` integration file
  and the initial `~/.config/DankMaterialShell/settings.json`.
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
