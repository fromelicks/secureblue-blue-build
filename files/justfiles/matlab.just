# ── MATLAB / Simulink ──────────────────────────────────────────────────────
#
# MATLAB is installed by hand onto a host directory and run from a RHEL 9 (UBI)
# distrobox, on a private Xwayland per invocation. See docs/matlab-distrobox.md.
#
# ujust runs recipes from /usr/share/ublue-os, so anything that depends on the
# caller's directory resolves against invocation_directory().

matlab_release := "R2026a"

# Shared by the recipes below. Keep the release in sync with the init_hooks
# argument in /etc/distrobox/matlab.ini.
matlab_prelude := '''
# shellcheck disable=SC2034  # not every recipe uses every path
set -euo pipefail
MATLAB_RELEASE="''' + matlab_release + '''"
MATLAB_BOX=matlab
MATLAB_INSTALL_DIR="${HOME}/.local/share/matlab-distrobox"
MATLAB_MANIFEST="${HOME}/.config/distrobox/matlab.ini"
MATLAB_MANIFEST_TEMPLATE=/etc/distrobox/matlab.ini
MATLAB_DESKTOP="${HOME}/.local/share/applications/matlab.desktop"

warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

matlab_installed() { [[ -x "${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE}/bin/matlab" ]]; }

# Match the NAME column exactly; `grep -w matlab` would also match matlab-dev.
matlab_box_exists() {
    distrobox list 2>/dev/null |
        awk -F'|' -v box="${MATLAB_BOX}" 'NR>1 && $2 ~ "^ *" box " *$" { f=1 } END { exit !f }'
}

matlab_manifest_revision() { sed -n 's/^# fromelicks-matlab-manifest: *//p' "$1" 2>/dev/null | head -1; }
'''

# Create (or re-create) the MATLAB distrobox and the desktop entry.
[group('MATLAB')]
matlab-box:
    #!/usr/bin/env bash
    {{ matlab_prelude }}

    # secureblue's harden_container_userns SELinux module blocks podman.
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

    # Re-seed a copy from an older image, keeping its license line.
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

    # Created here so the bind-mount source is owned by the user, not podman.
    mkdir -p "${MATLAB_INSTALL_DIR}"

    printf "Assembling the MATLAB box. The first run installs MathWorks' dependencies;\n"
    printf 'full dnf output goes to %s/setup.log\n\n' "${MATLAB_INSTALL_DIR}"
    distrobox assemble create --replace --file "${MATLAB_MANIFEST}"

    # The installer does not register its icon with the host theme.
    icon_dir="${HOME}/.local/share/icons/hicolor/256x256/apps"
    icon_src="${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE}/bin/glnxa64/cef_resources/matlab_icon.png"
    icon_name='applications-science'
    if [[ -f "${icon_src}" ]]; then
        install -D -m 0644 "${icon_src}" "${icon_dir}/matlab.png"
        icon_name='matlab'
    fi

    # Not distrobox-export: that entry would start MATLAB with no X server.
    # StartupWMClass is a guess; check with `xprop WM_CLASS`.
    mkdir -p "$(dirname "${MATLAB_DESKTOP}")"
    cat > "${MATLAB_DESKTOP}" <<DESKTOP
    [Desktop Entry]
    Type=Application
    Name=MATLAB ${MATLAB_RELEASE}
    GenericName=Numerical Computing Environment
    Comment=MATLAB and Simulink
    Exec=ujust matlab
    Icon=${icon_name}
    Terminal=false
    Categories=Development;Science;Math;IDE;
    Keywords=matlab;simulink;stateflow;simscape;
    StartupNotify=true
    StartupWMClass=MATLAB ${MATLAB_RELEASE}
    DESKTOP
    update-desktop-database "$(dirname "${MATLAB_DESKTOP}")" 2>/dev/null || true

    matlab_installed ||
        warn "MATLAB is not installed in ${MATLAB_INSTALL_DIR}/${MATLAB_RELEASE} yet; see docs/matlab-distrobox.md."
    printf '\nDone. Launch with "ujust matlab" or the MATLAB %s desktop entry.\n' "${MATLAB_RELEASE}"

