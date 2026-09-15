# ── Font discovery ─────────────────────────────────────────────────────────
# fontconfig ignores case and spaces when matching names, so `fc-match` happily
# resolves a misspelled family ("0xProto NerdFont Mono"). Chromium/Electron apps
# (VSCode) do not: they silently fall back to another font. Copy names from
# these recipes, and confirm with `fonts-check`.

# List every font family fontconfig can see (primary names only).
[group('Fonts')]
fonts-list-all:
    fc-list --format '%{family[0]}\n' | sort -u

# List font families installed under $HOME (e.g. chezmoi's ~/.local/share/fonts).
[group('Fonts')]
fonts-list-local:
    #!/usr/bin/env bash
    set -euo pipefail
    # fontconfig may report either /home or /var/home; accept both spellings.
    fc-list --format '%{file}\t%{family[0]}\n' \
        | awk -F '\t' -v a="$HOME/" -v b="$(realpath "$HOME")/" \
            'index($1, a) == 1 || index($1, b) == 1 { print $2 }' \
        | sort -u

# Show family, style and file of fonts whose family contains <query> (case-insensitive).
[group('Fonts')]
fonts-find query:
    #!/usr/bin/env bash
    set -euo pipefail
    QUERY={{ quote(query) }}
    fc-list --format '%{family[0]}\t%{style[0]}\t%{file}\n' \
        | awk -F '\t' -v q="${QUERY,,}" 'index(tolower($1), q) { print; n++ } END { exit !n }' \
        | sort -t $'\t' -k1,1 -k2,2 \
        | awk -F '\t' '{ printf "%-32s %-16s %s\n", $1, $2, $3 }' \
        || { printf 'No font family contains: %s\n' "$QUERY" >&2; exit 1; }

# Check <family> is an exact name, as VSCode needs; on a miss, suggest case/spacing variants.
[group('Fonts')]
fonts-check family:
    #!/usr/bin/env bash
    set -euo pipefail
    FAMILY={{ quote(family) }}
    NAMES="$(fc-list --format '%{family}\n' | tr ',' '\n' | sort -u)"
    if grep -Fxq -- "$FAMILY" <<<"$NAMES"; then
        printf 'OK: "%s" is an installed family.\n' "$FAMILY"
        exit 0
    fi
    printf 'NOT FOUND: "%s" is not an exact family name.\n' "$FAMILY" >&2
    awk -v t="$FAMILY" '
        function norm(s) { gsub(/[[:space:]]/, "", s); return tolower(s) }
        BEGIN { t = norm(t) }
        norm($0) == t { printf "  did you mean: \"%s\"\n", $0 }
    ' <<<"$NAMES" >&2
    exit 1
