# ── MATLAB / Simulink distrobox ────────────────────────────────────────────

# The image ships /etc/distrobox/matlab.ini and matlab-products.txt as
# templates. Both are per-machine -- the license server address and the product
# set are site and hardware specific -- so `matlab-box` seeds copies under
# ~/.config/distrobox/ and works from those. Editing the copies rather than
# /etc is what keeps `ostree admin config-diff` clean, per AGENTS.md principle
# 4. See docs/matlab-distrobox.md.

# Create (or re-create) the MATLAB R2026a distrobox and export the GUI.
[group('MATLAB')]
matlab-box:
    #!/usr/bin/env bash
    set -euo pipefail

    MANIFEST="${HOME}/.config/distrobox/matlab.ini"
    PRODUCTS="${HOME}/.config/distrobox/matlab-products.txt"

    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

    # secureblue disables container-domain userns via the harden_container_userns
    # SELinux module. Without it podman cannot create the container at all.
    if [[ "$(ujust set-container-userns status)" != 'enabled' ]]; then
        fail "Container userns is disabled. Run 'ujust set-container-userns on' first."
    fi

    # MATLAB has no Wayland backend -- the desktop is an X11 client. secureblue's
    # toggle only passes --no-x11 to gnome-shell, i.e. it disables Mutter's
    # built-in Xwayland; /usr/bin/Xwayland is still there for anything that
    # starts its own. So this warns rather than blocks, and only for the session
    # it applies to: Niri (xwayland-satellite) and xpra both work without it.
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]] &&
       [[ "$(ujust set-xwayland status)" == 'disabled' ]]; then
        printf 'NOTE: Mutter is running with --no-x11, so MATLAB will not get a\n'
        printf 'display from this GNOME session. Options, cheapest first:\n'
        printf '  * log into the Niri session instead (xwayland-satellite, no toggle)\n'
        printf '  * run it through xpra (see docs/matlab-distrobox.md)\n'
        printf "  * ujust set-xwayland on   -- a deliberate security reduction\n\n"
        printf 'The box itself builds fine either way.\n\n'
    fi

    mkdir -p "$(dirname "${MANIFEST}")"
    seeded=0
    for pair in "matlab.ini:${MANIFEST}" "matlab-products.txt:${PRODUCTS}"; do
        template="/etc/distrobox/${pair%%:*}"
        target="${pair#*:}"
        if [[ ! -f "${target}" ]]; then
            cp "${template}" "${target}"
            printf 'Seeded %s from the image template.\n' "${target}"
            seeded=1
        fi
    done
    if (( seeded )); then
        printf '\nSet MLM_LICENSE_FILE in the manifest to your license server (and\n'
        printf 'adjust the product list if you want to), then run this again.\n'
        exit 0
    fi

    if grep -q 'matlab-license.example.invalid' "${MANIFEST}"; then
        fail "${MANIFEST} still has the placeholder license server. Edit MLM_LICENSE_FILE."
    fi

    if [[ -e "${HOME}/.local/share/matlab-distrobox/.installing-R2026a" ]]; then
        fail "A previous install did not finish. Run 'ujust reset-matlab-install' first."
    fi

    # The full Simulink family is a very large download.
    avail=$(df -BG --output=avail "${HOME}" | tail -1 | tr -dc '0-9')
    if (( avail < 60 )); then
        printf 'WARNING: only %sG free in %s; the install needs roughly 50G.\n' \
            "${avail}" "${HOME}" >&2
        read -rp 'Continue anyway? [y/N] ' proceed
        [[ "${proceed}" == [Yy]* ]] || exit 1
    fi

    # podman would create the bind-mount source itself, but doing it here keeps
    # ownership with the user rather than depending on podman's behaviour.
    mkdir -p "${HOME}/.local/share/matlab-distrobox"

    printf 'Assembling the MATLAB box. The first run downloads MATLAB and every\n'
    printf 'listed product and will take a long time. Progress lines appear here;\n'
    printf 'the full apt and mpm output goes to\n'
    printf '%s/.local/share/matlab-distrobox/setup.log\n\n' "${HOME}"
    distrobox assemble create --replace --file "${MANIFEST}"

