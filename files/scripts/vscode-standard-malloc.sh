#!/usr/bin/env bash
set -euo pipefail

# VS Code (Electron) does not run under hardened_malloc, which secureblue
# preloads for every user process via LD_PRELOAD (environment.d, profile.d and
# systemd DefaultEnvironment). /etc/ld.so.preload is 0600 root, so glibc skips
# it for unprivileged processes: dropping LD_PRELOAD is enough.
#
# Every file edited here is owned by the `code` RPM, so this must run after the
# dnf module. Each edit is checked, so an upstream change fails the build
# instead of silently shipping an unwrapped launcher.

wrap='/usr/bin/env -u LD_PRELOAD'

for desktop in /usr/share/applications/code.desktop \
               /usr/share/applications/code-url-handler.desktop; do
    sed -i "s|^Exec=/usr/share/code/code|Exec=${wrap} /usr/share/code/code|" "$desktop"
    if grep '^Exec=' "$desktop" | grep -vq "^Exec=${wrap} "; then
        echo "unwrapped Exec= line left in $desktop" >&2
        exit 1
    fi
done

# /usr/bin/code is a symlink to /usr/share/code/bin/code. Replace it with a
# wrapper; the target is not a symlink, so its `dirname "$0"/..` lookup still
# resolves /usr/share/code.
test -x /usr/share/code/bin/code
rm -f /usr/bin/code
cat > /usr/bin/code <<'EOF'
#!/usr/bin/sh
exec /usr/bin/env -u LD_PRELOAD /usr/share/code/bin/code "$@"
EOF
chmod 0755 /usr/bin/code
