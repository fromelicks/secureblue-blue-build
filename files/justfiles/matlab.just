# ── MATLAB / Simulink ──────────────────────────────────────────────────────
#
# MATLAB is installed once from the release ISO onto a host directory, and run
# from a RHEL 9 (UBI) distrobox that supplies the MathWorks-supported
# userspace. The display is a private Xwayland started per invocation by
# xwayland-satellite -- secureblue's global `set-xwayland` stays off.
#
# The image ships /etc/distrobox/matlab.ini as a TEMPLATE. `matlab-box` seeds
# a per-machine copy under ~/.config/distrobox/ and works from that, because
# the license server address is site configuration.
#
# ujust runs recipes from /usr/share/ublue-os, so anything that depends on the
# caller's directory resolves against invocation_directory().
#
# See docs/matlab-distrobox.md.

# Install MATLAB from the release ISO. Takes hours; needs the GUI installer.
[group('MATLAB')]
[positional-arguments]
matlab-install iso="":
    #!/usr/bin/env bash
    set -euo pipefail
    source /usr/libexec/fromelicks-matlab-env

    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
    cd {{ quote(invocation_directory()) }}

    if matlab_installed; then
        printf 'MATLAB %s is already installed in %s.\n' "${MATLAB_RELEASE}" "${MATLAB_INSTALL_DIR}"
        printf 'Re-run the installer anyway to add or remove products.\n\n'
    fi

    iso="${1:-}"
    if [[ -n "${iso}" ]]; then
        iso="$(realpath -e -- "${iso}" 2>/dev/null)" || fail "no such file: ${1}"
    else
        # Newest match wins, so a later release ISO is picked up without the
        # recipe naming a version.
        iso="$(find "${HOME}/Downloads" -maxdepth 3 -iname '*_Linux.iso' -printf '%T@ %p\n' 2>/dev/null |
               sort -rn | head -1 | cut -d' ' -f2- || true)"
        [[ -n "${iso}" ]] ||
            fail "no installer ISO found in ~/Downloads. Pass one: ujust matlab-install /path/to/R2026a_Linux.iso"
    fi

    mount_of() { findmnt -rn -o TARGET -S "$1" 2>/dev/null | head -1 || true; }

    # Reuse a loop device already attached to this file, mounted or not, rather
    # than stacking another one on the same 14 GB image.
    loopdev="$(losetup -j "${iso}" -O NAME -n 2>/dev/null | head -1 || true)"
    if [[ -z "${loopdev}" ]]; then
        printf 'Attaching %s\n' "${iso}"
        # udisks does this unprivileged via polkit, and mounts land under
        # /run/media/$USER where they are readable as the user.
        out="$(udisksctl loop-setup -r -f "${iso}" 2>&1)" || fail "could not attach the ISO: ${out}"
        loopdev="$(sed -n 's/.* as \(\/dev\/loop[0-9]*\).*/\1/p' <<<"${out}")"
        [[ -n "${loopdev}" ]] || fail "could not parse the loop device from: ${out}"
    fi

    # Released on exit so the ISO does not stay mounted indefinitely. The next
    # run attaches it again.
    # loop-delete on a still-mounted device only arms autoclear and returns 0,
    # so check the result rather than trusting the exit code.
    release() {
        udisksctl unmount -b "${loopdev}" >/dev/null 2>&1 || true
        udisksctl loop-delete -b "${loopdev}" >/dev/null 2>&1 || true
        if [[ -n "$(losetup -j "${iso}" -O NAME -n 2>/dev/null)" ]]; then
            printf 'NOTE: %s is still attached; release it with\n' "${iso}" >&2
            printf '  udisksctl unmount -b %s && udisksctl loop-delete -b %s\n' "${loopdev}" "${loopdev}" >&2
        fi
    }
    trap release EXIT

    # GNOME automounts loop devices it sees appear, so give it a moment and
    # only mount if nobody has; losing that race is not an error.
    mnt=''
    for _ in {1..20}; do
        mnt="$(mount_of "${loopdev}")"
        [[ -n "${mnt}" ]] && break
        sleep 0.1
    done
    if [[ -z "${mnt}" ]]; then
        out="$(udisksctl mount -b "${loopdev}" 2>&1)" || true
        mnt="$(mount_of "${loopdev}")"
        [[ -n "${mnt}" ]] || fail "could not mount ${loopdev}: ${out}"
    fi
    printf 'ISO mounted at %s\n\n' "${mnt}"

    [[ -x "${mnt}/install" ]] || fail "${mnt}/install is missing -- is this a MATLAB installer ISO?"

    mkdir -p "${MATLAB_INSTALL_DIR}"
    avail=$(df -BG --output=avail "${MATLAB_INSTALL_DIR}" | tail -1 | tr -dc '0-9')
    if (( avail < 80 )); then
        printf 'WARNING: only %sG free; the full product suite needs roughly 60-80G.\n' "${avail}" >&2
        read -rp 'Continue anyway? [y/N] ' proceed
        [[ "${proceed}" == [Yy]* ]] || exit 1
    fi

    cat <<NOTE

    The MathWorks installer will open on a private X display.

      Destination folder : ${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE}
      Products           : leave everything selected -- the installer offers
                           exactly what your license covers, which is the
                           full suite.
      License            : log in with your MathWorks account, or use a File
                           Installation Key plus your network.lic.

    This takes hours. The window belongs to this terminal; closing the
    terminal ends the install. The ISO is unmounted when it finishes.

    NOTE
    read -rp 'Start the installer? [Y/n] ' proceed
    [[ "${proceed}" == [Nn]* ]] && exit 0

    # hardened_malloc kills the installer's CEF front end (MATLABWindow) the
    # instant it spawns, leaving no window and no error.
    env -u LD_PRELOAD /usr/libexec/fromelicks-xwayland-isolated "${mnt}/install" || true

    if matlab_installed; then
        printf '\nInstalled. Next: ujust matlab-box\n'
    else
        printf '\nThe installer exited without producing %s/bin/matlab.\n' \
            "${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE}" >&2
        exit 1
    fi

