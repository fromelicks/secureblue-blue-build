# MATLAB R2026a + Simulink in a distrobox

Short answer to "is this even possible": yes. One secureblue precondition is
hard (container userns), one is a choice between four display paths, and the
container is a better place for MATLAB than the host is.

## What is in the image

| Path | Purpose |
|---|---|
| `/etc/distrobox/matlab.ini` | assemble manifest **template** |
| `/etc/distrobox/matlab-products.txt` | mpm product list **template** |
| `/usr/libexec/fromelicks-matlab-box-setup` | init hook that installs everything inside the container |
| `ujust matlab-box` / `check-matlab-box` / `remove-matlab-box` / `reset-matlab-install` | preflight + drive `distrobox assemble` |

Both files in `/etc` are templates. `ujust matlab-box` copies them to
`~/.config/distrobox/` on first run and works from the copies. The license
server address and the product set are both per-machine — one is site
configuration, the other depends on which hardware support packages are worth
installing — so neither belongs in a layer published to a registry, and
**editing them in `/etc` would permanently dirty `ostree admin config-diff`**
against design principle 4. Edit the copies.

## The four things that actually decide whether this works

### 1. MATLAB is an X11 client, and it needs *an* X server — not necessarily GNOME's

MathWorks ships no Wayland backend. The MATLAB desktop, every Simulink model
window and every figure window is an X11 client.

What secureblue's toggle actually does is narrower than it sounds. The override
it drops at `/etc/systemd/user/org.gnome.Shell@user.service.d/override.conf` is
exactly two lines:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --mode=%i --no-x11
```

That disables **Mutter's built-in Xwayland**. It does not remove
`/usr/bin/Xwayland`, which is still present and still startable by anything that
wants to run its own X server. So there are four ways to give MATLAB a display,
in rough order of preference:

| Path | Needs `set-xwayland on`? | Notes |
|---|---|---|
| Run the session under **Niri** | no | `xwayland-satellite` runs a standalone rootless Xwayland; secureblue's GNOME-only toggle never touches it. Already installed. Cleanest option — nothing to configure. |
| **Xpra** seamless mode | no | `xpra` 6.5.3 is already in the recipe. X server inside the container, one native client-side window per X window, client speaks Wayland. See below. |
| GNOME with `ujust set-xwayland on` | yes | Simplest, best-integrated, and a deliberate security reduction. Read what the recipe prints before accepting it. |
| **gamescope** | no | It embeds its own Xwayland (`GAMESCOPE_XWAYLAND_SERVER_ID` in the binary), so it genuinely works — but it is a single-fullscreen-window nested compositor. MATLAB is a multi-top-level-window IDE. Technically possible, practically miserable. Use it for Steam, not this. |

`matlab-proxy` is a fifth option that avoids X entirely by serving the desktop
over HTTP to a browser. Not wired up here.

#### Xpra, concretely

Xpra is the way to keep `--no-x11` on GNOME and still get real windows. The
server runs *inside* the box on a virtual display and the client runs on the
host as a native Wayland application:

```sh
# inside the box
distrobox enter matlab -- xpra start :100 --start='/usr/local/bin/matlab -desktop'
# on the host
xpra attach :100
```

Both halves of xpra are already installed: the host gets it from the recipe,
and the container from `additional_packages` in the manifest. Pinning the
socket under `/tmp` is worth doing — distrobox bind-mounts `/tmp` into the box,
so `--socket-dir=/tmp/xpra` on both sides needs no further plumbing. Two caveats
worth knowing up front: MATLAB's post-R2023b
desktop is CEF/Chromium and composites more than xpra likes, and figure windows
want OpenGL, so `matlab -softwareopengl` is usually the difference between
usable and not.

### 2. Container-domain userns is disabled by default

`harden_container_userns` blocks userns creation for `container_t`, so podman
cannot create the container at all. `ujust set-container-userns on` removes the
module. `ujust matlab-box` refuses to run until it does.

### 3. The base image is already trusted by the container policy

`/etc/containers/policy.json` is default-reject. `quay.io/toolbx-images` is one
of the namespaces secureblue already trusts, which is why the manifest uses
`quay.io/toolbx-images/ubuntu-toolbox:24.04` rather than
`docker.io/mathworks/matlab`. No policy overlay is needed, and none should be
added for this.

Ubuntu 24.04 is also a MathWorks-supported platform for R2026a — confirmed by
the presence of `matlab-deps/r2026a/ubuntu24.04/` in
`mathworks-ref-arch/container-images`, which is the same list the setup script
fetches to install MATLAB's shared-library dependencies.

### 4. The network license

`MLM_LICENSE_FILE=<port>@<host>` is passed as a podman `--env` from the
manifest. `MLM_LICENSE_FILE` rather than `LM_LICENSE_FILE` on purpose: the
latter is consulted by every FlexLM client on the machine.

The container runs in the **host network namespace** (`--network host`, and the
manifest deliberately does not set `unshare_netns`), so license checkout follows
whatever routing the host has. If the license server is only reachable over a
VPN, bringing that VPN up on the host is sufficient — there is nothing to
configure in the container. Do not add `unshare_netns=true` to the manifest.

Entitlement is checked at *run* time, not install time: `mpm` will happily
install products the license does not cover. They are wasted disk, not an
error, and they fail at `ver`/model-open time with a licensing error.

## Products

`matlab-products.txt` names the Simulink family — Simulink, Stateflow,
SimEvents, Requirements Toolbox, the `Simulink_*` products and the Simscape
family. It does *not* name their dependencies (MATLAB Coder, Fixed-Point
Designer, Control System Toolbox, …) because `mpm` resolves required products
automatically.

Hardware and vendor support packages (Arduino, Android, LEGO, VEX, the Embedded
Coder processor packages, the Siemens tyre-model interface) are listed commented
out. They pull vendor toolchains and are dead weight without the board.

Uncomment them in `~/.config/distrobox/matlab-products.txt`, not in `/etc`. The
setup script prefers the user copy and falls back to the image template only
when there isn't one.

Regenerate the authoritative name list for a new release with:

```sh
curl -sSfL https://raw.githubusercontent.com/mathworks-ref-arch/matlab-dockerfile/main/mpm-input-files/R2026a/mpm_input_r2026a.txt \
  | sed -n 's/^#\?product\.//p'
