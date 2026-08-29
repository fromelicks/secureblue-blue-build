# Niri with DankMaterialShell

GNOME remains the primary desktop and GDM remains the display manager. The
image also installs Niri and DankMaterialShell (DMS), which adds a `Niri`
choice to GDM without changing the selected/default session.

## Ownership

- Image: the `niri` and `dms` packages plus the system-wide
  `niri.service.d/10-dms.conf` integration.
- User layer (chezmoi): `~/.config/niri`, initial DMS-generated fragments, and
  the initial `~/.config/DankMaterialShell/settings.json`.
- Runtime: wallpaper cache, DMS state, generated output/cursor rules, and later
  changes made through DMS settings.

The image drop-in adds `Wants=dms.service` to `niri.service`. This is the
declarative equivalent of `systemctl --user add-wants niri.service dms` and
does not globally enable DMS. In particular, DMS does not start in GNOME or in
GDM's greeter user manager.

The DMS-owned files use chezmoi's `create_` attribute. Chezmoi creates their
initial versions but does not overwrite later changes made by DMS.

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
```

On this hybrid Intel/NVIDIA machine, leave the render device automatic first.
Only add a `render-drm-device` override after checking `niri msg outputs` and
the journal if the first Niri login produces a black screen.