# Report the state of the MATLAB distrobox and everything it depends on.
[group('MATLAB')]
check-matlab-box:
    #!/usr/bin/env bash
    set -uo pipefail

    state() { printf '%-28s %s\n' "$1" "$2"; }

    if [[ "$(ujust set-container-userns status)" == 'enabled' ]]; then
        state 'container userns' 'enabled'
    else
        state 'container userns' "DISABLED -- ujust set-container-userns on"
    fi

    # The GNOME override is present regardless of which session is running, so
    # reporting it unconditionally would tell Niri users to perform a security
    # reduction they do not need.
    xwayland="$(ujust set-xwayland status)"
    if [[ "${XDG_CURRENT_DESKTOP:-}" == *GNOME* ]]; then
        if [[ "${xwayland}" == 'enabled' ]]; then
            state 'Xwayland (GNOME)' 'enabled'
        else
            state 'Xwayland (GNOME)' "DISABLED -- ujust set-xwayland on, or use Niri/xpra"
        fi
    else
        state 'session' "${XDG_CURRENT_DESKTOP:-unknown} (GNOME toggle is ${xwayland}, not used here)"
    fi

    # Anchored on the NAME column: `grep -qw matlab` would also match a
    # container called matlab-dev, since '-' is a word boundary.
    if distrobox list 2>/dev/null | awk -F'|' 'NR>1 && $2 ~ /^ *matlab *$/ { f=1 } END { exit !f }'; then
        state 'container' 'present'
    else
        state 'container' "absent -- ujust matlab-box"
    fi

    install_dir="${HOME}/.local/share/matlab-distrobox"
    if [[ -x "${install_dir}/R2026a/bin/matlab" ]]; then
        # Deliberately no `du`: this is meant to be a cheap report, and the
        # tree is ~50G across hundreds of thousands of inodes.
        state 'MATLAB R2026a' "installed in ${install_dir}"
    elif [[ -e "${install_dir}/.installing-R2026a" ]]; then
        state 'MATLAB R2026a' "PARTIAL -- ujust reset-matlab-install"
    else
        state 'MATLAB R2026a' 'not installed'
    fi

    # distrobox-export names the exported copy "<container>-<original>".
    if [[ -f "${HOME}/.local/share/applications/matlab-matlab.desktop" ]]; then
        state 'exported application' 'present'
    else
        state 'exported application' 'absent'
    fi

    manifest="${HOME}/.config/distrobox/matlab.ini"
    if [[ -f "${manifest}" ]]; then
        state 'license server' "$(sed -n 's/.*MLM_LICENSE_FILE=//p' "${manifest}" | head -1)"
    else
        state 'license server' 'no manifest yet'
    fi

# Destroy the MATLAB container. The MATLAB install on the host volume is kept.
[group('MATLAB')]
remove-matlab-box:
    #!/usr/bin/env bash
    set -euo pipefail
    # distrobox-rm's cleanup_exports() already removes the exported binary and
    # every ~/.local/share/applications/matlab* entry, so there is nothing to
    # tidy up by hand here.
    distrobox rm --force matlab
    printf '\nContainer removed. %s/.local/share/matlab-distrobox was left in place.\n' "${HOME}"
    printf 'Reclaim the disk with "ujust reset-matlab-install".\n'

# Delete the MATLAB install from the host volume, after a failed or unwanted install.
[group('MATLAB')]
reset-matlab-install:
    #!/usr/bin/env bash
    set -euo pipefail
    install_dir="${HOME}/.local/share/matlab-distrobox"

    if [[ ! -d "${install_dir}" ]]; then
        printf 'Nothing to reset: %s does not exist.\n' "${install_dir}"
        exit 0
    fi

    printf 'This permanently deletes %s\n' "${install_dir}"
    printf 'and everything MATLAB has written into it. Re-installing means\n'
    printf 'downloading roughly 50G again.\n\n'
    read -rp 'Delete it? [y/N] ' proceed
    [[ "${proceed}" == [Yy]* ]] || { printf 'Aborted.\n'; exit 0; }

    # The tree is written by container-root, which maps to a subuid the host
    # user does not own, so a plain rm -rf cannot remove it.
    podman unshare rm -rf "${install_dir}"
    printf 'Removed. Run "ujust matlab-box" to install again.\n'
