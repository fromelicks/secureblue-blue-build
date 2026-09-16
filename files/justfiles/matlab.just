# ── MATLAB / Simulink ──────────────────────────────────────────────────────
#
# MATLAB is installed once from the release ISO onto a host directory, and run
# from an Ubuntu distrobox that supplies the MathWorks-supported userspace.
# The display is a private Xwayland started per invocation by
# xwayland-satellite -- secureblue's global `set-xwayland` stays off.
#
# The image ships /etc/distrobox/matlab.ini as a TEMPLATE. `matlab-box` seeds
# a per-machine copy under ~/.config/distrobox/ and works from that, because
# the license server address is site configuration. Editing /etc would dirty
# `ostree admin config-diff` against AGENTS.md principle 4.
#
# See docs/matlab-distrobox.md.

# Install MATLAB from the release ISO. Takes hours; needs the GUI installer.
[group('MATLAB')]
matlab-install iso="":
    #!/usr/bin/env bash
    set -euo pipefail

    RELEASE='R2026a'
    INSTALL_DIR="${HOME}/.local/share/matlab-distrobox"
    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

    if [[ -x "${INSTALL_DIR}/${RELEASE}/bin/matlab" ]]; then
        printf 'MATLAB %s is already installed in %s.\n' "${RELEASE}" "${INSTALL_DIR}"
        printf 'Re-run the installer anyway to add or remove products.\n\n'
    fi

    iso='{{ iso }}'
    if [[ -z "${iso}" ]]; then
        # Newest match wins, so a later release ISO is picked up without the
        # recipe naming a version.
        iso="$(find "${HOME}/Downloads" -maxdepth 3 -iname '*_Linux.iso' -print0 2>/dev/null |
               xargs -0 -r ls -t 2>/dev/null | head -1 || true)"
    fi
    [[ -n "${iso}" && -f "${iso}" ]] ||
        fail "no installer ISO found. Pass one: ujust matlab-install /path/to/R2026a_Linux.iso"

    # Already mounted from an earlier run? Reuse it rather than stacking
    # another loop device on the same file.
    mnt="$(findmnt -rn -o TARGET -S "$(losetup -j "${iso}" -O NAME -n 2>/dev/null | head -1)" 2>/dev/null | head -1 || true)"
    if [[ -z "${mnt}" ]]; then
        printf 'Mounting %s\n' "${iso}"
        # udisks does this unprivileged via polkit -- no run0, and the mount
        # lands under /run/media/$USER where it is readable as the user.
        loopdev="$(udisksctl loop-setup -r -f "${iso}" |
                   sed -n 's/.* as \(\/dev\/loop[0-9]*\)\.*/\1/p')"
        [[ -n "${loopdev}" ]] || fail 'could not attach the ISO to a loop device'
        mnt="$(udisksctl mount -b "${loopdev}" | sed -n 's/.* at \(.*\)\.*$/\1/p')"
        [[ -n "${mnt}" ]] || fail "could not mount ${loopdev}"
    fi
    printf 'ISO mounted at %s\n\n' "${mnt}"

    [[ -x "${mnt}/install" ]] || fail "${mnt}/install is missing -- is this a MATLAB installer ISO?"

    mkdir -p "${INSTALL_DIR}"
    avail=$(df -BG --output=avail "${INSTALL_DIR}" | tail -1 | tr -dc '0-9')
    if (( avail < 80 )); then
        printf 'WARNING: only %sG free; the full product suite needs roughly 60-80G.\n' "${avail}" >&2
        read -rp 'Continue anyway? [y/N] ' proceed
        [[ "${proceed}" == [Yy]* ]] || exit 1
    fi

    cat <<NOTE

    The MathWorks installer will open on a private X display.

      Destination folder : ${INSTALL_DIR}/${RELEASE}
      Products           : leave everything selected -- the installer offers
                           exactly what your license covers, which is the
                           full suite.
      License            : log in with your MathWorks account, or use a File
                           Installation Key plus your network.lic.

    This takes hours. The window belongs to this terminal; closing the
    terminal ends the install.

    NOTE
    read -rp 'Start the installer? [Y/n] ' proceed
    [[ "${proceed}" == [Nn]* ]] && exit 0

    # LD_PRELOAD is fatal here: the installer's CEF front end (MATLABWindow)
    # dies instantly under hardened_malloc, leaving a parent spinning at 40%
    # CPU with no window and no error. Same reason the container wrappers
    # unset it. See docs/matlab-distrobox.md.
    env -u LD_PRELOAD /usr/libexec/fromelicks-xwayland-isolated "${mnt}/install"

    if [[ -x "${INSTALL_DIR}/${RELEASE}/bin/matlab" ]]; then
        printf '\nInstalled. Next: ujust matlab-box\n'
    else
        printf '\nThe installer exited without producing %s/bin/matlab.\n' "${INSTALL_DIR}/${RELEASE}" >&2
    fi