# Create (or re-create) the MATLAB distrobox and the desktop entry.
[group('MATLAB')]
matlab-box:
    #!/usr/bin/env bash
    set -euo pipefail
    source /usr/libexec/fromelicks-matlab-env

    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

    # secureblue disables container-domain userns via the harden_container_userns
    # SELinux module. Without it podman cannot create the container at all.
    if [[ "$(ujust set-container-userns status)" != 'enabled' ]]; then
        fail "Container userns is disabled. Run 'ujust set-container-userns on' first."
    fi

    mkdir -p "$(dirname "${MATLAB_MANIFEST}")"
    if [[ ! -f "${MATLAB_MANIFEST}" ]]; then
        cp "${MATLAB_MANIFEST_TEMPLATE}" "${MATLAB_MANIFEST}"
        printf 'Seeded %s from the image template.\n\n' "${MATLAB_MANIFEST}"
        printf 'Set MLM_LICENSE_FILE to your license server, then run this again.\n'
        exit 0
    fi

    # A copy seeded from an older image can be unusable (the old Ubuntu base no
    # longer pulls), so re-seed it and carry the license line across.
    template_rev="$(matlab_manifest_revision "${MATLAB_MANIFEST_TEMPLATE}")"
    user_rev="$(matlab_manifest_revision "${MATLAB_MANIFEST}")"
    if (( ${user_rev:-0} < ${template_rev:-0} )); then
        backup="${MATLAB_MANIFEST}.rev${user_rev:-0}.bak"
        license="$(grep -m1 '^additional_flags=--env MLM_LICENSE_FILE=' "${MATLAB_MANIFEST}" || true)"
        mv -f "${MATLAB_MANIFEST}" "${backup}"
        awk -v line="${license}" '
            line != "" && !done && /^additional_flags=--env MLM_LICENSE_FILE=/ { print line; done = 1; next }
            { print }' "${MATLAB_MANIFEST_TEMPLATE}" > "${MATLAB_MANIFEST}"
        printf 'Updated %s to template revision %s (was %s).\n' \
            "${MATLAB_MANIFEST}" "${template_rev}" "${user_rev:-none}"
        printf 'The old copy is at %s; carry over any other local edits by hand.\n\n' "${backup}"
    fi

    if grep -q 'matlab-license.example.invalid' "${MATLAB_MANIFEST}"; then
        fail "${MATLAB_MANIFEST} still has the placeholder license server. Edit MLM_LICENSE_FILE."
    fi

    # podman would create the bind-mount source itself, but doing it here keeps
    # ownership with the user rather than depending on podman's behaviour.
    mkdir -p "${MATLAB_INSTALL_DIR}"

    printf "Assembling the MATLAB box. The first run installs MathWorks' dependencies\n"
    printf 'inside it; progress appears here, full dnf output in\n'
    printf '%s/setup.log\n\n' "${MATLAB_INSTALL_DIR}"
    distrobox assemble create --replace --file "${MATLAB_MANIFEST}"

    # The installer ships the icon inside the install tree but registers it
    # nowhere the host icon theme looks. Skip the search once it is in place.
    icon_dir="${HOME}/.local/share/icons/hicolor/256x256/apps"
    icon_name='applications-science'
    if [[ -f "${icon_dir}/matlab.png" ]]; then
        icon_name='matlab'
    elif matlab_installed; then
        icon_src="$(find "${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE}/toolbox/shared" \
            "${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE}/resources" \
            -name 'matlab_icon*.png' -print -quit 2>/dev/null || true)"
        if [[ -n "${icon_src}" ]]; then
            mkdir -p "${icon_dir}"
            install -m 0644 "${icon_src}" "${icon_dir}/matlab.png"
            icon_name='matlab'
        fi
    fi

    # Written on the host, not via distrobox-export, which would run MATLAB
    # with no X server. StartupWMClass is a guess -- MATLAB's X11 class is its
    # window title, which embeds the license type; check with
    # `xprop WM_CLASS` if the taskbar shows a second icon. No %f/MimeType:
    # MATLAB does not open a file passed as an argument.
    apps="${HOME}/.local/share/applications"
    mkdir -p "${apps}"
    cat > "${apps}/matlab.desktop" <<DESKTOP
    [Desktop Entry]
    Type=Application
    Name=MATLAB ${MATLAB_RELEASE}
    GenericName=Numerical Computing Environment
    Comment=MATLAB and Simulink
    Exec=/usr/libexec/fromelicks-matlab-launch
    Icon=${icon_name}
    Terminal=false
    Categories=Development;Science;Math;IDE;
    Keywords=matlab;simulink;stateflow;simscape;
    StartupNotify=true
    StartupWMClass=MATLAB ${MATLAB_RELEASE}
    DESKTOP
    update-desktop-database "${apps}" 2>/dev/null || true

    printf '\nDone. Launch with "ujust matlab" or the MATLAB %s desktop entry.\n' "${MATLAB_RELEASE}"

