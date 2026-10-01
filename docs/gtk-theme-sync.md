# GTK3 theme follows the GNOME color scheme

`fromelicks-gtk-theme-sync.service` (user unit, enabled globally by the recipe)
switches `org.gnome.desktop.interface gtk-theme` between `adw-gtk3` and
`adw-gtk3-dark` whenever `color-scheme` changes, and once at login.

## Why

GNOME's Style switch (Settings → Appearance, or the quick-settings Dark Style
toggle) writes only `color-scheme`. GTK3 ignores that key, which is why a dark
desktop gets `gtk-theme='adw-gtk3-dark'`. Nothing ever switches it back. On
2026-10-01 the Legion was on:

```
color-scheme = 'default'          # Style: Light
gtk-theme    = 'adw-gtk3-dark'    # left over from an earlier dark setup
```

This breaks every Chromium/Electron app that is not a flatpak. Claude Desktop
stayed dark on a light desktop. Its own setting is `userThemeMode: "system"`,
which defers to Electron's `nativeTheme`. Chromium (152, in Electron 44) reads
the portal's `org.freedesktop.appearance color-scheme`, but the final
`shouldUseDarkColors` comes from the GTK3 theme's colors. On a portal change
Chromium only sets `gtk-application-prefer-dark-theme`. `adw-gtk3-dark` has no
light variant, so that has no effect. Measured with a probe app on Claude's
exact runtime:

| GTK theme | Start-up | Live switch |
|---|---|---|
| `adw-gtk3-dark`, scheme light | random: dark in 5 of 6 runs | `updated` fires, value never changes |
| `GTK_THEME=adw-gtk3` (env pins it) | light every time | never changes |
| `adw-gtk3` (dconf) | light | dark ↔ light, live |

The portal does emit `SettingChanged` (`color-scheme` → `uint32 1`). The data
is there; the GTK theme overrides it. Flatpak Electron apps (Vesktop) are
unaffected because their GTK never sees the host's `adw-gtk3-dark`.

Keeping both keys in sync also gives non-Chromium GTK3 apps the right variant,
which a fixed `adw-gtk3` would not.

## Behaviour

- `prefer-dark` → `<theme>-dark`; `default` or `prefer-light` → `<theme>`, where
  `<theme>` is the current `gtk-theme` without a `-dark` suffix. So it works
  for any theme shipped as a `Foo`/`Foo-dark` pair, not just adw-gtk3.
- It switches only if the target exists as `themes/<name>/gtk-3.0` on GTK3's
  search path, and otherwise logs and leaves the theme alone.
- It writes only `gtk-theme` and watches only `color-scheme`, so it cannot
  trigger itself.
- Logs: `journalctl --user -u fromelicks-gtk-theme-sync`. One line per actual
  switch.

Under Niri, DankMaterialShell sets both keys itself. The service then sees a
consistent pair and writes nothing.

## Cost

The service is a sleeping `bash` plus `dconf watch` on the single key (about 8 MB).
Idle CPU measured over 20 s: **0 µs**. dconf scopes its D-Bus match rule to the
watched key, so the broker filters everything else. Six writes to sibling keys
produced zero context switches in the watcher; one write to the key produced
exactly one. A real Style change costs one `gsettings get` and one
`gsettings set`.

Rejected alternatives:

- **D-Bus activation** starts a service on a *method call* to its name, never
  on a signal. Reacting to `SettingChanged` needs a resident listener either
  way.
- **A `.path` unit on `~/.config/dconf/user`** would have no resident process.
  But that file is rewritten on *every* dconf write by any app, so each one
  would fork+exec a oneshot, about 3 ms each under the hardening kargs (see
  `desktop-responsiveness.md`). That is more CPU than a watcher that never
  wakes.
- **`gsettings monitor`** subscribes to the whole schema directory and wakes
  for every `org.gnome.desktop.interface` key (clock, fonts, scaling…).

## Sandbox

`systemd-analyze --user security`: **0.4 SAFE** (an unhardened transient user
unit scores 9.4 UNSAFE). `ProtectHome=tmpfs` plus binds expose exactly the session bus, the dconf
database (read-only), dconf's runtime shm flag, and the user theme dirs.
Each option was checked on the Legion (systemd 259) to really apply in the
user manager, not just to be accepted:

- `ProtectProc=invisible`/`ProcSubset=pid` alone are **silently ignored** in a
  user manager: all PIDs and `/proc/meminfo` stayed visible. They take effect
  only together with `PrivatePIDs=yes`, which mounts a fresh `/proc`.
- `PrivatePIDs=yes` makes the script **PID 1** of its namespace. The kernel
  discards signals to a namespace init that has no handler, so the first
  version ignored SIGTERM and `systemctl stop` waited out the full timeout. The
  script therefore has `trap 'exit 0' TERM`. `KillMode=mixed` sends SIGTERM to
  the script alone, and the kernel kills `dconf watch` when its namespace init
  exits. Before this, the watcher could die first and the EOF was logged as a
  failure.
- `PrivateNetwork=yes` is safe: the session bus is a path socket, reachable
  from any network namespace.
- Not added: `IPAddressDeny=` and `DevicePolicy=` need cgroup BPF, which a user
  manager cannot attach. They would lower the score and do nothing.

## Diagnosing from the tool shell

`gsettings` on an interactive `PATH` here may be Homebrew's
(`/home/linuxbrew/.linuxbrew/bin/gsettings`). Its glib has no dconf module, so
it falls back to a keyfile backend: `get` prints schema defaults and `set`
writes `~/.config/glib-2.0/settings/keyfile` instead of changing the desktop.
`G_MESSAGES_DEBUG=all gsettings …` shows `GKeyfileSettingsBackend`. Use
`/usr/bin/gsettings` or `dconf`. The script calls both by absolute path.

## Verifying after `bootc upgrade`

```sh
systemctl --user status fromelicks-gtk-theme-sync
dconf read /org/gnome/desktop/interface/color-scheme
dconf read /org/gnome/desktop/interface/gtk-theme   # matches the scheme
# Toggle Dark Style in quick settings; the journal logs the switch:
journalctl --user -u fromelicks-gtk-theme-sync -n 5
systemd-analyze --user security fromelicks-gtk-theme-sync | tail -1
```