# Create (or re-create) the MATLAB distrobox and the desktop entry.
[group('MATLAB')]
matlab-box:
    #!/usr/bin/env bash
    set -euo pipefail

    RELEASE='R2026a'
    MANIFEST="${HOME}/.config/distrobox/matlab.ini"
    INSTALL_DIR="${HOME}/.local/share/matlab-distrobox"
    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

    # secureblue disables container-domain userns via the harden_container_userns
    # SELinux module. Without it podman cannot create the container at all.
    if [[ "$(ujust set-container-userns status)" != 'enabled' ]]; then
        fail "Container userns is disabled. Run 'ujust set-container-userns on' first."
    fi

    mkdir -p "$(dirname "${MANIFEST}")"
    if [[ ! -f "${MANIFEST}" ]]; then
        cp /etc/distrobox/matlab.ini "${MANIFEST}"
        printf 'Seeded %s from the image template.\n\n' "${MANIFEST}"
        printf 'Set MLM_LICENSE_FILE to your license server, then run this again.\n'
        exit 0
    fi

    if grep -q 'matlab-license.example.invalid' "${MANIFEST}"; then
        fail "${MANIFEST} still has the placeholder license server. Edit MLM_LICENSE_FILE."
    fi

    # podman would create the bind-mount source itself, but doing it here keeps
    # ownership with the user rather than depending on podman's behaviour.
    mkdir -p "${INSTALL_DIR}"

    printf 'Assembling the MATLAB box. The first run installs MathWorks*\n'
    printf 'dependencies inside it; progress appears here, full apt output in\n'
    printf '%s/setup.log\n\n' "${INSTALL_DIR}"
    distrobox assemble create --replace --file "${MANIFEST}"

    # Written on the host, not via distrobox-export: an exported entry runs
    # `distrobox enter` directly, which would start MATLAB with no X server
    # under GNOME's default --no-x11.
    #
    # StartupWMClass has to be set to something, and the value is a guess --
    # MATLAB's real X11 class is its window title, which embeds the license
    # type (" - academic use" on an academic license). If the taskbar shows a
    # second unmatched icon, read the truth off a running window with
    # `xprop WM_CLASS` and correct it here.
    #
    # No %f and no MimeType: `matlab <path>` is not a thing -- MATLAB opens
    # files through -r/-batch, so registering it as a .m handler produces a
    # launch that silently never opens a window.
    apps="${HOME}/.local/share/applications"
    mkdir -p "${apps}"
    cat > "${apps}/matlab.desktop" <<DESKTOP
    [Desktop Entry]
    Type=Application
    Name=MATLAB ${RELEASE}
    GenericName=Numerical Computing Environment
    Comment=MATLAB and Simulink
    Exec=/usr/libexec/fromelicks-matlab-launch
    Icon=matlab
    Terminal=false
    Categories=Development;Science;Math;IDE;
    Keywords=matlab;simulink;stateflow;simscape;
    StartupNotify=true
    StartupWMClass=MATLAB ${RELEASE}
    DESKTOP

    # mpm and the ISO installer both ship the icon inside the install tree but
    # register it nowhere the host icon theme looks.
    icon_src="$(find "${INSTALL_DIR}/${RELEASE}/toolbox/shared" "${INSTALL_DIR}/${RELEASE}/resources" \
        -name 'matlab_icon*.png' -print -quit 2>/dev/null || true)"
    if [[ -n "${icon_src}" ]]; then
        icon_dir="${HOME}/.local/share/icons/hicolor/256x256/apps"
        mkdir -p "${icon_dir}"
        install -m 0644 "${icon_src}" "${icon_dir}/matlab.png"
    fi
    update-desktop-database "${apps}" 2>/dev/null || true

    printf '\nDone. Launch with "ujust matlab" or the MATLAB %s desktop entry.\n' "${RELEASE}"

