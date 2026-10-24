# MicroVMs with libkrun (`podman --runtime krun`)

The image ships `crun-krun`. With it, any OCI image runs in its own KVM
microVM, with its own kernel, through the podman that is already here:

```
podman run --rm --runtime krun registry.access.redhat.com/ubi9/ubi:latest uname -r
```

This prints the libkrunfw guest kernel (`6.12.91` with `libkrunfw-5.5.0`), not
the host's `7.2.5-200.secureblue`. `ujust krun-check` runs that comparison.

## Daily use: `krun-box`

Raw `podman run --runtime krun` needs several non-obvious flags to be usable as a
workstation (see [Traps](#traps-and-why-krun-box-exists) below).
`/usr/bin/krun-box` (also `ujust krun-box`) wraps them:

```
krun-box -- krun-box-setup                 # once: install juliaup + opencode into the box
krun-box -v ~/Repos/myproj                 # shell in the VM, project at /work/myproj
krun-box -v ~/Repos/myproj -- opencode     # opencode in the project
krun-box -m 16 -c 12 -- julia              # bigger VM: 16 GiB, 12 vCPUs (default 8 / 8)
krun-box -n scratch -- bash -l             # a separate box with its own persistent home
```

- **Every call boots a fresh VM.** What persists is the podman volume
  `krun-NAME-home` (default `NAME=dev`), mounted as the guest's `/root`: juliaup,
  the Julia depot, opencode and its config and login, shell history. juliaup and
  opencode are installed *into the volume*, not the image, so `juliaup update`
  and `opencode upgrade` work and survive image rebuilds.
- **The image** `localhost/krun-box` is built from
  `/usr/share/fromelicks/krun-box/` (UBI 9 + git, unzip, less, ncurses) on first
  use, and rebuilt automatically when a future image update changes that
  directory (content hash in the `fromelicks.krun-box.hash` label). docker.io is
  `reject` in policy.json, which is why the base is UBI.
- **`-v HOSTDIR[:GUESTDIR]`** shares a project directory read-write (default
  guest path `/work/<basename>`, which also becomes the working directory).
  Guest root writes files the host sees as owned by uid 1000.
- **Several shells** means several `krun-box` calls: separate VMs sharing the
  same volume. There is no `podman exec` into a running one, and UBI ships no
  `tmux`.
- Remove a box and everything installed in it with
  `podman volume rm krun-NAME-home`.

Measured on the Legion: Julia `Pkg.add("DataFrames")` with precompilation takes
147.5 s in the VM vs 138.8 s under plain crun; a warm `using DataFrames` is
0.51 s vs 0.39 s.

## What gets installed

`crun-krun` is only the `/usr/bin/krun` symlink to `crun`. crun switches to krun
mode when invoked under that name, and Fedora's `crun` is already built with
`+LIBKRUN`. The package pulls in:

- `libkrun` — the VMM, as a library `dlopen`ed by crun. Its other dependencies
  (`virglrenderer`, `pipewire-libs`, `libzstd`) were already in the base image.
- `libkrunfw` — the guest kernel, bundled into a shared library.

No containers.conf entry is needed: podman's built-in default maps the
runtime name `krun` to `/usr/bin/krun`.

## Why this and not Firecracker or Kata

Decided 2026-09-18.

- **Firecracker** (`firecracker` 1.13.1 is in Fedora 44, without `jailer`) is a
  bare VMM: it needs a hand-built uncompressed `vmlinux`, an ext4 rootfs, and a
  TAP device per VM, which on this image means `ip_forward`, a dedicated
  firewalld zone with masquerade, and a privileged unit to create the tap.
  It wins for building a platform — snapshots, `jailer`, many short-lived VMs —
  which is not the goal here.
- **Kata Containers** (3.26.0 in Fedora 44) sits *above* a VMM and can use
  Firecracker as one. It integrates through `containerd-shim-kata-v2` —
  containerd, CRI-O, Docker, Kubernetes — and has no podman path, since podman
  needs an OCI runtime CLI and Kata dropped that in 2.0. Adopting it would mean
  adding a container daemon to a deliberately daemonless machine.
- **krun** needs no kernel or rootfs build, no network plumbing (below), and
  runs rootless through the existing podman.

Firecracker remains the right tool if snapshot/restore or the `jailer` is ever
needed. Cloud Hypervisor is not packaged for Fedora 44, so it would carry the
same pinned-binary burden as upstream Firecracker.

## Networking: TSI, not a tap

With no network interface configured, libkrun uses TSI (Transparent Socket
Impersonation): the guest's socket calls are forwarded over vsock and made by
the VMM process. The guest sees `lo` and a `dummy0` with `203.0.113.1/24`
(TEST-NET-3, a placeholder). Consequences:

- **No host changes.** No tap device, no `ip_forward`, no firewalld zone. The
  VMM process lives in the container's network namespace, so the guest's
  traffic leaves through podman's ordinary rootless networking (pasta), exactly
  like a plain crun container's.
- `-p 127.0.0.1:HOST:GUEST` works. The listener takes about a second to come up
  after `podman run -d` returns.
- `--annotation krun.use_passt=1` switches to passt-based virtio-net, and
  `krun.tap_name=` attaches to an existing tap (only if libkrun was built with
  virtio-net), if a real interface is ever needed. Neither has been tried here.

## Sizing and other annotations

Defaults: vCPUs equal to the CPU affinity of the process (16 here), and
1024 MiB RAM unless the container has a memory limit. Override per container:

```
podman run --rm --runtime krun \
    --annotation krun.cpus=2 --annotation krun.ram_mib=4096 IMAGE ...
```

Also available: `krun.nested_virt=1` (the host has `kvm_intel nested=Y`) and
`krun.gpu_flags=` for virtio-gpu. The full list is in `man 1 krun`. An image can
carry the same defaults in a `/.krun_vm.json`. With raw podman, give `--memory`
about 25% more than `krun.ram_mib` (see below).

## Traps, and why `krun-box` exists

All found on the Legion with crun 1.28, libkrun 1.19 and libkrunfw 5.5.0.

- **No `podman exec`.** krun fails it with `the handler does not support exec`.
  `distrobox enter` and `toolbox enter` *are* `podman exec`, so neither can work
  with krun: a distrobox created with `--additional-flags "--runtime krun"` runs
  its init inside the VM and then can never be entered. The container's main
  process is the session.
- **No TTY for the guest process.** Even with `-it`, `tty` in the guest prints
  `not a tty`, so REPLs and TUIs misbehave. crun's krun handler does not set up
  a console. `krun-box` runs the command under `script -qec` in the guest,
  which allocates a guest-side pty, and passes the host terminal's size with
  `stty`. **Resizing the window afterwards does not propagate.**
- **Random MCS levels break named volumes.** The VMM runs as
  `container_kvm_t` with a fresh random MCS level per `podman run`. A file
  created directly in a volume inherits the volume's shared `s0` label, but a
  file an installer stages in `/tmp` (the container's own rootfs) and `mv`s
  into the volume keeps that run's private categories, and every later run is
  denied it: the opencode installer does exactly this (`Permission denied`,
  exit 126). `krun-box` pins a fixed level per box name
  (`--security-opt label=level:s0:cA,cB`, derived from the name), which keeps
  such files usable and still keeps other containers out.
- **Memory is outside `app.slice`.** krun containers land in
  `user@1000.service/user.slice/libpod-*.scope`, so the `app.slice`
  `MemoryHigh` from `docs/memory-pressure-hangs.md` does not apply. This is
  mostly fine: when the guest fills its RAM, the *guest* kernel OOM-kills the
  process and the VM and desktop carry on. But the host-side `--memory` cap needs
  headroom over the guest RAM: with the two equal, the host cgroup hit
  `memory.max` 408 times in one test (reclaim stalls on the VMM); 25% headroom
  brought that to 0. `krun-box` sets `krun.ram_mib` and `--memory` = 1.25x.
- **`:Z` host mounts relabel recursively.** SELinux needs the shared directory
  relabelled for `container_kvm_t` to reach it, and `:Z` does that for the whole
  tree. `krun-box` therefore only accepts an **allowlist**: a directory at least
  two levels inside `$HOME`, under no dot-directory, whose current type is
  `user_home_t` or `container_file_t`. A denylist was tried first and let
  `$HOME` through (it is `/home/licks`, a symlink to `/var/home/licks`), which
  relabelled ~900k files; that was repaired with `podman unshare restorecon -F`
  on exactly the files carrying the bad level. Do not loosen this check.
- **Fully cached builds are rejected by policy.** A build whose result matches
  an existing local image is committed as a copy from `containers-storage`, and
  secureblue's policy.json rejects that transport (`Source image rejected ...
  rejected by policy`). `krun-box` builds with `--no-cache`.

## Interaction with secureblue hardening

All verified on the Legion, 2026-09-18:

- **`/dev/kvm`** is `crw-rw-rw- root:kvm` and `kvm_intel` loads, so
  AGENTS.md constraint 6 (KVM blacklisting) does not apply to this hardware.
- **Container userns** (constraint 4) must be on, as for any rootless podman:
  `ujust set-container-userns status` reports `enabled` on the Legion.
- **hardened_malloc** (constraint 8) is compatible. crun and libkrun run under
  `LD_PRELOAD='libhardened_malloc.so libno_rlimit_as.so'` without the abort
  VS Code hits, so no `with-standard-malloc` wrapper is needed.
- **Container signature policy** (constraint 1) is unchanged: krun uses the same
  images podman already pulls, so the trusted-registry list applies as before.
- **Bind mounts** (`-v host:guest:Z`) work read-write over virtiofs.
- **Start-up** costs about 0.45 s more than plain crun (0.78 s vs 0.33 s for
  `podman run --rm IMAGE true`). The hardening kargs make VM exits expensive
  (`mitigations=auto,nosmt`, `l1tf=full,force`,
  `kvm-intel.vmentry_l1d_flush=always`); that is the accepted cost.

The guest kernel runs with `panic=-1`, set by libkrun on its own cmdline. That
concerns only the microVM and is unrelated to the host `kernel.panic` override
in constraint 10.

## Verifying on the machine

After `bootc upgrade` and a reboot:

```
ujust krun-check
```

It checks for `/usr/bin/krun`, read-write `/dev/kvm` and the userns state, then
boots `registry.access.redhat.com/ubi9/ubi` under krun and fails if the guest
reports the host's kernel.
