# Pull the latest build of the fromelicks custom image (day-to-day update)
#
# Uses bootc, NOT rpm-ostree. Only bootc reads /usr/lib/bootc/kargs.d/, so an
# rpm-ostree deployment silently drops every kernel argument the recipe declares
# -- and because bootc applies kargs.d as a delta against the booted deployment,
# a karg first shipped under an rpm-ostree deployment is then unreachable forever.
# See docs/kernel-arguments.md.
#
# `run0 -i` is deliberate: /usr/bin/bootc is labelled install_exec_t and run0's
# transient unit cannot exec it directly (SELinux denies entrypoint), so the
# command has to be resolved through a shell. Do not pass an absolute path here.
[group('Custom')]
update-fromelicks:
    #!/usr/bin/env bash
    set -euo pipefail
    REF="ghcr.io/fromelicks/secureblue-nvidia-open-hardened:latest"
    TARGET="ostree-image-signed:docker://${REF}"
    CURRENT=$(rpm-ostree status --json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['deployments'][0].get('container-image-reference',''))" \
        2>/dev/null || true)
    if [[ "$CURRENT" == "$TARGET" ]]; then
        run0 -i bootc upgrade
    else
        run0 -i bootc switch --enforce-container-sigpolicy "$REF"
    fi
