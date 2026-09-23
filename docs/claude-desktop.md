# Claude Desktop

The Claude desktop app (Linux beta) is installed on the host, in the image, by
`files/scripts/install-claude-desktop.sh`. Anthropic only publishes it for
Ubuntu/Debian, as a `.deb` in an apt repository. There is no RPM or dnf repo,
and the docs point Fedora users to the CLI. The payload is a self-contained
Electron app, so the image unpacks it directly. A Debian distrobox was the
fallback, but it would need a new trusted registry in the default-reject
container policy (open decision 1 in `AGENTS.md`), and it gains nothing.

## What the `.deb` contains

Everything lives under `/usr`, so it survives on an atomic image, unlike `/opt`
or `/usr/local`:

- `/usr/lib/claude-desktop/`: the Electron app, including a bundled
  `virtiofsd` and `cowork-linux-helper`
- `/usr/bin/claude-desktop`: a symlink into the above
- `/usr/share/applications/com.anthropic.Claude.desktop`, hicolor icons

Every shared library resolves against Fedora 44. The declared `Depends:` are
all standard GTK/NSS/libdrm libraries that the base already has.

The maintainer scripts are **not** run. `postinst` writes an AppArmor userns
profile, which is irrelevant on SELinux, and registers the apt repo and
unattended-upgrades snippet, which are useless without apt. Its third job, the
GNOME Shell search provider (`.ini` + D-Bus `.service` running a GJS script),
is replicated by the install script.

## Supply chain

The same chain apt uses, with the key pinned in the repo:

1. `files/scripts/claude-desktop-archive-keyring.asc`, taken from the package's
   own `postinst`. Its fingerprint `31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE`
   matches `https://downloads.claude.ai/claude-desktop/key.asc` and Anthropic's
   install docs. The script re-checks the fingerprint.
2. `gpgv` verifies `dists/stable/InRelease` against it. An expired
   `Valid-Until` fails the build, as it would in apt.
3. The SHA256 from `InRelease` verifies `Packages`, and the SHA256 from
   `Packages` verifies the `.deb`.

The newest version in the index is taken on every build. The daily 06:00 UTC
rebuild is therefore the update channel: the app never updates itself on
Linux. If Anthropic ever rotates the key, the build fails at step 2. Replace
the `.asc` file and the `fingerprint=` line together.

## hardened_malloc

Electron aborts under secureblue's global hardened_malloc preload, as VS Code
does (see [`vscode-hardened-malloc.md`](vscode-hardened-malloc.md)):

```
$ /usr/lib/claude-desktop/claude-desktop
fatal allocator error: invalid uninitialized allocator usage
Aborted
```

`/usr/bin/claude-desktop` is therefore replaced with a wrapper that runs
through `/usr/bin/with-standard-malloc`. The `.desktop` file and both of its
actions (New Chat, New Claude Code Session) run the bare `claude-desktop`, so
they reach the wrapper through `PATH` without being edited. The script fails
the build if any `Exec=` line stops doing that.

VS Code also needed a `profile.d` hook, because its environment probe
re-launches Electron in node mode from a login shell. Claude Desktop's probe
runs `env -0` in the login shell instead, so nothing Electron-based runs there.
Checked on a running instance: every Electron process (zygote, GPU, renderers,
utility) had no `LD_PRELOAD`. Only `chrome_crashpad_handler` had it, and that
is plain C++ that runs fine under hardened_malloc. Terminals and Claude Code
sessions started from the app get the resolved login environment, so they keep
hardened_malloc like any other shell.

## Icon and URL-handler caches

GNOME does not read `/usr/share/icons/hicolor` and `/usr/share/applications`
directly; it reads `icon-theme.cache` and `mimeinfo.cache`. Both are generated
by RPM scriptlets during the dnf module, which runs *before* this script, so
the first version of this install shipped the icon files but no cache entry:
the app grid showed a blank tile, and `claude://` links had no handler.

GTK normally notices a cache older than its directory and falls back to
scanning. That cannot happen here: ostree sets every mtime to epoch 0, so the
cache never looks stale and GTK trusts it completely.

The script therefore ends by running `gtk-update-icon-cache --force` and
`update-desktop-database`, then greps both caches for the new entries, because
the whole failure mode is a cache that is silently out of date. The icon cache
is binary and `strings` can prepend a stray byte to the name, so that grep
anchors only the end of the line.

Any future module that drops files into either directory after the dnf step
needs the same treatment.

## Chromium sandbox

The `.deb` ships `chrome-sandbox` as `4755 root`, as a fallback for systems
without unprivileged user namespaces. Here the namespace sandbox works: the
app ran from an unpacked copy in a user directory, where SUID cannot apply.
The script therefore drops the bit (`0755`), leaving one fewer setuid binary.
If userns is ever restricted, the app fails to start with "No usable sandbox".
Restore `4755` in the script in that case, and do not launch with
`--no-sandbox`.

## Display

It runs as a native Wayland client (`--ozone-platform=wayland`) on the Intel
iGPU render node, so secureblue's disabled Xwayland is not a problem. The
Quick Entry global hotkey needs the GlobalShortcuts portal on Wayland.

## Cowork

Cowork runs its tasks in a QEMU/KVM VM that the app hosts. `qemu-system-x86`,
`edk2-ovmf` and `virtiofsd` are already in the image, and the app also bundles
its own `virtiofsd`. It additionally needs `/dev/vhost-vsock`, which only
`kvm` group members can open (`sudo modprobe vhost_vsock` if the module is not
loaded). This is untested on this machine. Chat and Claude Code do not need it.

## Verifying after `bootc upgrade`

```sh
rpm -qf /usr/lib/claude-desktop 2>&1   # "not owned by any package": expected
cat /usr/lib/claude-desktop/version
cat /usr/bin/claude-desktop            # the with-standard-malloc wrapper
claude-desktop                         # or "Claude" in the app grid

# The app grid icon: both must print a match
strings /usr/share/icons/hicolor/icon-theme.cache | grep claude-desktop
grep x-scheme-handler/claude /usr/share/applications/mimeinfo.cache
```