# Launch MATLAB on a private X display.
[group('MATLAB')]
matlab *args:
    @/usr/libexec/fromelicks-matlab-launch {{ args }}

# Report the state of the MATLAB setup and everything it depends on.
[group('MATLAB')]
check-matlab:
    #!/usr/bin/env bash
    set -uo pipefail

    RELEASE='R2026a'
    INSTALL_DIR="${HOME}/.local/share/matlab-distrobox"
    state() { printf '%-24s %s\n' "$1" "$2"; }

    if [[ "$(ujust set-container-userns status)" == 'enabled' ]]; then
        state 'container userns' 'enabled'
    else
        state 'container userns' 'DISABLED -- ujust set-container-userns on'
    fi

    # Deliberately does NOT report secureblue's set-xwayland toggle: this setup
    # runs its own Xwayland per invocation, so the global toggle is irrelevant
    # and reporting it would suggest a security reduction that is not needed.
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        state 'display' 'not a Wayland session -- xwayland-satellite cannot start'
    elif command -v xwayland-satellite >/dev/null; then
        state 'display' "private Xwayland via xwayland-satellite (${XDG_CURRENT_DESKTOP:-unknown})"
    else
        state 'display' 'xwayland-satellite MISSING'
    fi

    # Deliberately no `du`: this is meant to be a cheap report, and the tree is
    # tens of GB across hundreds of thousands of inodes.
    if [[ -x "${INSTALL_DIR}/${RELEASE}/bin/matlab" ]]; then
        state "MATLAB ${RELEASE}" "installed in ${INSTALL_DIR}"
    else
        state "MATLAB ${RELEASE}" 'not installed -- ujust matlab-install'
    fi

    # Anchored on the NAME column: `grep -qw matlab` would also match a
    # container called matlab-dev, since '-' is a word boundary.
    if distrobox list 2>/dev/null | awk -F'|' 'NR>1 && $2 ~ /^ *matlab *$/ { f=1 } END { exit !f }'; then
        state 'container' 'present'
    else
        state 'container' 'absent -- ujust matlab-box'
    fi

    if [[ -f "${HOME}/.local/share/applications/matlab.desktop" ]]; then
        state 'desktop entry' 'present'
    else
        state 'desktop entry' 'absent -- ujust matlab-box'
    fi

    manifest="${HOME}/.config/distrobox/matlab.ini"
    if [[ -f "${manifest}" ]]; then
        state 'license server' "$(sed -n 's/.*MLM_LICENSE_FILE=//p' "${manifest}" | head -1)"
    else
        state 'license server' 'no manifest yet -- ujust matlab-box'
    fi

# Destroy the MATLAB container. The MATLAB install on the host is kept.
[group('MATLAB')]
remove-matlab-box:
    #!/usr/bin/env bash
    set -euo pipefail
    distrobox rm --force matlab
    rm -f "${HOME}/.local/share/applications/matlab.desktop"
    printf '\nContainer removed. %s was left in place.\n' "${HOME}/.local/share/matlab-distrobox"
    printf 'Reclaim the disk with "ujust matlab-uninstall".\n'

# Delete the MATLAB install from the host. Frees tens of gigabytes.
[group('MATLAB')]
matlab-uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    install_dir="${HOME}/.local/share/matlab-distrobox"

    if [[ ! -d "${install_dir}" ]]; then
        printf 'Nothing to remove: %s does not exist.\n' "${install_dir}"
        exit 0
    fi

    printf 'This permanently deletes %s\n' "${install_dir}"
    printf 'and everything MATLAB has written into it. Re-installing means\n'
    printf 'running the ISO installer again.\n\n'
    read -rp 'Delete it? [y/N] ' proceed
    [[ "${proceed}" == [Yy]* ]] || { printf 'Aborted.\n'; exit 0; }

    # The install itself belongs to the user, but the container's init hook
    # writes setup.log as container-root, which maps to a subuid the host user
    # does not own -- so a plain rm cannot remove that one file.
    rm -rf "${install_dir}" 2>/dev/null ||
        podman unshare rm -rf "${install_dir}"
    printf 'Removed. Run "ujust matlab-install" to install again.\n'

