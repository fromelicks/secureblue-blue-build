# MicroVMs with libkrun (`podman --runtime krun`)

The image ships `crun-krun`. With it, any OCI image runs in its own KVM
microVM, with its own kernel, through the podman that is already here:

```
podman run --rm --runtime krun registry.access.redhat.com/ubi9/ubi:latest uname -r
```

This prints the libkrunfw guest kernel (`6.12.91` with `libkrunfw-5.5.0`), not
the host's `7.2.5-200.secureblue`. `ujust krun-check` runs that comparison.

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
carry the same defaults in a `/.krun_vm.json`.

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
