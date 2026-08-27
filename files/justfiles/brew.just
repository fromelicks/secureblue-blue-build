# ── Homebrew helpers ───────────────────────────────────────────────────────

# `run0 -u linuxbrew` (as brew-proxy's README suggests) cannot work here: the
# linuxbrew account is created locked by sysusers.d and run0 runs PAM account
# management, which rejects it. This uses systemd-run instead, which does not.
# Open an interactive shell as the linuxbrew user.
[group('Brew')]
brew-shell:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "Starting a shell as linuxbrew (systemd-run, no PAM session)."
    echo "For ordinary brew commands you do NOT need this -- just run 'brew ...',"
    echo "which the /usr/bin/brew shim forwards to the brew-proxy DBus service."
    echo ""
    run0 -i systemd-run --pty --wait --collect --quiet \
        --unit="brew-shell-$$" \
        --uid=linuxbrew \
        --working-directory=/home/linuxbrew \
        --setenv=HOMEBREW_PREFIX=/home/linuxbrew/.linuxbrew \
        --setenv=HOMEBREW_CELLAR=/home/linuxbrew/.linuxbrew/Cellar \
        --setenv=HOMEBREW_REPOSITORY=/home/linuxbrew/.linuxbrew/Homebrew \
        --setenv=NO_BREW_PROXY=1 \
        /bin/bash -l

# Explains the run0 limitation if it is hit.
# Report whether the supported brew path (shim + brew-proxy DBus service) is healthy.
[group('Brew')]
check-brew:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "--- brew shim ---"
    command -v brew || echo "brew is not on PATH"
    echo ""
    echo "--- brew-proxy ---"
    for u in brew-proxy-setup.service brew-proxy-daemon.service; do
        printf '%-30s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
    done
    echo ""
    echo "--- scheduled brew jobs ---"
    for u in brew-update.timer brew-upgrade.timer brew-update.service brew-upgrade.service; do
        printf '%-30s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
    done
    echo ""
    echo "--- linuxbrew account ---"
    getent passwd linuxbrew || echo "no linuxbrew account"
    echo ""
    echo "Note: sysusers.d creates linuxbrew with the 'u!' (locked) modifier, which"
    echo "sets both a locked password and an expiry date of 1970-01-02. Anything"
    echo "that opens a PAM session as linuxbrew -- run0, su, login -- therefore"
    echo "fails with 'User account has expired'. That is by design, not breakage:"
    echo "the brew shim, brew-proxy, and the brew-*.service units all bypass PAM."
    echo "Use 'ujust brew-shell' if you genuinely need a linuxbrew shell."