# Install the Simulink Agentic Toolkit and wire it into Claude Code.
[group('MATLAB')]
matlab-agentic-toolkit:
    #!/usr/bin/env bash
    set -euo pipefail

    RELEASE='R2026a'
    INSTALL_DIR="${HOME}/.local/share/matlab-distrobox"
    CACHE="${HOME}/.local/share/matlab-agentic-toolkit"
    fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

    [[ -x "${INSTALL_DIR}/${RELEASE}/bin/matlab" ]] ||
        fail "MATLAB ${RELEASE} is not installed. Run 'ujust matlab-install' first."
    distrobox list 2>/dev/null |
        awk -F'|' 'NR>1 && $2 ~ /^ *matlab *$/ { f=1 } END { exit !f }' ||
        fail "the 'matlab' container does not exist. Run 'ujust matlab-box' first."

    # Fetched to a host directory and handed to the installer explicitly, so
    # the MATLAB side runs with Offline=true. Left to itself the installer
    # downloads these from inside the container, where a failure surfaces as a
    # MATLAB exception rather than a curl error.
    mkdir -p "${CACHE}"
    fetch() {
        local url="$1" dest="${CACHE}/$2"
        if [[ ! -s "${dest}" ]]; then
            printf 'Fetching %s\n' "$2"
            curl -sSfL --retry 3 "${url}" -o "${dest}" || fail "could not fetch ${url}"
        fi
    }
    fetch 'https://github.com/matlab/simulink-agentic-toolkit/releases/latest/download/agenticToolkitInstaller.mltbx' \
          'agenticToolkitInstaller.mltbx'
    fetch 'https://github.com/matlab/matlab-mcp-server/releases/latest/download/matlab-mcp-server-linux-x64' \
          'matlab-mcp-server-linux-x64'
    # Offline=true copies this file verbatim, mode included, so curl's 0644
    # would otherwise land a non-executable binary in the install root and
    # Claude Code's MCP server would fail with a bare "Permission denied".
    chmod +x "${CACHE}/matlab-mcp-server-linux-x64"
    fetch 'https://github.com/matlab/matlab-mcp-server/releases/latest/download/MATLABMCPServerToolbox.mltbx' \
          'MATLABMCPServerToolbox.mltbx'

    # The toolkit repositories are plain clones; the installer reads the skill
    # catalogue straight out of them.
    for repo in simulink-agentic-toolkit matlab-agentic-toolkit; do
        if [[ -d "${CACHE}/${repo}/.git" ]]; then
            git -C "${CACHE}/${repo}" pull --ff-only --quiet || true
        else
            git clone --depth 1 --quiet "https://github.com/matlab/${repo}.git" "${CACHE}/${repo}"
        fi
    done

    # -batch needs no display, but it DOES check out a license -- so the
    # license server has to be reachable for this step.
    printf '\nInstalling into MATLAB. This checks out a license and takes a few minutes.\n\n'
    distrobox enter --name matlab -- /usr/local/bin/matlab -batch "
        matlab.addons.toolbox.installToolbox('${CACHE}/agenticToolkitInstaller.mltbx');
        setupAgenticToolkit('install', Prompt=false, Offline=true, ...
            Toolkit=[\"matlab\", \"simulink\"], Agents=\"claude-code\", Scope=\"global\", ...
            MCPServerLocation='${CACHE}/matlab-mcp-server-linux-x64', ...
            MCPToolboxLocation='${CACHE}/MATLABMCPServerToolbox.mltbx', ...
            SimulinkAgenticToolkitLocation='${CACHE}/simulink-agentic-toolkit', ...
            MATLABAgenticToolkitLocation='${CACHE}/matlab-agentic-toolkit');
        setupAgenticToolkit('configure', Agents=\"claude-code\", Scope=\"global\", Prompt=false);
        setupAgenticToolkit('status');
    "

    # Belt and braces: the copy above is the usual culprit, but the install
    # root is what Claude Code actually executes.
    chmod +x "${HOME}/.matlab/agentic-toolkits/bin/matlab-mcp-server" 2>/dev/null || true

    cat <<'NOTE'

    Installed. The MCP server entry now lives in ~/.claude.json, which the
    host Claude Code reads.

    To use it, MATLAB has to be running and sharing its session:

        ujust matlab                 # in one terminal
        >> satk_initialize           # in the MATLAB command window

    satk_initialize calls shareMATLABSession() for you. Then restart Claude
    Code so it picks up the new MCP server and skills.

    If Claude Code reports that the MCP server cannot reach MATLAB, the
    host-side server is not finding the container's session -- see the
    "Reaching MATLAB from Claude Code" section of docs/matlab-distrobox.md
    for the podman-exec fallback.

    NOTE
