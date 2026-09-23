#!/usr/bin/env bash
set -euo pipefail

# VS Code (Electron) aborts under hardened_malloc, which secureblue preloads
# for every user process via LD_PRELOAD (environment.d, profile.d and systemd
# DefaultEnvironment). /etc/ld.so.preload is 0600 root, so glibc skips it for
# unprivileged processes: dropping LD_PRELOAD is enough, which is what
# secureblue's own with-standard-malloc helper does.
#
# Every file edited here is owned by the `code` RPM, so this must run after the
# dnf module. Each edit is checked, so an upstream change fails the build
# instead of silently shipping an unwrapped launcher.
#
# Desktop launches also need /etc/profile.d/zz-fromelicks-vscode-resolve-env.sh.
# See docs/vscode-hardened-malloc.md.

wrap=/usr/bin/with-standard-malloc
target=/usr/share/code/bin/code

fail() {
    echo "vscode-standard-malloc: $*" >&2
    exit 1
}

[ -x "$wrap" ] || fail "$wrap is missing from the base image"

# 1.139.0 renamed the desktop files to reverse-DNS IDs (code.desktop ->
# com.microsoft.VSCode.desktop), so find them by the launcher they run.
mapfile -t desktops < <(
    grep -lE '^Exec=/usr/share/code/code([[:space:]]|$)' /usr/share/applications/*.desktop
)
[ "${#desktops[@]}" -ge 2 ] ||
    fail "found ${#desktops[@]} desktop files launching /usr/share/code/code, expected the application and URL-handler entries"

for desktop in "${desktops[@]}"; do
    sed -i "s|^Exec=/usr/share/code/code|Exec=${wrap} /usr/share/code/code|" "$desktop"
    # At least one Exec= line, and every one of them wrapped. No pipeline:
    # under pipefail a failing or SIGPIPE'd grep would read as success.
    awk -v prefix="Exec=${wrap} " '
        /^Exec=/ { n++; if (index($0, prefix) != 1) bad++ }
        END { exit !(n > 0 && bad == 0) }
    ' "$desktop" || fail "missing or unwrapped Exec= line in $desktop"
done

# /usr/bin/code is a symlink to the launcher script. Replace it with a wrapper;
# the target is not a symlink, so its `dirname "$0"/..` lookup still resolves
# /usr/share/code.
[ "$(readlink /usr/bin/code)" = "$target" ] ||
    fail "/usr/bin/code is no longer a symlink to $target"
[ -x "$target" ] || fail "$target is missing"
rm /usr/bin/code
cat > /usr/bin/code <<EOF
#!/usr/bin/sh
exec ${wrap} ${target} "\$@"
EOF
chmod 0755 /usr/bin/code
