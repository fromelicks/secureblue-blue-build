#!/usr/bin/env bash
set -euo pipefail

# Two lock-screen defects in DMS 1.5.3's Modules/Lock/LockScreenContent.qml:
#
#   1. Enter (or the enter button) on an empty password field starts a PAM
#      attempt. It cannot succeed, and it spends the faillock budget, so a stray
#      Enter moves the session towards a real lockout for nothing. Guarded by a
#      new canSubmitPassword(), which still allows an empty submit when the PAM
#      stack is not DMS's own (lockPamExternallyManaged or a custom lockPamPath)
#      -- there the conversation itself may prompt for an inline u2f/fingerprint
#      touch and Enter is how the user starts it.
#      Still present on upstream master as of 2026-09-01.
#
#   2. Ctrl+Backspace is not handled in the Ctrl branch of the key handler, so
#      it falls through to the plain Backspace case and deletes one character
#      instead of the previous word. Ctrl+W already does the word delete.
#      ALREADY FIXED UPSTREAM in 262acda3 ("fix(lock): handle ctrl-backspace",
#      2026-08-18, issue #3087), which is after the v1.5.3 tag. DROP THIS HUNK
#      when the image picks up a DMS newer than 1.5.3 -- the build will fail
#      loudly and point here.
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
