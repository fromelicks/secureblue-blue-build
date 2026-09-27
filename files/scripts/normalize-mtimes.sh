#!/usr/bin/env bash
set -euo pipefail

# Make chunkah's layers reproducible across daily rebuilds. See docs/update-size.md.
#
# chunkah clamps each RPM component's mtimes to that package's build time, and
# everything else to the image's creation time. A directory whose mtime is
# already older than the clamp passes through untouched, and those mtimes
# drift from build to build in the secureblue base -- so ~40 layers (~1.6 GB)
# changed digest daily with byte-identical contents. ostree discards every
# mtime on import anyway (the booted /usr is all epoch 0), so zeroing them here
# changes nothing on a deployed system; it only stops the churn.
#
# Directories: all of them. Cheap -- an overlayfs copy-up of a directory is
# metadata only. Non-directories: only the ones no RPM owns. RPM-owned files
# carry payload mtimes at or below their build time, which are already stable,
# and skipping them avoids copying ~10 GB up into this layer.
#
# Must be the LAST module. BlueBuild's post_build.sh still runs afterwards,
# but it only touches RPM-owned directories (/, /var, /usr/lib/tmpfiles.d, the
# rpmdb dirs), which chunkah clamps to their package's build time.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Mount points are never touched: /etc/resolv.conf, /etc/hosts and the module
# mounts are bind mounts from the build host.
findmnt -rn -o TARGET | sed 's/\\x20/ /g' | tr '\n' '\0' | LC_ALL=C sort -zu >"$tmp/mounts"
{ rpm -qa --qf '[%{FILENAMES}\n]' | tr '\n' '\0'; cat "$tmp/mounts"; } | LC_ALL=C sort -zu >"$tmp/keep"

walk() {
    find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /tmp -o -path /var \) -prune \
        -o "$@" -print0 | LC_ALL=C sort -z
}

# Files first: a copy-up must not bump a directory after it has been zeroed.
walk ! -type d | LC_ALL=C comm -z -23 - "$tmp/keep" >"$tmp/files"
walk -type d | LC_ALL=C comm -z -23 - "$tmp/mounts" >"$tmp/dirs"
xargs -0 -r touch -h -d @0 -- <"$tmp/files"
xargs -0 -r touch -h -d @0 -- <"$tmp/dirs"

files=$(tr -cd '\0' <"$tmp/files" | wc -c)
dirs=$(tr -cd '\0' <"$tmp/dirs" | wc -c)
left=$(xargs -0 -r stat -c '%Y' -- <"$tmp/dirs" | grep -cv '^0$' || true)
echo "normalize-mtimes: zeroed ${dirs} directories and ${files} unowned files"
if [ "$left" -ne 0 ]; then
    echo "normalize-mtimes: ${left} directories still have a non-zero mtime" >&2
    exit 1
fi