# Launch MATLAB on a private X display, in the directory ujust was run from.
[group('MATLAB')]
[positional-arguments]
matlab *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd {{ quote(invocation_directory()) }}
    exec /usr/libexec/fromelicks-matlab-launch "$@"

# Report the state of the MATLAB setup and everything it depends on.
[group('MATLAB')]
check-matlab:
    #!/usr/bin/env bash
    set -uo pipefail
    source /usr/libexec/fromelicks-matlab-env

    state() { printf '%-24s %s\n' "$1" "$2"; }

    if [[ "$(ujust set-container-userns status)" == 'enabled' ]]; then
        state 'container userns' 'enabled'
    else
        state 'container userns' 'DISABLED -- ujust set-container-userns on'
    fi

    # The global set-xwayland toggle is deliberately not reported: this setup
    # runs its own Xwayland, and mentioning it would suggest a needless
    # security reduction.
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        state 'display' 'not a Wayland session -- xwayland-satellite cannot start'
    elif command -v xwayland-satellite >/dev/null; then
        state 'display' "private Xwayland via xwayland-satellite (${XDG_CURRENT_DESKTOP:-unknown})"
    else
        state 'display' 'xwayland-satellite MISSING'
    fi

    # No `du`: the tree is tens of GB, and this is meant to be cheap.
    if matlab_installed; then
        state "MATLAB ${MATLAB_RELEASE}" "installed in ${MATLAB_INSTALL_DIR}"
    else
        state "MATLAB ${MATLAB_RELEASE}" 'not installed -- ujust matlab-install'
    fi

    if matlab_box_exists; then
        state 'container' 'present'
    else
        state 'container' 'absent -- ujust matlab-box'
    fi

    if [[ -f "${HOME}/.local/share/applications/matlab.desktop" ]]; then
        state 'desktop entry' 'present'
    else
        state 'desktop entry' 'absent -- ujust matlab-box'
    fi

    if [[ -f "${MATLAB_MANIFEST}" ]]; then
        template_rev="$(matlab_manifest_revision "${MATLAB_MANIFEST_TEMPLATE}")"
        user_rev="$(matlab_manifest_revision "${MATLAB_MANIFEST}")"
        if (( ${user_rev:-0} < ${template_rev:-0} )); then
            state 'manifest' "OUTDATED (rev ${user_rev:-none} < ${template_rev}) -- ujust matlab-box"
        else
            state 'manifest' "rev ${user_rev}"
        fi
        state 'license server' "$(sed -n 's/.*MLM_LICENSE_FILE=//p' "${MATLAB_MANIFEST}" | head -1)"
    else
        state 'manifest' 'none yet -- ujust matlab-box'
    fi

