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
# published. The commit is fetched with git, and git checks the content
# against the commit hash. GitHub's generated archives are not byte-stable,
# so a separate SHA256 pin would add nothing but a second value to keep in
# step.
#
# Installs the same files PaperWM's Makefile packs into its release zip.
# The compiled schema must live in the extension's own schemas/ directory:
# PaperWM opens it from there and fails to load otherwise.

rev=2d460db8365b2dee235dde15103161e67df83247 # v51.0.0
repo=https://github.com/paperwm/PaperWM.git
uuid=paperwm@paperwm.github.com
dest=/usr/share/gnome-shell/extensions/$uuid

fail() {
    echo "install-paperwm: $*" >&2
    exit 1
}

for tool in git jq glib-compile-schemas gnome-shell; do
    command -v "$tool" >/dev/null || fail "$tool is missing from the build image"
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
src=$work/src

git init -q "$src"
git -C "$src" fetch -q --depth 1 "$repo" "$rev" || fail "cannot fetch $rev from $repo"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[ "$(git -C "$src" rev-parse HEAD)" = "$rev" ] || fail "fetched commit is not $rev"

[ "$(jq -r .uuid "$src/metadata.json")" = "$uuid" ] ||
    fail "metadata.json does not declare uuid $uuid"

# GNOME Shell refuses an extension whose shell-version omits the running major
# (secureblue leaves disable-extension-version-validation off). Fail the build
# here, not silently at login.
shell_version=$(gnome-shell --version) || fail "gnome-shell --version failed"
gnome_major=$(grep -oE '[0-9]+' <<<"$shell_version" | head -n 1) || true
[ -n "$gnome_major" ] || fail "cannot parse gnome-shell --version: $shell_version"
jq -e --arg v "$gnome_major" '."shell-version" | index($v)' "$src/metadata.json" >/dev/null ||
    fail "PaperWM $rev does not support GNOME $gnome_major (shell-version: $(jq -c '."shell-version"' "$src/metadata.json")); bump rev"

# Globs rather than file names, so a file upstream adds to one of these
# directories is not dropped without an error.
rm -rf "$dest"
install -d -m 0755 "$dest" "$dest/config" "$dest/schemas"
install -m 0644 "$src"/*.js "$src"/*.ui "$src/metadata.json" "$src/stylesheet.css" "$src/LICENSE" "$dest/"
install -m 0644 "$src"/config/* "$dest/config/"
install -m 0644 "$src"/schemas/*.gschema.xml "$dest/schemas/"
cp -r "$src/resources" "$dest/resources"
# Compile it here rather than trust the one in the repo.
glib-compile-schemas --strict "$dest/schemas"

# Normalise all modes explicitly, rather than rely on the build step's umask.
find "$dest" -type d -exec chmod 0755 {} +
find "$dest" -type f -exec chmod 0644 {} +

[ -s "$dest/schemas/gschemas.compiled" ] || fail "schema compilation produced nothing"
[ -s "$dest/extension.js" ] || fail "extension.js missing from $dest"

echo "install-paperwm: installed PaperWM $(jq -r '."version-name"' "$dest/metadata.json") ($rev) for GNOME $gnome_major"
