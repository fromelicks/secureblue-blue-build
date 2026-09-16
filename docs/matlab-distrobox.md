# MATLAB R2026a + Simulink

MATLAB is installed once from the release ISO onto a host directory, and run
from a RHEL 9 distrobox. The display is a private Xwayland started per
invocation — secureblue's global `set-xwayland` stays **off**.

## What is in the image

| Path | Purpose |
|---|---|
| `/etc/distrobox/matlab.ini` | assemble manifest **template** |
| `/usr/libexec/fromelicks-matlab-box-setup` | init hook: MathWorks dependencies + entry points |
| `/usr/libexec/fromelicks-xwayland-isolated` | runs any command against a private X server |
| `/usr/libexec/fromelicks-matlab-launch` | ties the two together |
| `ujust matlab-install / matlab-box / matlab / check-matlab / matlab-agentic-toolkit / remove-matlab-box / matlab-uninstall` | drives all of it |

`matlab.ini` is a template. `ujust matlab-box` copies it to
`~/.config/distrobox/` and works from the copy, because the license server
address is per-machine. Editing it in `/etc` would permanently dirty
`ostree admin config-diff`.

## The display: a private Xwayland, not the global toggle

MathWorks ships no Wayland backend — the desktop, every Simulink model window
and every figure is an X11 client. The obvious answer is
`ujust set-xwayland on`, and it is the wrong one.

