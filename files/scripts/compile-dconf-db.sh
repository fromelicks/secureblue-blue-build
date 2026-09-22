#!/usr/bin/env bash
set -euo pipefail

# /etc/dconf/db/local.d/* is source only: GSettings reads the compiled binary
# database at /etc/dconf/db/local, which the `files` module cannot produce. The
# base image ships an empty one, so without this step every keyfile this repo
# adds under local.d/ is inert.
#
# `dconf compile` rather than `dconf update`: update rebuilds every
# /etc/dconf/db/*.d in the image -- including distro.d's 20-authselect symlink
# and ibus.d -- and there is no reason to rewrite databases this repo does not
# own.
#
# dconf has no notion of GSettings schemas, so a mistyped path compiles
# perfectly and then does nothing. Every key is read back below.

db=/etc/dconf/db/local
src=/etc/dconf/db/local.d
profile=/etc/dconf/profile/user

# Each entry is a dconf path and the value it must hold after the compile.
expected=(
    "/org/gnome/desktop/notifications/application/gnome-power-panel/show-in-lock-screen=false"
)

fail() {
    echo "compile-dconf-db: $*" >&2
    exit 1
}

command -v dconf >/dev/null || fail "dconf is missing from the image"
[ -d "$src" ] || fail "$src does not exist"

# A database nothing reads is worse than no database: it looks applied.
grep -qx 'system-db:local' "$profile" ||
    fail "$profile no longer reads system-db:local"

dconf compile "$db" "$src"

# Reading the compiled file needs a profile that points at it. file-db: is
# read-only and pulls in no user database, so this touches nothing else.
readback=$(mktemp)
trap 'rm -f "$readback"' EXIT
printf 'file-db:%s\n' "$db" > "$readback"

for entry in "${expected[@]}"; do
    key=${entry%%=*}
    want=${entry#*=}
    got=$(DCONF_PROFILE="$readback" dconf read "$key")
    [ "$got" = "$want" ] ||
        fail "$key reads '${got:-<unset>}' after the compile, expected '$want'"
done
