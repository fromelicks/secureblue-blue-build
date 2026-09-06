#!/usr/bin/env bash
set -euo pipefail

# One lock-screen defect in DMS's Modules/Lock/LockScreenContent.qml, not yet
# fixed upstream as of 1.6.0 (2026-09-06):
#
#   Enter (or the enter button) on an empty password field starts a PAM
#   attempt. It cannot succeed, and it spends the faillock budget, so a stray
#   Enter moves the session towards a real lockout for nothing. Guarded by a
#   new canSubmitPassword(), which still allows an empty submit when the PAM
#   stack is not DMS's own (lockPamExternallyManaged or a custom lockPamPath)
#   -- there the conversation itself may prompt for an inline u2f/fingerprint
#   touch and Enter is how the user starts it.
#
# canSubmitPassword() is inserted right after upstream's own
# securityKeyShortcutMatches(), the last function DMS defines before
# Component.onCompleted in that block. 1.6.0 added triggerSecurityKeyUnlock()
# and securityKeyShortcutMatches() at the exact spot this hunk used to target
# (straight after canStartSecurityKeyUnlock()), so re-anchor here again if a
# future DMS release adds another function in the same place.
#
# A second defect this patch used to carry -- Ctrl+Backspace falling through
# to plain Backspace instead of deleting a word -- was fixed upstream in
# 262acda3 ("fix(lock): handle ctrl-backspace", 2026-08-18, issue #3087) and
# shipped in 1.6.0 (`case Qt.Key_W: case Qt.Key_Backspace:` is now stock).
# That hunk is gone from this patch; do not re-add it.
#
# Runs after the dnf module installs `dms`, so it always patches the exact
# version this build shipped. --forward with zero fuzz means a DMS release that
# reworks these hunks fails the build loudly rather than silently dropping the
# fix or corrupting the file.

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dms_dir=/usr/share/quickshell/dms

if [ ! -d "$dms_dir" ]; then
	echo "patch-dms-lockscreen: $dms_dir missing; is the dms package still installed?" >&2
	exit 1
fi

echo "patch-dms-lockscreen: patching DMS $(cat "$dms_dir/VERSION")"
patch --forward -F0 -p1 -d "$dms_dir" <"${script_dir}/dms-lockscreen.patch"