# Destroy the MATLAB container. The MATLAB install on the host is kept.
[group('MATLAB')]
remove-matlab-box:
    #!/usr/bin/env bash
    set -euo pipefail
    source /usr/libexec/fromelicks-matlab-env

    # The desktop entry goes first, so it cannot outlive a container that was
    # already removed some other way.
    rm -f "${HOME}/.local/share/applications/matlab.desktop"
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true

    if matlab_box_exists; then
        distrobox rm --force "${MATLAB_BOX}"
        printf '\nContainer removed.'
    else
        printf 'No %s container to remove; desktop entry cleaned up.' "${MATLAB_BOX}"
    fi
    printf ' %s was left in place.\n' "${MATLAB_INSTALL_DIR}"
    printf 'Reclaim the disk with "ujust matlab-uninstall".\n'

# Delete the MATLAB install from the host. Frees tens of gigabytes.
[group('MATLAB')]
matlab-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    source /usr/libexec/fromelicks-matlab-env

    if [[ ! -d "${MATLAB_INSTALL_DIR}" ]]; then
        printf 'Nothing to remove: %s does not exist.\n' "${MATLAB_INSTALL_DIR}"
        exit 0
    fi

    printf 'This permanently deletes %s\n' "${MATLAB_INSTALL_DIR}"
    printf 'and everything MATLAB has written into it. Re-installing means\n'
    printf 'running the ISO installer again.\n\n'
    read -rp 'Delete it? [y/N] ' proceed
    [[ "${proceed}" == [Yy]* ]] || { printf 'Aborted.\n'; exit 0; }

    # setup.log is written by container-root, i.e. a subuid the host user does
    # not own, so a plain rm cannot remove that one file.
    rm -rf "${MATLAB_INSTALL_DIR}" 2>/dev/null ||
        podman unshare rm -rf "${MATLAB_INSTALL_DIR}"
    printf 'Removed. Run "ujust matlab-install" to install again.\n'

