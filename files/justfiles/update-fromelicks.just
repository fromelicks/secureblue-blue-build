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

# Show which packages the next update changes, without downloading it
#
# The rough equivalent of `rpm-ostree db diff` for an update that has not been
# pulled yet. The image is chunked by chunkah, which puts the RPM database in a
# layer of its own (~45 MB), so fetching that one blob and diffing it against
# the booted database costs a fraction of the ~3 GB pull. Both sides use
# rpm-ostree-base-db, so locally layered packages do not show up as removals.
# Read-only, needs no root. Pass a ref to diff against another image.
[group('Custom')]
update-diff ref="":
    #!/usr/bin/env bash
    set -euo pipefail
    STATUS=$(rpm-ostree status --json)
    BOOTED_REF=$(jq -r '.deployments[] | select(.booted) | ."container-image-reference" // ""' <<<"$STATUS")
    BOOTED_DIGEST=$(jq -r '.deployments[] | select(.booted) | ."container-image-reference-digest" // ""' <<<"$STATUS")
    STAGED_DIGEST=$(jq -r '.deployments[] | select(.staged) | ."container-image-reference-digest" // ""' <<<"$STATUS")
    REF="{{ ref }}"
    [[ -n "$REF" ]] || REF=${BOOTED_REF##*docker://}
    [[ -n "$REF" ]] || { echo "The booted deployment does not track a container image; pass a ref." >&2; exit 1; }
    REPO_REF=${REF%%@*}                                        # drop a digest
    [[ "${REPO_REF##*/}" != *:* ]] || REPO_REF=${REPO_REF%:*}  # drop a tag, not a registry port
    REGISTRY=${REPO_REF%%/*}
    REPO=${REPO_REF#*/}
    case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; *) ARCH=$(uname -m) ;; esac

    TOP=$(skopeo inspect --raw "docker://$REF")
    if jq -e '.manifests' >/dev/null <<<"$TOP"; then
        DIGEST=$(jq -r --arg a "$ARCH" '.manifests[] | select(.platform.architecture == $a) | .digest' <<<"$TOP" | head -n1)
        MANIFEST=$(skopeo inspect --raw "docker://$REPO_REF@$DIGEST")
    else
        DIGEST=$(skopeo inspect --format '{{ "{{" }} .Digest {{ "}}" }}' "docker://$REF")
        MANIFEST=$TOP
    fi
    VERSION=$(skopeo inspect --config "docker://$REPO_REF@$DIGEST" | jq -r '.config.Labels["org.opencontainers.image.version"] // "unknown"')
    echo "Booted:   $(jq -r '.deployments[] | select(.booted) | .version // "unknown"' <<<"$STATUS")  ${BOOTED_DIGEST:0:19}"
    echo "Incoming: $VERSION  ${DIGEST:0:19}  ($REF)"
    if [[ "$DIGEST" == "$BOOTED_DIGEST" ]]; then
        echo "Up to date: the booted deployment already is this image."
        exit 0
    fi
    [[ "$DIGEST" != "$STAGED_DIGEST" ]] || echo "Note: this image is already staged; it applies on the next reboot."

    # Estimated pull size: layers the booted image does not already have. Needs
    # the booted manifest from the registry; skipped if it has been pruned.
    if [[ -n "$BOOTED_DIGEST" ]] && OLD=$(skopeo inspect --raw "docker://$REPO_REF@$BOOTED_DIGEST" 2>/dev/null); then
        jq -r --argjson old "$OLD" '
            ([$old.layers[].digest]) as $have
            | ([.layers[] | select(.digest as $d | $have | index($d) | not)]) as $new
            | "Download: \($new | length) of \(.layers | length) layers changed, ~\(($new | map(.size) | add // 0) / 1e6 | floor) MB"' <<<"$MANIFEST"
    fi

    LAYER=$(jq -c '[.layers[] | select(.annotations["org.chunkah.component"] // "" | split(" ") | index("bigfiles/rpmdb.sqlite"))][0] // empty' <<<"$MANIFEST")
    if [[ -z "$LAYER" ]]; then
        echo "No layer is annotated as holding the RPM database (image not chunked by chunkah?)." >&2
        exit 1
    fi
    BLOB=$(jq -r .digest <<<"$LAYER")
    echo "Fetching the RPM database layer ($(( $(jq -r .size <<<"$LAYER") / 1000000 )) MB)..."

    # skopeo cannot fetch a single blob, so talk to the registry API directly,
    # using whatever token service its WWW-Authenticate challenge names (GET,
    # not HEAD: ghcr.io answers HEAD /v2/ with a bare 405 and no challenge).
    AUTH=()
    CHALLENGE=$(curl -s -o /dev/null -D - "https://$REGISTRY/v2/" | tr -d '\r' | grep -i '^www-authenticate: *bearer' || true)
    if [[ -n "$CHALLENGE" ]]; then
        REALM=$(sed -n 's/.*realm="\([^"]*\)".*/\1/p' <<<"$CHALLENGE")
        SERVICE=$(sed -n 's/.*service="\([^"]*\)".*/\1/p' <<<"$CHALLENGE")
        TOKEN=$(curl -fsSG "$REALM" --data-urlencode "service=$SERVICE" --data-urlencode "scope=repository:$REPO:pull" | jq -r '.token // .access_token')
        AUTH=(-H "Authorization: Bearer $TOKEN")
    fi
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    curl -fsSL "${AUTH[@]}" -o "$TMP/layer" "https://$REGISTRY/v2/$REPO/blobs/$BLOB"
    [[ "sha256:$(sha256sum "$TMP/layer" | cut -d' ' -f1)" == "$BLOB" ]] || { echo "Layer digest mismatch; refusing to read it." >&2; exit 1; }
    mkdir "$TMP/root"
    tar -xf "$TMP/layer" -C "$TMP/root"   # tar detects the compression itself
    NEWDB=$TMP/root/usr/lib/sysimage/rpm-ostree-base-db
    [[ -f "$NEWDB/rpmdb.sqlite" ]] || NEWDB=$TMP/root/usr/share/rpm
    OLDDB=/usr/lib/sysimage/rpm-ostree-base-db
    [[ -f "$OLDDB/rpmdb.sqlite" ]] || OLDDB=/usr/share/rpm

    QF='%{NAME}\t%{EPOCHNUM}:%{VERSION}-%{RELEASE}\n'
    rpm -qa --dbpath "$OLDDB" --qf "$QF" | sort > "$TMP/old"
    rpm -qa --dbpath "$NEWDB" --qf "$QF" | sort > "$TMP/new"
    # One line per changed name; multi-instance packages (gpg-pubkey, kernel)
    # compare as whole sets, so a reordering never reads as a change.
    awk -F'\t' '
        FNR == NR { old[$1] = old[$1] (old[$1] == "" ? "" : ", ") $2; next }
                  { new[$1] = new[$1] (new[$1] == "" ? "" : ", ") $2 }
        END {
            for (n in old) if (!(n in new)) printf "removed\t%s\t%s\t\n", n, old[n]
            for (n in new) if (!(n in old)) printf "added\t%s\t\t%s\n", n, new[n]
                           else if (old[n] != new[n]) printf "changed\t%s\t%s\t%s\n", n, old[n], new[n]
        }' "$TMP/old" "$TMP/new" | sed 's/\t0:/\t/g' | sort -t$'\t' -k1,1r -k2,2 > "$TMP/diff"
    echo ""
    if [[ ! -s "$TMP/diff" ]]; then
        echo "No package changes (the update only changes non-RPM content)."
        exit 0
    fi
    for kind in changed added removed; do
        n=$(grep -c "^$kind"$'\t' "$TMP/diff" || true)
        [[ "$n" -gt 0 ]] || continue
        echo "${kind^} ($n):"
        grep "^$kind"$'\t' "$TMP/diff" | cut -f2- | awk -F'\t' '{ printf "  %-44s %s%s%s\n", $1, $2, ($2 != "" && $3 != "" ? "  ->  " : ""), $3 }'
        echo ""
    done
