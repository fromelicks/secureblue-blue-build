# Update download size

Why a daily update of this image pulled ~3 GB even when a handful of packages
changed, what `normalize-mtimes.sh` does about it, and what churn is left.

Measured on the 2026-09-25 update (44.20260923.0 → 44.20260925.0).

## Seeing an update before pulling it

`ujust update-diff` prints the package-level diff of the pending update and an
estimate of its download size. It fetches only the manifest, the config and the
~45 MB layer that chunkah dedicates to the RPM database, then diffs that
database against the booted `rpm-ostree-base-db`. It is read-only and needs no
root. It is the closest thing to `rpm-ostree db diff` for an update that has not
been pulled.

## How the image is layered

The build runs [chunkah](https://github.com/coreos/chunkah) (`chunkah: true` in
`.github/workflows/build.yml`). chunkah splits the final rootfs into 128 layers
by component: one per source RPM for the big ones, bins of 40–60 small source
RPMs, `bigfiles/*` for large unowned files (initramfs, rpmdb, claude-desktop,
cosign, BlueBuild's `nu`), and a catch-all `chunkah/unclaimed`. Every layer
carries an `org.chunkah.component` annotation that names its contents. bootc
pulls only the layers whose digests the booted image does not already have.

The goal is that a layer's digest changes only when its contents do.

## What actually changed

26 packages changed (webkitgtk, VS Code, samba, bootc, the nvidia kmod rebuild,
kernel-tools, mise, thermald, gdb). 49 of the 128 layers changed digest,
3,073 MB in total:

| Changed layers | Count | Size |
|---|---|---|
| contain a changed source RPM | 9 | 1,094 MB |
| rpmdb + initramfs (expected) | 2 | 380 MB |
| **contain no changed package** | **38** | **1,599 MB** |

Diffing the tar members of eleven of the 38 (old blob vs new blob) found
byte-identical contents in all but two, differing only in mtimes:

| Layer | Differences |
|---|---|
| `rpm/podman` | 1 directory mtime |
| `rpm/systemd` | 8 directory mtimes |
| `rpm/vim` | 18 directory mtimes |
| `rpm/selinux-policy`, `rpm/gtk4` | 2 directory mtimes each |
| `bigfiles/cosign`, `bigfiles/.../nu/nu` | directory + file mtimes |
| `bigfiles/app.asar`, `bigfiles/smol-bin.x64.img` | 2 directory mtimes each |
| `rpm/dnf5` | 1 directory mtime + libdnf5 state files (real content) |
| font/license bin | 66 directory mtimes, java `cacerts`, hardlink-vs-file flips |

## Why the mtimes drift

chunkah clamps mtimes rather than setting them. From `src/components/rpm.rs`
and `src/tar.rs` (v0.6.0):

- files and directories that an RPM owns get `min(mtime, max buildtime of the source RPM)`;
- everything else gets `min(mtime, SOURCE_DATE_EPOCH or the image's Created time)`.

A clamp only helps when the raw mtime is *newer* than the clamp. A directory
shared by several packages, such as `/usr/libexec/podman` (podman, conmon,
netavark, catatonit), takes the mtime of whichever write happened last in the
secureblue base build. That mtime can be older than the owning package's build
time, and it differs from day to day:

```
/usr/libexec/podman   old build: 1789591279 (= podman BUILDTIME, clamped)
                      new build: 1789480580 (older than BUILDTIME, passed through)
```

Unowned files that BlueBuild or the recipe creates (cosign, `nu`) get the build
time. That is older than the image's Created time, so it also passes through.

BlueBuild set `SOURCE_DATE_EPOCH=0` for chunkah in blue-build/cli#836 and
reverted it four days later (`c1b9cee`, no reason given). It would not have
been enough anyway: `SOURCE_DATE_EPOCH` replaces only the *default* clamp, and
RPM components ignore it.

## The fix

`files/scripts/normalize-mtimes.sh`, the last module in the recipe, sets the
mtime to epoch 0 on:

- **every directory**, which is cheap because an overlayfs copy-up of a directory
  is metadata only;
- **every file and symlink that no RPM owns** (~14k paths, ~1.8 GB). RPM-owned
  files keep their payload mtimes, which are already stable, and skipping them
  avoids copying ~10 GB up into the layer.

It skips mount points: `/etc/resolv.conf`, `/etc/hosts` and the module mounts
are bind mounts from the build host. The build fails if any directory is left
non-zero.

Zeroing mtimes has **no effect on a deployed system**, because ostree does not
store mtimes and every file under `/usr` is epoch 0 once deployed
(`ls -l --time-style=+%s /usr`).

BlueBuild's `post_build.sh` still runs afterwards. It changes `/`, `/var`,
`/usr/lib/tmpfiles.d` and the rpmdb directories, all RPM-owned, so chunkah clamps
them to the owning package's build time, which is stable.

## Churn that remains

- **`bigfiles/rpmdb.sqlite`** (44 MB): rebuilt on every build, and it stores
  install times.
- **`bigfiles/initramfs.img`** (336 MB): secureblue already regenerates it with
  `dracut --reproducible` and strips the version from `os-release`, so it
  changes only when its inputs do. On 2026-09-25 the rebuilt nvidia kmod did
  that (secureblue force-loads nvidia early).
- **`rpm/dnf5`** (8 MB): `/usr/lib/sysimage/libdnf5/transaction_history.sqlite`
  and `nevras.toml` change on every dnf run.
- **java `cacerts`**: regenerated with fresh timestamps; it drags its ~20 MB bin
  along.
- **Hardlink-vs-file flips** in license files: the base image's inode sharing
  varies.
- **Bin regrouping**: chunkah's per-package stability score depends on the
  current date, so packages occasionally move between bins. On 2026-09-25 this
  affected 2 layers (147 MB).
- **Bins**: one changed package re-downloads its whole 20–110 MB bin. That is
  inherent to a 128-layer limit.

## Verifying

Compare two builds with the same base image. Every layer that differs should
contain a changed package, or be one of the residual cases above:

```bash
IMG=ghcr.io/fromelicks/secureblue-nvidia-open-hardened
OLD=sha256:...   # per-arch manifest digests, e.g. from `rpm-ostree status --json`
NEW=sha256:...
skopeo inspect --raw "docker://$IMG@$NEW" | jq -r \
    --argjson old "$(skopeo inspect --raw "docker://$IMG@$OLD")" '
    ([$old.layers[].digest]) as $have
    | .layers[] | select(.digest as $d | $have | index($d) | not)
    | "\(.size / 1e6 | floor) MB  \(.annotations["org.chunkah.component"][0:100])"'
```

`ujust update-diff` prints the download estimate for the pending update.
