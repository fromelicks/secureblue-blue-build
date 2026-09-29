#!/usr/bin/env bash
set -euo pipefail

# Run after dnf. Keep CLI, desktop launches and codex:// links on the same
# native Wayland / standard allocator path. See docs/chatgpt.md.
app=/usr/lib/chatgpt
wrap=/usr/bin/with-standard-malloc
desktop=/usr/share/applications/chatgpt.desktop

fail() {
    echo "chatgpt-integration: $*" >&2
    exit 1
}

[ -x "$wrap" ] || fail "$wrap is missing from the base image"
[ -x "$app/ChatGPT" ] || fail "the RPM no longer contains $app/ChatGPT"
[ "$(readlink -f /usr/bin/chatgpt)" = "$app/codex-launcher" ] ||
    fail "/usr/bin/chatgpt no longer resolves to $app/codex-launcher"
[ -f "$app/codex-launcher" ] && [ ! -L "$app/codex-launcher" ] ||
    fail "codex-launcher is no longer a regular file"

# Fail on packaging changes that would bypass the launcher, including actions.
awk '
    /^Exec=/ { n++; if ($0 !~ /^Exec=chatgpt( |$)/) bad++ }
    END { exit !(n > 0 && bad == 0) }
' "$desktop" || fail "a desktop Exec= line no longer runs chatgpt"

# Replace the symlink target so direct codex-launcher calls are covered too.
# Arguments follow the default, allowing an explicit per-launch override.
cat > "$app/codex-launcher" <<EOF
#!/usr/bin/sh
exec ${wrap} ${app}/ChatGPT --ozone-platform=wayland "\$@"
EOF
chmod 0755 "$app/codex-launcher"

# This icon is in pixmaps, outside the hicolor cache. Check its desktop lookup
# and refresh the URL-handler cache before ostree fixes mtimes at epoch 0.
grep -qx 'Icon=chatgpt' "$desktop" || fail "the desktop icon name changed"
[ -s /usr/share/pixmaps/chatgpt.png ] || fail "the RPM's chatgpt icon is missing"
update-desktop-database /usr/share/applications
grep -q '^x-scheme-handler/codex=.*chatgpt\.desktop' \
    /usr/share/applications/mimeinfo.cache ||
    fail "codex:// has no handler in mimeinfo.cache"