# Launch MATLAB on a private X display, in the directory ujust was run from.
[group('MATLAB')]
[positional-arguments]
matlab *args:
    #!/usr/bin/env bash
    {{ matlab_prelude }}
    cd {{ quote(invocation_directory()) }}

    matlab_installed ||
        fail "MATLAB ${MATLAB_RELEASE} is not installed in ${MATLAB_INSTALL_DIR}; see docs/matlab-distrobox.md."
    matlab_box_exists ||
        fail "the '${MATLAB_BOX}' container does not exist. Run 'ujust matlab-box'."

    (( $# )) || set -- -desktop
    # Escape hatch for broken hardware OpenGL.
    if [[ "${FROMELICKS_MATLAB_SOFTWARE_OPENGL:-0}" == '1' ]]; then
        set -- -softwareopengl "$@"
    fi

    # The X server runs on the host, MATLAB in the box; they share /tmp/.X11-unix.
    exec /usr/libexec/fromelicks-xwayland-isolated \
        distrobox enter --name "${MATLAB_BOX}" -- /usr/local/bin/matlab "$@"

# Report the state of the MATLAB setup and everything it depends on.
[group('MATLAB')]
check-matlab:
    #!/usr/bin/env bash
    {{ matlab_prelude }}
    set +e

    state() { printf '%-24s %s\n' "$1" "$2"; }

    if [[ "$(ujust set-container-userns status)" == 'enabled' ]]; then
        state 'container userns' 'enabled'
    else
        state 'container userns' 'DISABLED -- ujust set-container-userns on'
    fi

    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        state 'display' 'not a Wayland session -- xwayland-satellite cannot start'
    elif command -v xwayland-satellite >/dev/null; then
        state 'display' "private Xwayland via xwayland-satellite (${XDG_CURRENT_DESKTOP:-unknown})"
    else
        state 'display' 'xwayland-satellite MISSING'
    fi

    if matlab_installed; then
        state "MATLAB ${MATLAB_RELEASE}" "installed in ${MATLAB_INSTALL_DIR}"
    else
        state "MATLAB ${MATLAB_RELEASE}" "not installed in ${MATLAB_INSTALL_DIR} -- see docs/matlab-distrobox.md"
    fi

    if matlab_box_exists; then
        state 'container' 'present'
    else
        state 'container' 'absent -- ujust matlab-box'
    fi

    if [[ -f "${MATLAB_DESKTOP}" ]]; then
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
    {{ matlab_prelude }}

    rm -f "${MATLAB_DESKTOP}"
    update-desktop-database "$(dirname "${MATLAB_DESKTOP}")" 2>/dev/null || true

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
    {{ matlab_prelude }}

    if [[ ! -d "${MATLAB_INSTALL_DIR}" ]]; then
        printf 'Nothing to remove: %s does not exist.\n' "${MATLAB_INSTALL_DIR}"
        exit 0
    fi

    printf 'This permanently deletes %s\n' "${MATLAB_INSTALL_DIR}"
    printf 'and everything MATLAB has written into it.\n\n'
    read -rp 'Delete it? [y/N] ' proceed
    [[ "${proceed}" == [Yy]* ]] || { printf 'Aborted.\n'; exit 0; }

    # setup.log belongs to container-root, a subuid the host user does not own.
    rm -rf "${MATLAB_INSTALL_DIR}" 2>/dev/null ||
        podman unshare rm -rf "${MATLAB_INSTALL_DIR}"
    printf 'Removed.\n'

# Install the Simulink Agentic Toolkit and wire it into Claude Code.
[group('MATLAB')]
matlab-agentic-toolkit:
    #!/usr/bin/env bash
    {{ matlab_prelude }}

    CACHE="${HOME}/.local/share/matlab-agentic-toolkit"

    matlab_installed ||
        fail "MATLAB ${MATLAB_RELEASE} is not installed in ${MATLAB_INSTALL_DIR}."
    matlab_box_exists ||
        fail "the '${MATLAB_BOX}' container does not exist. Run 'ujust matlab-box' first."

    # Fetched on the host and installed with Offline=true, so download errors
    # surface here rather than as MATLAB exceptions. Refreshed every run, to
    # stay in step with the repos pulled below.
    mkdir -p "${CACHE}"
    fetch() {
        local url="$1" dest="${CACHE}/$2" mode="$3" tmp
        tmp="$(mktemp "${dest}.XXXXXX")"
        printf 'Fetching %s\n' "$2"
        if curl -sSfL --retry 3 "${url}" -o "${tmp}"; then
            # Offline=true keeps the file mode.
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

    for repo in simulink-agentic-toolkit matlab-agentic-toolkit; do
        if [[ -d "${CACHE}/${repo}/.git" ]]; then
            git -C "${CACHE}/${repo}" pull --ff-only --quiet ||
                warn "could not update ${repo}; using the existing checkout"
        else
            git clone --depth 1 --quiet "https://github.com/matlab/${repo}.git" "${CACHE}/${repo}"
        fi
    done

    # -batch keeps only the first line of its argument, so use a script. It
    # lives under $HOME for the container to see, and has no hyphen in its
    # name, since run() would parse `a-b` as a subtraction.
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
    % "install" does not configure the agent on its own.
    setupAgenticToolkit("configure", Agents="claude-code", Scope="global", Prompt=false);
    setupAgenticToolkit("status");
    MFILE

    printf '\nInstalling into MATLAB. This checks out a license and takes a few minutes.\n\n'
    distrobox enter --name "${MATLAB_BOX}" -- \
        /usr/local/bin/matlab -batch "run('${work}/fromelicks_satk_setup.m')"

    chmod +x "${HOME}/.matlab/agentic-toolkits/bin/matlab-mcp-server" 2>/dev/null || true

    # The Simulink tools only resolve after satk_initialize, once per session.
    # Kept between markers so a re-run replaces the block, not appends to it.
    startup="${HOME}/Documents/MATLAB/startup.m"
    begin='% >>> fromelicks: Simulink Agentic Toolkit >>>'
    end='% <<< fromelicks: Simulink Agentic Toolkit <<<'
    mkdir -p "$(dirname "${startup}")"
    touch "${startup}"
    kept="$(awk -v b="${begin}" -v e="${end}" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "${startup}")"
    {
        [[ -n "${kept}" ]] && printf '%s\n' "${kept}"
        printf '%s\n' "${begin}"
        cat <<MFILE
    satkDir = fullfile(getenv('HOME'), '.matlab', 'agentic-toolkits', 'simulink');
    if contains(version, '${MATLAB_RELEASE}') && ~batchStartupOptionUsed && isfolder(satkDir)
        addpath(satkDir)
        satk_initialize
    end
    clear satkDir
    MFILE
        printf '%s\n' "${end}"
    } > "${startup}.tmp"
    mv -f "${startup}.tmp" "${startup}"

    cat <<NOTE

    Installed. ${startup} now runs satk_initialize
    whenever MATLAB starts; restart MATLAB if it is already running:

        ujust matlab

    Then restart Claude Code so it picks up the new MCP server and skills.
    See docs/matlab-distrobox.md if the server cannot reach MATLAB.

    NOTE
