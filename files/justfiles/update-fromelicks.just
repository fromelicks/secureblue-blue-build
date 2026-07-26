# Pull the latest build of the fromelicks custom image (day-to-day update)
[group('Custom')]
update-fromelicks:
    #!/usr/bin/env bash
    set -euo pipefail
    TARGET="ostree-image-signed:docker://ghcr.io/fromelicks/secureblue-nvidia-open-hardened:latest"
    CURRENT=$(rpm-ostree status --json \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['deployments'][0].get('container-image-reference',''))" \
        2>/dev/null || true)
    if [[ "$CURRENT" == "$TARGET" ]]; then
        rpm-ostree upgrade
    else
        rpm-ostree rebase "$TARGET"
    fi
    echo ""
