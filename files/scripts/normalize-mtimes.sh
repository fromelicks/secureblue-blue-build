#!/usr/bin/env bash
set -euo pipefail

# Make chunkah's layers reproducible across daily rebuilds. See docs/update-size.md.
#
# chunkah clamps each RPM component's mtimes to that package's build time, and
# everything else to the image's creation time. A directory whose mtime is
# already older than the clamp passes through untouched, and those mtimes
# drift from build to build in the secureblue base -- so ~40 layers (~1.6 GB)
# changed digest daily with byte-identical contents. ostree discards every
# mtime on import (the booted /usr is all epoch 0), so the zeroing itself is
# invisible on a deployed system. Two side effects are not: the fontconfig
# caches are regenerated (and now validate at runtime), and the image's /run
# is emptied (never visible under the runtime tmpfs).
#
# Directories: all of them. Cheap -- an overlayfs copy-up of a directory is
# metadata only. Non-directories: the ones no RPM owns *with that file type*,
# judged the way chunkah judges ownership (the RPM path's parent directory
# canonicalized, so /lib64/libgcc_s.so.1 owns /usr/lib64/libgcc_s.so.1). RPM
# payload mtimes are already stable, and skipping them avoids copying ~10 GB up
# into this layer. The type check catches paths the build replaced, e.g.
# /usr/bin/code (a symlink in the RPM, a wrapper script here), which chunkah no
# longer counts as owned. Never select by mtime age: a "changed recently" rule
# flips a package's layer once it ages out.
#
# /run is emptied instead: every RUN step bumps its mtime (buildah's mount
# points), and a booted system mounts a tmpfs over it, so its contents are
# build leftovers nobody can see.
#
# Must be the LAST module (the build workflow asserts it). BlueBuild's
# post_build.sh runs once after it; the RPM-owned directories it touches (/,
# /var, /usr/lib/tmpfiles.d) are clamped to their package's build time, but
# /opt and rpm-ostree-base-db are not, so chunkah/unclaimed (~58 MB) still
# changes on every build.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Mount points are never touched: /etc/resolv.conf, /etc/hosts and the module
# mounts are bind mounts from the build host.
findmnt -rn -o TARGET | sed 's/\\x20/ /g' | tr '\n' '\0' | LC_ALL=C sort -zu >"$tmp/mounts"

# "<type> <path>" for every RPM-owned path, type as find's %y (f, l, d, ...),
# with the parent directory canonicalized like chunkah's
# canonicalize_package_paths (rpm.rs), so /lib64 and /sbin paths match the
# /usr ones that find reports.
rpm -qa --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' | python3 -c '
import os, sys
cache, out = {}, sys.stdout.buffer
for line in sys.stdin.buffer:
    perms, _, path = line.rstrip(b"\n").partition(b" ")
    kind = b"f" if perms[:1] == b"-" else perms[:1]
    parent, name = os.path.split(path)
    real = cache.get(parent)
    if real is None:
        real = cache[parent] = os.path.realpath(parent)
    out.write(kind + b" " + os.path.join(real, name) + b"\0")
' | LC_ALL=C sort -zu >"$tmp/owned"

walk() {
    find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /tmp -o -path /var \) -prune \
        -o "$@" | LC_ALL=C sort -z
}

zero_dirs() {
    walk -type d -print0 | LC_ALL=C comm -z -23 - "$tmp/mounts" >"$tmp/dirs"
    xargs -0 -r touch -h -d @0 -- <"$tmp/dirs"
}

# Skip any /run entry that is, or contains, a mount point (buildah's secrets).
while IFS= read -r -d '' entry; do
    if ! tr '\0' '\n' <"$tmp/mounts" | grep -qxF -e "$entry" && ! tr '\0' '\n' <"$tmp/mounts" | grep -qF -e "$entry/"; then
        rm -rf -- "$entry"
    fi
done < <(find /run -mindepth 1 -maxdepth 1 -print0)

# fontconfig caches record each font directory's mtime, so regenerate them once
# the directories are zeroed. This also fixes the deployed system: there every
# directory is mtime 0, so caches recording the build time never validated and
# fontconfig rescanned every font into each user's ~/.cache/fontconfig.
zero_dirs
if command -v fc-cache >/dev/null; then
    fc-cache --system-only --force
fi

walk ! -type d -printf '%y %p\0' | LC_ALL=C comm -z -23 - "$tmp/owned" |
    sed -z 's/^. //' | LC_ALL=C sort -z | LC_ALL=C comm -z -23 - "$tmp/mounts" >"$tmp/files"
xargs -0 -r touch -h -d @0 -- <"$tmp/files"
# Again, last: fc-cache wrote into /usr/lib/fontconfig/cache, and a file
# copy-up can bump its parent directory.
zero_dirs

echo "normalize-mtimes: zeroed $(tr -cd '\0' <"$tmp/dirs" | wc -c) directories" \
    "and $(tr -cd '\0' <"$tmp/files" | wc -c) files"
