#!/usr/bin/env bash
set -euo pipefail

# Claude Desktop (beta) ships only as a .deb from Anthropic's apt repository;
# there is no RPM or dnf repo yet. The payload is a self-contained Electron app
# under /usr (nothing in /opt), so unpack it straight into the image instead of
# running it from a Debian distrobox.
#
# Trust chain, same as apt's: the pinned signing key verifies InRelease, whose
# SHA256 covers Packages, whose SHA256 covers the .deb. Each step fails the
# build on a mismatch. The newest version is picked on every build, so the
# daily rebuild is the update mechanism.
#
# The package's maintainer scripts are NOT run. They write an AppArmor profile
# (irrelevant on SELinux), register the apt repo (no apt here) and install the
# GNOME search provider, which is replicated below.
#
# See docs/claude-desktop.md.

repo=https://downloads.claude.ai/claude-desktop/apt/stable
arch=amd64
fingerprint=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
app=/usr/lib/claude-desktop
wrap=/usr/bin/with-standard-malloc
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

fail() {
    echo "install-claude-desktop: $*" >&2
    exit 1
}

for tool in ar gpg gpgv curl sha256sum strings xz gtk-update-icon-cache update-desktop-database; do
    command -v "$tool" >/dev/null || fail "$tool is missing from the build image"
done
[ -x "$wrap" ] || fail "$wrap is missing from the base image"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

# gpgv needs a binary keyring, and the pinned file must hold exactly the
# expected key.
export GNUPGHOME="$work/gnupg"
mkdir -m 0700 "$GNUPGHOME"
gpg --batch --quiet --dearmor -o keyring.gpg "$script_dir/claude-desktop-archive-keyring.asc"
[ "$(gpg --batch --show-keys --with-colons keyring.gpg | awk -F: '/^fpr/ { print $10 }')" = "$fingerprint" ] ||
    fail "pinned key does not have fingerprint $fingerprint"

curl -fsSL --retry 3 -o InRelease "$repo/dists/stable/InRelease"
gpgv --keyring "$work/keyring.gpg" --output Release InRelease ||
    fail "InRelease signature does not verify against the pinned key"

# apt refuses an expired Release; so does this, so a frozen mirror cannot pin
# an old build forever.
valid_until=$(sed -n 's/^Valid-Until: //p' Release)
[ -n "$valid_until" ] || fail "Release has no Valid-Until"
[ "$(date -u -d "$valid_until" +%s)" -gt "$(date -u +%s)" ] ||
    fail "Release expired at $valid_until"

packages_sha=$(awk -v f="main/binary-$arch/Packages" '
    /^SHA256:/ { s = 1; next }
    /^[^ ]/    { s = 0 }
    s && $3 == f { print $1 }
' Release)
[ -n "$packages_sha" ] || fail "Release lists no SHA256 for main/binary-$arch/Packages"
curl -fsSL --retry 3 -o Packages "$repo/dists/stable/main/binary-$arch/Packages"
echo "$packages_sha  Packages" | sha256sum --quiet -c - || fail "Packages checksum mismatch"

# One "version filename sha256" line per claude-desktop stanza; keep the newest.
read -r version filename deb_sha < <(awk '
    /^Package: /  { p = $2; v = f = h = "" }
    /^Version: /  { v = $2 }
    /^Filename: / { f = $2 }
    /^SHA256: /   { h = $2 }
    /^$/          { if (p == "claude-desktop" && v && f && h) print v, f, h; p = "" }
    END           { if (p == "claude-desktop" && v && f && h) print v, f, h }
' Packages | sort -V -k1,1 | tail -n 1)
[ -n "${version:-}" ] || fail "no claude-desktop package in the $arch index"
case "$filename" in
    pool/main/c/claude-desktop/claude-desktop_*_"$arch".deb) ;;
    *) fail "unexpected package path: $filename" ;;
esac

echo "install-claude-desktop: installing $version"
curl -fsSL --retry 3 -o claude-desktop.deb "$repo/$filename"
echo "$deb_sha  claude-desktop.deb" | sha256sum --quiet -c - || fail ".deb checksum mismatch"