# Install the Simulink Agentic Toolkit and wire it into Claude Code.
[group('MATLAB')]
matlab-agentic-toolkit:
    #!/usr/bin/env bash
    set -euo pipefail
    source /usr/libexec/fromelicks-matlab-env

    CACHE="${HOME}/.local/share/matlab-agentic-toolkit"
    warn() { printf 'WARNING: %s\n' "$*" >&2; }
    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

    matlab_installed ||
        fail "MATLAB ${MATLAB_RELEASE} is not installed. Run 'ujust matlab-install' first."
    matlab_box_exists ||
        fail "the '${MATLAB_BOX}' container does not exist. Run 'ujust matlab-box' first."

    # Fetched on the host and handed to the installer with Offline=true, so a
    # download failure is a curl error rather than a MATLAB exception.
    # Refreshed every run, since the URLs track the latest release and the
    # toolkit repos below are pulled every run too. Downloads land in a temp
    # file first, so a dropped transfer never replaces a good copy.
    mkdir -p "${CACHE}"
    fetch() {
        local url="$1" dest="${CACHE}/$2" mode="$3" tmp
        tmp="$(mktemp "${dest}.XXXXXX")"
        printf 'Fetching %s\n' "$2"
        if curl -sSfL --retry 3 "${url}" -o "${tmp}"; then
            # Offline=true copies the file verbatim, mode included; a
            # non-executable server fails in Claude Code with a bare
            # "Permission denied".
            chmod "${mode}" "${tmp}"
            mv -f "${tmp}" "${dest}"
        else
            rm -f "${tmp}"
            [[ -s "${dest}" ]] || fail "could not fetch ${url}"
            warn "could not refresh $2; using the cached copy"
        fi
    }
    releases='https://github.com'
    fetch "${releases}/matlab/simulink-agentic-toolkit/releases/latest/download/agenticToolkitInstaller.mltbx" \
          'agenticToolkitInstaller.mltbx' 0644
    fetch "${releases}/matlab/matlab-mcp-server/releases/latest/download/matlab-mcp-server-linux-x64" \
          'matlab-mcp-server-linux-x64' 0755
    fetch "${releases}/matlab/matlab-mcp-server/releases/latest/download/MATLABMCPServerToolbox.mltbx" \
          'MATLABMCPServerToolbox.mltbx' 0644

    # The installer reads the skill catalogue straight out of these clones.
    for repo in simulink-agentic-toolkit matlab-agentic-toolkit; do
        if [[ -d "${CACHE}/${repo}/.git" ]]; then
            git -C "${CACHE}/${repo}" pull --ff-only --quiet ||
                warn "could not update ${repo}; using the existing checkout"
        else
            git clone --depth 1 --quiet "https://github.com/matlab/${repo}.git" "${CACHE}/${repo}"
        fi
    done

    # MATLAB's own launcher passes only the first line of a multi-line -batch
    # argument, so the steps go in a script. The directory is under $HOME so
    # the container sees it, and the file name has no hyphen: run() evaluates
    # the stem, and `a-b` parses as a subtraction.
    work="$(mktemp -d "${CACHE}/run_XXXXXX")"
    trap 'rm -rf "${work}"' EXIT
    cat > "${work}/fromelicks_satk_setup.m" <<MFILE
    matlab.addons.toolbox.installToolbox("${CACHE}/agenticToolkitInstaller.mltbx");
    setupAgenticToolkit("install", Prompt=false, Offline=true, ...
        Toolkit=["matlab", "simulink"], Agents="claude-code", Scope="global", ...
        MCPServerLocation="${CACHE}/matlab-mcp-server-linux-x64", ...
        MCPToolboxLocation="${CACHE}/MATLABMCPServerToolbox.mltbx", ...
        SimulinkAgenticToolkitLocation="${CACHE}/simulink-agentic-toolkit", ...
        MATLABAgenticToolkitLocation="${CACHE}/matlab-agentic-toolkit");
    % `install` does not configure the agent on its own.
    setupAgenticToolkit("configure", Agents="claude-code", Scope="global", Prompt=false);
    setupAgenticToolkit("status");
    MFILE

    # -batch needs no display, but it DOES check out a license.
    printf '\nInstalling into MATLAB. This checks out a license and takes a few minutes.\n\n'
    distrobox enter --name "${MATLAB_BOX}" -- \
        /usr/local/bin/matlab -batch "run('${work}/fromelicks_satk_setup.m')"

    chmod +x "${HOME}/.matlab/agentic-toolkits/bin/matlab-mcp-server" 2>/dev/null || true

    cat <<'NOTE'

    Installed. The MCP server entry now lives in ~/.claude.json, which the
    host Claude Code reads.

    To use it, MATLAB has to be running and sharing its session:

        ujust matlab                 # in one terminal
        >> satk_initialize           # in the MATLAB command window

    satk_initialize calls shareMATLABSession() for you. Then restart Claude
    Code so it picks up the new MCP server and skills.

    If the server reports it cannot reach MATLAB, see "Reaching MATLAB from
    Claude Code" in docs/matlab-distrobox.md: a stale session record and a
    MATLAB busy in pause() look alike and are not.

    NOTE