```

## Where the install lives, and why

`${HOME}/.local/share/matlab-distrobox` on the host, bind-mounted at
`/opt/matlab` in the container. The full family is roughly 50 GB; putting it on
a host volume means `distrobox rm`, `--replace`, or a botched container does not
cost another multi-hour download.

That split is why `fromelicks-matlab-box-setup` keeps **two** stamps. The MATLAB
stamp lives on the volume and survives a container replace; the apt dependency
stamp lives at `/var/lib/` inside the container and does not. Keyed off a single
stamp, a replaced container would skip the dependency install and end up with a
MATLAB that cannot start.

Because the container runs rootless with `--userns keep-id` and the setup
script runs as container-root, everything under that directory ends up owned by
one of your subuids. It reads and executes fine from both sides, but deleting it
from the host needs `podman unshare rm -rf`, not plain `rm -rf`.

## The exported application

`mpm` is a silent product installer and creates no desktop integration at all,
so the setup script writes `/usr/share/applications/matlab.desktop` itself —
otherwise `exported_apps=matlab` in the manifest has nothing to export.
`exported_bins` additionally puts a `matlab` launcher in `~/.local/bin`.

Ordering works out because `distrobox assemble` exports only after the first
`distrobox enter` returns, and that enter blocks on the init hook — so the first
`ujust matlab-box` takes hours.

That wait is why the setup script is careful about *where* it writes. The
`distrobox enter` log watcher gives three prefixes meaning: `distrobox:` is
progress and gets printed, `Error:` is fatal and aborts the enter, and anything
else is discarded silently. So the script's own step announcements carry the
`distrobox:` prefix and appear on the terminal, genuine failures use `Error:`
deliberately, and the bulk apt/mpm output goes to
`~/.local/share/matlab-distrobox/setup.log` and nowhere else. That last part is
not cosmetic: routed through the container log, a single `Error:` line from mpm
would kill `distrobox enter` — and with it `ujust matlab-box` — while the
install carried on unattended in the background. One previous log is kept as
`setup.log.prev`.

`StartupWMClass` is set, and the value is a guess. It has to be set to
*something*, because `distrobox-export` appends `StartupWMClass=matlab` to the
exported copy whenever the key is absent, and that is never correct. MATLAB's
real X11 class embeds the license type — `MATLAB R2026a - academic use` on an
academic license — so if the taskbar shows a second unmatched icon, read the
truth off a running window with `xprop WM_CLASS` and correct the value in the
setup script.

The exported entry is named `matlab-matlab.desktop`, not `matlab.desktop`:
`distrobox-export` prefixes the container name. Its `Name` also gains a
` (on matlab)` suffix, which `entry=false` in the manifest does not suppress —
that key only removes distrobox's own terminal entry for the container.

Removing the box needs no manual cleanup: `distrobox rm` runs its own
`cleanup_exports()`, which deletes the exported binary and every
`~/.local/share/applications/matlab*` entry.

## When an install fails halfway

`mpm` cannot resume, and re-running it over a half-written destination produces
a subtly broken install rather than an error. So the setup script drops a
`.installing-R2026a` marker on the volume before starting and removes it on
success. If a later run finds that marker — a dropped connection, a full disk,
an aborted `distrobox enter` — it refuses to touch the destination and says so,
rather than silently making things worse.

`ujust reset-matlab-install` is the way out. It prompts, then removes the whole
install directory with `podman unshare rm -rf` (a plain `rm -rf` cannot: see
the subuid note above). `ujust check-matlab-box` reports the `PARTIAL` state.
Recovering means downloading everything again — there is no partial resume to
be had.

## Known rough edges

- **NVIDIA.** `nvidia=true` mounts the host driver libraries for `gpuArray` and
  GPU Coder. Plain Simulink does not need it, and distrobox prepends the host
  driver directories to `ld.so.conf`, which occasionally shadows container
  libraries and breaks OpenGL. If MATLAB's graphics misbehave, set it to false
  first. `matlab -softwareopengl` is the other escape hatch.
- **ptrace.** secureblue's `set-selinux-booleans.sh` sets `deny_ptrace=on` and
  `container_allow_ptrace=off`. Ordinary MATLAB and Simulink work is unaffected,
  but attaching `gdb` to a mex file from inside the box needs both flipped.
  `ujust toggle-debug-mode` turns `deny_ptrace` off; `container_allow_ptrace`
  has no ujust recipe and has to be set by hand with `setsebool`.
- **`hardened_malloc` does leak in.** It is preloaded not through
  `/etc/ld.so.preload` (which is empty here) but through
  `/usr/lib/environment.d/40-hardened_malloc.conf` and
  `/etc/profile.d/hardened_malloc.sh`, both of which set
  `LD_PRELOAD='libhardened_malloc.so libno_rlimit_as.so'`. `distrobox enter`
  forwards nearly the whole host environment into the container — its blocklist
  covers `HOME`/`PATH`/`SHELL`/`XDG_*` but not `LD_PRELOAD` — and those
  libraries do not exist on Ubuntu. The `matlab`, `mex` and `mbuild` entries in
  `/usr/local/bin` are therefore wrapper scripts that `unset LD_PRELOAD` before
  exec, not symlinks.

## Two roads not taken

### The official MathWorks images

They exist: `mathworks/matlab:R2026a` and `mathworks/matlab-deps:R2026a-ubuntu24.04`
are both on Docker Hub. Neither is used here, for different reasons.

`mathworks/matlab` ships **MATLAB only** — no toolboxes. Every product in
`matlab-products.txt` would still have to come down through `mpm`, so it saves
none of the download that actually costs time. It is also built around its own
entrypoint and a non-root `matlab` user, both of which distrobox overrides
anyway.

`mathworks/matlab-deps` is the genuinely interesting one: it is precisely the
dependency layer that `fromelicks-matlab-box-setup` reproduces by apt-installing
the fetched `base-dependencies.txt`. Using it as the base would delete that step
outright.

The blocker for both is constraint 1. `docker.io` is not in
`/etc/containers/policy.json`, and MathWorks does not sigstore-sign these
images, so trusting them means an `insecureAcceptAnything` entry scoped to
`docker.io/mathworks` — i.e. resolving open decision 2 in AGENTS.md in the
loosest available direction, in exchange for skipping one `apt-get install`.
`quay.io/toolbx-images` is already trusted and costs nothing. If that trade is
ever worth making, the change is two lines: the `image=` key and dropping the
dependency block from the setup script.

### Installing MATLAB natively on the host

**Fedora is not a MathWorks-supported platform.** The R2026a Linux requirements
list Ubuntu 22.04/24.04, Debian 12/13, RHEL 8/9 (8.6/9.2 minimum) and SLED/SLES
15 SP4+. Fedora appears nowhere on it, so anything that breaks is unsupported by
definition.

The mechanics would work — `/usr/local` is a symlink to `/var/usrlocal` and is
writable, so a 50 GB tree could go in `/usr/local/MATLAB/R2026a` without
rpm-ostree layering. That is the whole argument in its favour, and it is
outweighed three times over:

- **`hardened_malloc` applies to everything on the host.** In the container it
  is one `unset LD_PRELOAD` in a wrapper. Natively, MATLAB's JVM and allocator
  would run under it for real, and opting out means the same per-app
  `LD_PRELOAD` surgery `ujust install-steam` does — see constraint 8.
- **Any missing shared library becomes rpm-ostree layering**, against design
  principle 3's "keep local layering at zero".
- **It is undeclarative drift**: 50 GB in `/var/usrlocal` that the image does
  not describe and `ostree admin config-diff` will never show.

The container costs nothing by comparison. secureblue's kernel hardening — the
fork/exec penalty in [`desktop-responsiveness.md`](desktop-responsiveness.md) —
applies either way, because the container shares the host kernel.