ar x claude-desktop.deb data.tar.xz
mkdir data
tar -xpJf data.tar.xz -C data --no-same-owner

# Everything must stay under /usr: /opt and /usr/local are /var symlinks on an
# atomic image and would not be part of the deployment.
stray=$(cd data && find . -mindepth 1 -maxdepth 1 ! -name usr)
[ -z "$stray" ] || fail "package installs outside /usr: $stray"
[ -x data/usr/lib/claude-desktop/claude-desktop ] || fail "the .deb has no usr/lib/claude-desktop/claude-desktop"

rm -rf "$app"
cp -a data/usr/lib/claude-desktop "$app"
cp -a data/usr/share/applications/com.anthropic.Claude.desktop /usr/share/applications/
cp -a data/usr/share/icons/hicolor/. /usr/share/icons/hicolor/
install -Dm0644 data/usr/share/doc/claude-desktop/copyright /usr/share/doc/claude-desktop/copyright

# Chromium's user-namespace sandbox works here (verified on the Legion), so
# the SUID fallback helper is not needed. Dropping the bit leaves one fewer
# setuid-root binary in the image; if userns ever stops working the app fails
# with "No usable sandbox" rather than quietly relying on SUID.
chmod 0755 "$app/chrome-sandbox"

# Electron aborts under hardened_malloc ("fatal allocator error: invalid
# uninitialized allocator usage"), same as VS Code. The .deb's /usr/bin entry is
# a symlink into $app; replace it with a wrapper. The .desktop file and its
# actions all run the bare `claude-desktop`, so they resolve to this wrapper
# without being edited.
rm -f /usr/bin/claude-desktop
cat > /usr/bin/claude-desktop <<EOF
#!/usr/bin/sh
exec ${wrap} ${app}/claude-desktop "\$@"
EOF
chmod 0755 /usr/bin/claude-desktop

# Every Exec= must be the bare name, or it bypasses the wrapper. No pipeline:
# under pipefail a failing or SIGPIPE'd grep would read as success.
awk '
    /^Exec=/ { n++; if ($0 !~ /^Exec=claude-desktop( |$)/) bad++ }
    END { exit !(n > 0 && bad == 0) }
' /usr/share/applications/com.anthropic.Claude.desktop ||
    fail "a desktop Exec= line no longer runs the bare claude-desktop"

# GNOME Shell search provider, which the .deb's postinst registers.
provider="$app/resources/gnome-search-provider"
install -Dm0644 "$provider/com.anthropic.Claude.search-provider.ini" \
    /usr/share/gnome-shell/search-providers/com.anthropic.Claude.search-provider.ini
install -Dm0644 "$provider/com.anthropic.Claude.SearchProvider.service" \
    /usr/share/dbus-1/services/com.anthropic.Claude.SearchProvider.service

# Both caches are generated by RPM scriptlets during the dnf module, which runs
# before this script, so anything dropped here afterwards is invisible to
# GNOME: the app grid showed a blank icon and claude:// had no handler. On an
# ostree image every mtime is epoch 0, so GTK cannot see that the cache is
# older than the directory and trusts it. Rebuild both, and check the new
# entries landed -- a silently stale cache is exactly the failure being fixed.
gtk-update-icon-cache --force --quiet /usr/share/icons/hicolor
# The cache is binary and `strings` can glue a preceding byte onto the name, so
# anchor only the end of the line, not both sides.
grep -qE '(^|[^[:alnum:]_.-])?claude-desktop$' \
    < <(strings /usr/share/icons/hicolor/icon-theme.cache) ||
    fail "claude-desktop is missing from the hicolor icon cache"

update-desktop-database /usr/share/applications
grep -q '^x-scheme-handler/claude=.*com\.anthropic\.Claude\.desktop' \
    /usr/share/applications/mimeinfo.cache ||
    fail "claude:// has no handler in mimeinfo.cache"
