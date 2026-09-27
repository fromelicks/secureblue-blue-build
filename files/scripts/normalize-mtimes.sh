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
# metadata only. Non-directories: the ones no RPM owns *with that file type*.
# RPM payload mtimes are already stable, and skipping them avoids copying
# ~10 GB up into this layer. The type check catches paths the build replaced,
# e.g. /usr/bin/code (a symlink in the RPM, a wrapper script here), which
# chunkah no longer counts as owned. Never select by mtime age: a
# "changed recently" rule flips a package's layer once it ages out.
#
# /run is emptied instead: every RUN step bumps its mtime (buildah's mount
# points), and a booted system mounts a tmpfs over it, so its contents are
# build leftovers nobody can see.
#
# Must be the LAST module. BlueBuild's post_build.sh still runs afterwards; the
# RPM-owned directories it touches (/, /var, /usr/lib/tmpfiles.d) are clamped
# to their package's build time, but /opt and rpm-ostree-base-db are not, so
# chunkah/unclaimed (~58 MB) still changes on every build.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Mount points are never touched: /etc/resolv.conf, /etc/hosts and the module
# mounts are bind mounts from the build host.
findmnt -rn -o TARGET | sed 's/\\x20/ /g' | tr '\n' '\0' | LC_ALL=C sort -zu >"$tmp/mounts"
# "<type> <path>" for every RPM-owned path, type as find's %y (f, l, d, ...).
rpm -qa --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' |
    awk '{ t = substr($1, 1, 1); if (t == "-") t = "f"; sub(/^[^ ]+ /, ""); print t " " $0 }' |
    tr '\n' '\0' | LC_ALL=C sort -zu >"$tmp/owned"

walk() {
    find / -xdev \( -path /proc -o -path /sys -o -path /dev -o -path /tmp -o -path /var \) -prune \
        -o "$@" | LC_ALL=C sort -z
}

# Skip any /run entry that is, or contains, a mount point (buildah's secrets).
while IFS= read -r -d '' entry; do
    if ! tr '\0' '\n' <"$tmp/mounts" | grep -qxF -e "$entry" && ! tr '\0' '\n' <"$tmp/mounts" | grep -qF -e "$entry/"; then
        rm -rf -- "$entry"
    fi
done < <(find /run -mindepth 1 -maxdepth 1 -print0)

zero_dirs() {
    walk -type d -print0 | LC_ALL=C comm -z -23 - "$tmp/mounts" >"$tmp/dirs"
    xargs -0 -r touch -h -d @0 -- <"$tmp/dirs"
}

# Content that differs between identical builds only in ordering: dnf5 writes
# the repos the dnf module enabled in a different section order every time.
for repo in /etc/dnf/repos.override.d/*.repo; do
    [ -f "$repo" ] || continue
    python3 - "$repo" <<'PY'
import sys
path = sys.argv[1]
head, sections, current = [], {}, None
with open(path) as f:
    for line in f:
        if line.startswith("["):
            current = line
            sections.setdefault(current, [])
        elif current is None:
            head.append(line)
        else:
            sections[current].append(line)
with open(path, "w") as f:
    f.write("".join(head + [l for name in sorted(sections) for l in [name] + sections[name]]))
PY
done

# fontconfig caches record each font directory's mtime, so regenerate them once
# the directories are zeroed. This also fixes the deployed system: there every
# directory is mtime 0, so caches recording the build time never validated and
# fontconfig rescanned every font into each user's ~/.cache/fontconfig.
zero_dirs
if command -v fc-cache >/dev/null; then
    fc-cache --system-only --force
fi

# Files first: a copy-up must not bump a directory after it has been zeroed.
walk ! -type d -printf '%y %p\0' | LC_ALL=C comm -z -23 - "$tmp/owned" |
    sed -z 's/^. //' | LC_ALL=C sort -z | LC_ALL=C comm -z -23 - "$tmp/mounts" >"$tmp/files"
xargs -0 -r touch -h -d @0 -- <"$tmp/files"
zero_dirs

files=$(tr -cd '\0' <"$tmp/files" | wc -c)
dirs=$(tr -cd '\0' <"$tmp/dirs" | wc -c)
left=$(xargs -0 -r stat -c '%Y' -- <"$tmp/dirs" | grep -cv '^0$' || true)
echo "normalize-mtimes: zeroed ${dirs} directories and ${files} files"
if [ "$left" -ne 0 ]; then
    echo "normalize-mtimes: ${left} directories still have a non-zero mtime" >&2
    exit 1
fi
