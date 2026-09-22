# ── MicroVMs (libkrun) ─────────────────────────────────────────────────────

# `podman run --runtime krun ...` boots the container in its own KVM microVM
# with the libkrunfw guest kernel. Networking is TSI (socket impersonation), so
# no tap device, forwarding or firewalld zone is involved. See docs/microvms.md.
# Verify that containers really boot in their own kernel under krun.
[group('MicroVM')]
krun-check:
    #!/usr/bin/env bash
    set -uo pipefail
    IMAGE="registry.access.redhat.com/ubi9/ubi:latest"
    fail=0
    echo "--- prerequisites ---"
    if [ -x /usr/bin/krun ]; then echo "krun runtime: /usr/bin/krun"; else echo "krun runtime: MISSING (crun-krun not in this image?)"; fail=1; fi
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then echo "/dev/kvm: read+write"; else echo "/dev/kvm: NOT accessible"; fail=1; fi
    echo "container userns: $(ujust set-container-userns status 2>/dev/null | tail -1)"
    [ "$fail" -eq 0 ] || exit 1
    echo ""
    echo "--- boot test ($IMAGE) ---"
    host=$(uname -r)
    guest=$(podman run --rm --runtime krun "$IMAGE" uname -r) || { echo "krun container failed to start"; exit 1; }
    echo "host kernel:  $host"
    echo "guest kernel: $guest"
    if [ "$guest" = "$host" ]; then
        echo "FAIL: guest reports the host kernel -- this is not running in a microVM"
        exit 1
    fi
    echo "OK: the container ran in its own kernel"

# All arguments go to /usr/bin/krun-box unchanged; run `krun-box -h` for usage.
# Open a persistent dev shell (Julia/opencode) in a krun microVM.
[group('MicroVM')]
[positional-arguments]
krun-box *args:
    #!/usr/bin/env bash
    exec krun-box "$@"
