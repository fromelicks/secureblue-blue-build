#!/usr/bin/env bash
set -euo pipefail

# Build AmneziaWG's userspace stack from source.
#
# AmneziaWG is WireGuard plus traffic obfuscation. Neither half is packaged for
# Fedora: the upstream COPR (amneziavpn/amneziawg) enables EPEL and CentOS
# chroots only -- zero Fedora chroots -- and its newest build is from 2024,
# which predates the protocol entirely.
#
#   amneziawg-tools  awg(8) and awg-quick(8), a wireguard-tools fork
#   amneziawg-go     the userspace datapath, a wireguard-go fork
#
# There is no kernel module here and we deliberately do not build one: it would
# need DKMS or akmods against a secureblue kernel, and the userspace datapath is
# plenty for a single remote peer. awg-quick's add_if() already falls back to
# `amneziawg-go` when /sys/module/amneziawg is absent, so the fallback needs no
# configuration -- only the binary on PATH.
#
# Both are pinned to a tag AND verified by commit SHA. A tag is mutable; the
# commit it resolved to when this was written is not. The v3.1 series is what
# understands protocol_version 3.1 (I1-I5, S3/S4, HeaderProtectionKey,
# RandomTrailers, and range-valued timers like "RekeyAfterTime = 100-120").
# Older releases -- including everything in that COPR -- reject those keys.
# See docs/amneziawg.md.

readonly TOOLS_REPO='https://github.com/amnezia-vpn/amneziawg-tools'
readonly TOOLS_TAG='v3.1.20260812'
readonly TOOLS_SHA='ee0f0a9aa34ff0a0da4b3433b9512781cfe02843'

readonly GO_REPO='https://github.com/amnezia-vpn/amneziawg-go'
readonly GO_TAG='v3.1.20260828'
readonly GO_SHA='b5928efb6ca19f0153958460c3d141f04abc5c2e'

# gcc, make, git, golang and libmnl are already in the image; only the headers
# are missing. Removed again at the end so they do not ship.
readonly BUILD_DEPS=(libmnl-devel)

log() { printf '\n=== %s ===\n' "$*"; }

workdir="$(mktemp -d)"
cleanup() {
    rm -rf "${workdir}"
    # Never let cleanup mask a build failure.
    return 0
}
trap cleanup EXIT

log 'Installing build dependencies'
dnf install -y "${BUILD_DEPS[@]}"

fetch() {
    local repo="$1" tag="$2" want="$3" dest="$4" got
    git clone --depth 1 --branch "${tag}" "${repo}" "${dest}"
    got="$(git -C "${dest}" rev-parse HEAD)"
    if [[ "${got}" != "${want}" ]]; then
        printf 'ERROR: %s %s is %s, expected %s\n' "${repo}" "${tag}" "${got}" "${want}" >&2
        exit 1
    fi
    printf 'verified %s %s at %s\n' "${repo##*/}" "${tag}" "${got}"
}

log "Fetching amneziawg-tools ${TOOLS_TAG}"
fetch "${TOOLS_REPO}" "${TOOLS_TAG}" "${TOOLS_SHA}" "${workdir}/tools"

log "Fetching amneziawg-go ${GO_TAG}"
fetch "${GO_REPO}" "${GO_TAG}" "${GO_SHA}" "${workdir}/go"

# WITH_WGQUICK/WITH_BASHCOMPLETION/WITH_SYSTEMDUNITS all auto-detect to yes
# here; naming them makes the build fail loudly rather than silently omitting
# awg-quick or the awg-quick@.service template we rely on.
log 'Building amneziawg-tools'
make -C "${workdir}/tools/src" -j"$(nproc)" \
    WITH_WGQUICK=yes WITH_BASHCOMPLETION=yes WITH_SYSTEMDUNITS=yes
make -C "${workdir}/tools/src" \
    WITH_WGQUICK=yes WITH_BASHCOMPLETION=yes WITH_SYSTEMDUNITS=yes \
    PREFIX=/usr SYSCONFDIR=/etc SYSTEMDUNITDIR=/usr/lib/systemd/system install

log 'Building amneziawg-go'
# Keep the module and build caches inside the workdir so nothing survives into
# the image; normalize-mtimes.sh would otherwise have stray trees to walk.
export GOPATH="${workdir}/gopath" GOCACHE="${workdir}/gocache" GOFLAGS=-trimpath
make -C "${workdir}/go" -j"$(nproc)"
install -Dm755 "${workdir}/go/amneziawg-go" /usr/bin/amneziawg-go
go clean -cache -modcache 2>/dev/null || true

log 'Removing build dependencies'
dnf remove -y "${BUILD_DEPS[@]}"

# awg-quick resolves a bare interface name to /etc/amnezia/amneziawg/<name>.conf
# and refuses a world-readable config. The directory is image-owned; the config
# inside it is per-machine runtime state and is never baked (AGENTS.md
# principle 2).
install -dm700 /etc/amnezia/amneziawg

log 'Verifying the install'
fail=0
for bin in /usr/bin/awg /usr/bin/awg-quick /usr/bin/amneziawg-go; do
    if [[ -x "${bin}" ]]; then
        printf 'ok: %s\n' "${bin}"
    else
        printf 'ERROR: missing %s\n' "${bin}" >&2
        fail=1
    fi
done

# The awg-quick@.service template is what `ujust awg-up` enables.
if [[ -f /usr/lib/systemd/system/awg-quick@.service ]]; then
    printf 'ok: awg-quick@.service\n'
else
    printf 'ERROR: missing /usr/lib/systemd/system/awg-quick@.service\n' >&2
    fail=1
fi

# Assert the protocol 3.1 vocabulary really is present. `awg` embeds its key
# names; if a future tag drops one, every config we generate breaks silently at
# connect time instead of here.
missing=()
for key in I1 S3 S4 HeaderProtectionKey RandomTrailers DisableCookies; do
    grep -qF "${key}" /usr/bin/awg || missing+=("${key}")
done
if (( ${#missing[@]} )); then
    printf 'ERROR: awg does not know protocol 3.1 keys: %s\n' "${missing[*]}" >&2
    fail=1
else
    printf 'ok: awg understands the protocol 3.1 keys\n'
fi

exit "${fail}"
