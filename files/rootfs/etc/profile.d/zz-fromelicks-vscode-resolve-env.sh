#!/usr/bin/sh
# VS Code reads the user's environment by running a login shell that starts
# Electron in node mode, and Electron aborts under hardened_malloc. That shell
# sources hardened_malloc.sh, so drop LD_PRELOAD again for this probe only.
# The zz- prefix keeps this after hardened_malloc.sh.
# See docs/vscode-hardened-malloc.md.
if [ "${VSCODE_RESOLVING_ENVIRONMENT-}" = 1 ]; then
    unset LD_PRELOAD
fi
