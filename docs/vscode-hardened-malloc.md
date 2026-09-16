# VS Code and hardened_malloc

VS Code is installed on the host from Microsoft's `code` RPM. It does not run
under hardened_malloc, which secureblue preloads for every user process. This
image turns hardened_malloc off for VS Code only.

## The failure

secureblue sets
`LD_PRELOAD='libhardened_malloc.so libno_rlimit_as.so'` in three places:
`/usr/lib/environment.d/40-hardened_malloc.conf`,
`/usr/lib/systemd/system.conf.d/40-hardened_malloc.conf` and
`/etc/profile.d/hardened_malloc.sh`. Electron aborts under it, even in node
mode:

```
$ ELECTRON_RUN_AS_NODE=1 /usr/share/code/code -p 1
fatal allocator error: invalid uninitialized allocator usage
Aborted (core dumped)
```

`/etc/ld.so.preload` also lists hardened_malloc, but it is mode `0600 root`,
so glibc skips it for unprivileged processes. Removing `LD_PRELOAD` is enough.

## The fix, in two parts

### 1. Wrapped launchers (`files/scripts/vscode-standard-malloc.sh`)

Runs after the dnf module, because every file it edits is owned by the `code`
RPM and a `files/rootfs` copy would be overwritten by the install.

- The `Exec=` lines of `code.desktop` (including the "New Empty Window"
  action) and `code-url-handler.desktop` are prefixed with
  `/usr/bin/with-standard-malloc`, the helper secureblue ships for exactly
  this (`LD_PRELOAD='' exec -- "$@"`; also exposed as
  `ujust with-standard-malloc`).
- The `/usr/bin/code` symlink becomes a wrapper that runs
  `/usr/share/code/bin/code` through the same helper.

The script fails the build if a desktop file has no `Exec=` line, if any
`Exec=` line is left unwrapped, or if `/usr/bin/code` is no longer a symlink to
`/usr/share/code/bin/code`, so an upstream packaging change is caught at build
time. The check deliberately avoids a `grep | grep` pipeline: with `pipefail`,
a first `grep` that finds nothing, or is killed by SIGPIPE, made the check
pass.

### 2. The shell-environment probe (`/etc/profile.d/zz-fromelicks-vscode-resolve-env.sh`)

When VS Code is started from the desktop rather than from a terminal, it
learns the user's `PATH` and other variables by running
`$SHELL -i -l -c` with its own Electron binary in node mode inside that shell.
The login shell sources `/etc/profile.d/hardened_malloc.sh`, which puts
`LD_PRELOAD` back, and that Electron process aborts. VS Code then reports
"Unable to resolve your shell environment", and tools on the login `PATH`
(mise shims, for example) are missing from terminals and extensions.

VS Code sets `VSCODE_RESOLVING_ENVIRONMENT=1` only for this probe. The drop-in
removes `LD_PRELOAD` when that variable is set. Its `zz-` prefix keeps it
after `hardened_malloc.sh` in the `/etc/profile.d/*.sh` glob. Ordinary shells
are unaffected.

Shells that do not read `/etc/profile.d` (fish, nushell) never re-add
`LD_PRELOAD`, so the probe works for them without the drop-in.

## What still runs under hardened_malloc

VS Code's helpers inherit its environment without `LD_PRELOAD`, and so do
integrated terminals.

- **bash** terminals get hardened_malloc back: Fedora's `/etc/bashrc` sources
  `/etc/profile.d/*.sh` in interactive non-login shells too.
- **fish and nushell** terminals do not, and neither does anything started
  from them (builds, tests, tools). To restore it there, set it in the user
  layer:

  ```json
  "terminal.integrated.env.linux": {
      "LD_PRELOAD": "libhardened_malloc.so libno_rlimit_as.so"
  }
  ```

## Wayland

No `--ozone-platform-hint` flag is needed. VS Code 1.137 ships Electron 42,
and Electron has selected the Wayland backend by itself since version 38, so
it works with secureblue's Xwayland left off.

## Verifying on the machine

```sh
grep ^Exec= /usr/share/applications/code*.desktop   # all via with-standard-malloc
cat /usr/bin/code
# Start VS Code from the app menu, then check the main process:
tr '\0' '\n' < /proc/"$(pgrep -o -x code)"/environ | grep LD_PRELOAD   # no output
```

Starting from the menu must not show "Unable to resolve your shell
environment", and `echo $PATH` in an integrated terminal must match a normal
login shell.