What that toggle actually does is narrower than it sounds. It drops an
override at `/etc/systemd/user/org.gnome.Shell@user.service.d/override.conf`
whose entire content is:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/gnome-shell --mode=%i --no-x11
```

That disables **Mutter's built-in Xwayland**. It does not remove
`/usr/bin/Xwayland`, which is still installed and still startable by anything
that wants to run its own.

`xwayland-satellite` is exactly that: it connects to the compositor as an
ordinary Wayland client, starts a rootless Xwayland behind it, and maps each X
window as a normal Wayland surface. It is usually described as a Niri
companion, but nothing about it is Niri-specific. **It works unmodified under
Mutter with `--no-x11` still in force.** Measured on this machine:

```
$ fromelicks-xwayland-isolated glxinfo -B
direct rendering: Yes
OpenGL renderer string: Mesa Intel(R) Graphics (RPL-S)
Max core profile version: 4.6
$ fromelicks-xwayland-isolated glxgears
375 frames in 5.0 seconds = 74.988 FPS      # vsync-locked to the 75 Hz panel
```

So this is a strictly smaller hole than the global toggle: the X server lives
and dies with one command instead of being shared by every X client in the
session for as long as the session lasts. `set-xwayland` stays off, and
`check-matlab` deliberately does not report it — doing so would suggest a
security reduction that is not needed.

`fromelicks-xwayland-isolated` picks a free display in `:32`–`:63`, waits for
xwayland-satellite's own readiness line rather than for the socket (the socket
appears first, before it will serve clients), and tears the server down on
exit including on signal.

The X socket lives in `/tmp/.X11-unix`, which distrobox already bind-mounts
into the container as `/tmp:rslave` — so the host runs the X server, the
container runs MATLAB, and no display plumbing is needed in the manifest.

### Why not the alternatives

- **xpra** — an X server inside the box with a native Wayland client on the
  host. Works, but MATLAB's post-R2023b desktop is CEF/Chromium and composites
  more than xpra likes, and figure windows want real OpenGL.
  `xwayland-satellite` gives direct rendering with none of that.
- **gamescope** — embeds its own Xwayland, so it genuinely works, but it is a
  single-fullscreen-window nested compositor and MATLAB is a
  multi-top-level-window IDE.
- **matlab-proxy** — serves the desktop over HTTP to a browser, avoiding X
  entirely. Not wired up here.

## hardened_malloc is fatal to MATLAB's UI

This is the single most important gotcha, and it presents as a hang rather
than an error.

secureblue preloads hardened_malloc into every process — not via
`/etc/ld.so.preload` (empty here) but via
`/usr/lib/environment.d/40-hardened_malloc.conf` and
`/etc/profile.d/hardened_malloc.sh`, both setting
`LD_PRELOAD='libhardened_malloc.so libno_rlimit_as.so'`.

MATLAB runs its front end in a **separate CEF process**, `MATLABWindow`. Under
hardened_malloc that process dies the instant it is spawned, leaving a parent
sitting at ~40% CPU forever with no window and no error message:

```
$ pgrep -P <installer-pid> -a
34002 [MATLABWindow] <defunct>
```

With `LD_PRELOAD` unset, the same binary comes up immediately. This applies to
MathWorks' **installer** as much as to MATLAB itself — the first attempt at the
GUI installer on this machine produced exactly the zombie above.

Two places drop it:

- `ujust matlab-install` runs the installer under `env -u LD_PRELOAD`.
- The container's `/usr/local/bin/{matlab,mex,mbuild}` are wrapper scripts that
  `unset LD_PRELOAD` before exec, **not** symlinks. `distrobox enter` forwards
  nearly the whole host environment into the container — its blocklist covers
  `HOME`/`PATH`/`SHELL`/`XDG_*` but not `LD_PRELOAD` — and those libraries do
  not exist in the container anyway.

## Installing: the ISO, not mpm

The release ISO (`R2026a_Update_4_Linux.iso`, 14 GB) contains the complete
release: 127 products listed in `installer_input.txt`, 125 of which are
installable on `glnxa64` (`Spreadsheet_Link` and `STM32_Microcontroller_Blockset`
are Windows-only and rejected by name).

`ujust matlab-install` loop-mounts it with `udisksctl` — unprivileged, via
polkit, landing under `/run/media/$USER` — and runs MathWorks' own GUI
installer against it.

Leave every product selected. The installer offers exactly what the license
covers, which is what "the full suite" means in practice; on this machine that
produced **114 products**.

### mpm cannot install from this ISO

`mpm install --source=<mounted ISO>` looks like the obvious automated path. It
reads the ISO's catalogue correctly — it validates product names against it and
rejects the two Windows-only ones — then fails partway through extraction:

```
Error: Download failed. Check the network connection and retry.
```

That message is a lie. The real error is in `/tmp/mathworks_$USER.log`:

```
Fatal Engine Exception: Signature is invalid. Error code: 101
Error Message: extract task invalid signature error
```

Ruled out, so nobody has to rule them out again:

- **not the network** — it fails identically with the host online and the
  MathWorks CDN reachable;
- **not hardened_malloc** — identical under `env -u LD_PRELOAD`;
- **not the destination** — identical on tmpfs and on the real disk;
- **not the loop mount** — every file under `archives/` is byte-identical
  between the kernel's iso9660 view and the raw image read with `7z`;
- **not a partial product set** — it dies at the same point installing only
  `MATLAB Simulink Stateflow`, around 36%, in `archives/foundation/platform/`;
- **not the staging layout** — it fails the same way from a tree produced by
  MathWorks' own `bin/glnxa64/extract_product_files_from_iso`, which is the
  documented ISO→`--source` bridge.

The standalone `mpm` simply will not accept these archives' signatures. The
ISO's own installer reads its own media and works. Note also that `--release`
and `--source` are **mutually exclusive** — passing both is an immediate
`Invalid option combination`.

## The base image: UBI9, and why not Ubuntu

```
image=registry.access.redhat.com/ubi9/toolbox:latest
```

The constraint is that the base must be in a namespace secureblue's
default-reject `/etc/containers/policy.json` already trusts, *and* be a
platform MathWorks supports. MathWorks publishes dependency lists for
`debian12`, `debian13`, `ubi8`, `ubi9`, `ubuntu22.04` and `ubuntu24.04` — no
Ubuntu 26.04, no Fedora.

- `quay.io/toolbx-images/ubuntu-toolbox:24.04` — what this repo used to
  specify. The whole namespace is now **auth-only**: pulls fail with
  `unauthorized: access to the requested resource is not authorized`.
- `ghcr.io/ublue-os/ubuntu-toolbox` — trusted, and pulls fine, but `latest` is
  now **Ubuntu 26.04**, which MathWorks does not support and which the 24.04
  dependency list does not match. It is the only tag published.
- `docker.io/library/ubuntu:24.04` — supported, but `docker.io` is not trusted,
  so this would mean an `insecureAcceptAnything` overlay, i.e. resolving
  AGENTS.md open decision 2 in the loosest available direction.
- `registry.access.redhat.com/ubi9/toolbox` — RHEL 9.8, MathWorks-supported,
  already trusted (`signedBy`), purpose-built for distrobox, and its 54
  dependency packages plus `gcc`/`gcc-c++`/`gcc-gfortran`/`make` all come from
  the default UBI repos with no EPEL. **No policy change needed.**

`dnf` is invoked with `--disableplugin=subscription-manager`: outside a
subscribed RHEL host the plugin errors out instead of falling back to the UBI
repos, which carry everything on the list.

## The network license

`MLM_LICENSE_FILE=<port>@<host>` is passed as a podman `--env` from the
manifest — `MLM_LICENSE_FILE` rather than `LM_LICENSE_FILE` on purpose, since
the latter is consulted by every FlexLM client on the machine.

The container runs in the **host network namespace**, so checkout follows
whatever routing the host has. If the license server is only reachable over a
VPN, bringing that VPN up on the host is sufficient. **Never set
`unshare_netns`.**

The address is per-machine and lives only in `~/.config/distrobox/matlab.ini`.
The image template ships a placeholder, and `ujust matlab-box` refuses to
assemble until it has been replaced.

## Where the install lives

`~/.local/share/matlab-distrobox` on the host, mounted at `/opt/matlab` in the
container. Roughly 25 GB for 114 products. Keeping it on a host volume means
`distrobox rm`, `--replace` or a botched assemble costs the 30 seconds it takes
to reinstall the container's dependencies, not a reinstall of MATLAB.

Because the ISO installer runs as the host user, the tree is owned by that user
and a plain `rm -rf` removes it. The one exception is `setup.log`, written by
the container's init hook as container-root — which maps to a subuid the host
user does not own — so `ujust matlab-uninstall` falls back to
`podman unshare rm -rf`.

## The desktop entry

Written on the **host** by `ujust matlab-box`, pointing at
`fromelicks-matlab-launch`. Deliberately not `distrobox-export`: an exported
entry runs `distrobox enter` directly, which under GNOME's default `--no-x11`
would start MATLAB with no X server at all.

`StartupWMClass` is set, and the value is a guess — MATLAB's real X11 class is
its window title, which embeds the license type (`MATLAB R2026a - academic use`
on an academic licence). If the taskbar shows a second unmatched icon, read the
truth off a running window with `xprop WM_CLASS` and correct it in the recipe.

## The Simulink Agentic Toolkit

`ujust matlab-agentic-toolkit` fetches the release artifacts to the host, then
runs MathWorks' `setupAgenticToolkit` inside the container's MATLAB with
`Offline=true` so nothing is downloaded from inside the box, where a failure
would surface as a MATLAB exception rather than a curl error.

It installs both the MATLAB and Simulink toolkits, registers the MCP server in
`~/.claude.json`, and installs the nine Simulink skill packages globally
through Claude Code's plugin system.

Every product the skill groups require — Simulink Test, Simulink Check,
Simulink Design Verifier, Simulink Fault Analyzer, System Composer,
Requirements Toolbox, Embedded Coder, Fixed-Point Designer, Control System
Toolbox, DSP System Toolbox, Simulink Control Design — is present in this
install.

The setup shells out to the `claude` CLI, which lives on the host, so the init
hook drops a `/usr/local/bin/claude` shim in the container that forwards to
`distrobox-host-exec`. Without it, setup silently falls back to symlinks in
`~/.claude/skills/` and the plugin system never learns about the skills.

### Reaching MATLAB from Claude Code

Claude Code runs on the host; MATLAB runs in the container. The MCP server has
to bridge that, and there are two ways:

1. **Host-side server** — what `setupAgenticToolkit` configures by default.
   `~/.claude.json` gets a `command` pointing at
   `~/.matlab/agentic-toolkits/bin/matlab-mcp-server`. Because distrobox shares
   `$HOME`, `/tmp` and the host network namespace, a session shared from the
   container with `shareMATLABSession()` may well be discoverable from the
   host. Try this first — it needs no plumbing.
2. **In-container server** — if the host-side server cannot find the session,
   rewrite that `command` to run the server inside the box:

   ```json
   "command": "podman",
   "args": ["exec", "-i", "matlab", "/var/home/<user>/.matlab/agentic-toolkits/bin/matlab-mcp-server", "--matlab-session-mode=existing"]
   ```

   `podman exec -i` rather than `distrobox enter`, because the latter prints
   progress lines that would corrupt the MCP stdio stream.

Either way MATLAB has to be running and sharing its session:

```
ujust matlab            # one terminal
>> satk_initialize      # in the MATLAB command window; calls shareMATLABSession()
```

Then restart Claude Code so it picks up the new server and skills.

## Known rough edges

- **NVIDIA.** `nvidia=true` mounts the host driver libraries for `gpuArray`
  and GPU Coder. Plain Simulink does not need it, and distrobox prepends the
  host driver directories to `ld.so.conf`, which can shadow container
  libraries and break OpenGL. If graphics misbehave, set it to false first;
  `FROMELICKS_MATLAB_SOFTWARE_OPENGL=1 ujust matlab` is the other escape hatch.
- **ptrace.** secureblue's `set-selinux-booleans.sh` sets `deny_ptrace=on` and
  `container_allow_ptrace=off`. Ordinary work is unaffected, but attaching
  `gdb` to a mex file needs both flipped. `ujust toggle-debug-mode` handles the
  first; the second has no ujust recipe and needs `setsebool` by hand.
- **Multi-line `-batch`.** `distrobox enter -- matlab -batch "<multi-line>"`
  loses the argument (`No MATLAB command specified`). Put the code in a `.m`
  file and use `-batch "run('/path/to/file.m')"`.

## Installing natively on the host instead

Rejected. **Fedora is not a MathWorks-supported platform** — the R2026a Linux
requirements list Ubuntu 22.04/24.04, Debian 12/13, RHEL 8/9 and SLED/SLES 15
SP4+, and Fedora appears nowhere.

The mechanics would work: `/usr/local` is a symlink to `/var/usrlocal` and is
writable, so the tree could go in `/usr/local/MATLAB/R2026a` without
rpm-ostree layering. That is the whole argument in its favour, and it is
outweighed:

- hardened_malloc would apply for real, not behind one `unset LD_PRELOAD` in a
  wrapper — the same per-app `LD_PRELOAD` surgery `ujust install-steam` does;
- any missing shared library becomes rpm-ostree layering, against design
  principle 3's "keep local layering at zero";
- it is undeclarative drift that `ostree admin config-diff` will never show.

The container costs ~30 seconds to rebuild and nothing at runtime — it shares
the host kernel, so secureblue's fork/exec penalty applies either way.
