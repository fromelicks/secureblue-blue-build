#!/usr/bin/env bash
set -euo pipefail

# PaperWM from a pinned upstream commit, not from extensions.gnome.org (EGO).
#
# The gnome-extensions module only installs what EGO has approved, and EGO
# rejected PaperWM's GNOME 51 upload (EGO version 151, "51.0.0"), so the
# module failed the whole build as soon as the base moved to GNOME 51. See
# docs/paperwm.md.
#
# Pin the commit, not the tag: v51.0.0 was moved after it was first
# published. The tarball's SHA256 is pinned too. Bump both together.
#
# Installs the same files PaperWM's Makefile packs into its release zip.
# The compiled schema must live in the extension's own schemas/ directory:
# PaperWM opens it from there and fails to load otherwise.

rev=2d460db8365b2dee235dde15103161e67df83247 # v51.0.0
sha256=ad490fd34a6aeb9275b18d00a2532e6031d08e84148cd738f09f9473cc959914
uuid=paperwm@paperwm.github.com
dest=/usr/share/gnome-shell/extensions/$uuid

fail() {
    echo "install-paperwm: $*" >&2
    exit 1
}

for tool in curl sha256sum tar jq glib-compile-schemas gnome-shell; do
    command -v "$tool" >/dev/null || fail "$tool is missing from the build image"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 5 -o "$work/paperwm.tar.gz" \
    "https://github.com/paperwm/PaperWM/archive/$rev.tar.gz"
echo "$sha256  $work/paperwm.tar.gz" | sha256sum --quiet -c - ||
    fail "tarball checksum mismatch for $rev"
mkdir "$work/src"
tar -xzf "$work/paperwm.tar.gz" -C "$work/src" --strip-components=1
src=$work/src

[ "$(jq -r .uuid "$src/metadata.json")" = "$uuid" ] ||
    fail "metadata.json does not declare uuid $uuid"

# GNOME Shell refuses an extension whose shell-version omits the running major
# (secureblue leaves disable-extension-version-validation off). Fail the build
# here, not silently at login.
gnome_major=$(gnome-shell --version | grep -oE '[0-9]+' | head -n 1)
[ -n "$gnome_major" ] || fail "cannot parse gnome-shell --version"
jq -e --arg v "$gnome_major" '."shell-version" | index($v)' "$src/metadata.json" >/dev/null ||
    fail "PaperWM $rev does not support GNOME $gnome_major (shell-version: $(jq -c '."shell-version"' "$src/metadata.json")); bump rev"

rm -rf "$dest"
install -d -m 0755 "$dest" "$dest/config" "$dest/resources" "$dest/schemas"
install -m 0644 "$src"/*.js "$src"/*.ui "$src/metadata.json" "$src/stylesheet.css" "$src/LICENSE" "$dest/"
install -m 0644 "$src/config/user.js" "$src/config/user.css" "$dest/config/"
install -m 0644 "$src"/resources/* "$dest/resources/"
install -m 0644 "$src/schemas/org.gnome.shell.extensions.paperwm.gschema.xml" "$dest/schemas/"
# Compile it here rather than trust the one in the tarball.
glib-compile-schemas --strict "$dest/schemas"

[ -s "$dest/schemas/gschemas.compiled" ] || fail "schema compilation produced nothing"
[ -s "$dest/extension.js" ] || fail "extension.js missing from $dest"

echo "install-paperwm: installed PaperWM $(jq -r '."version-name"' "$dest/metadata.json") ($rev) for GNOME $gnome_major"
