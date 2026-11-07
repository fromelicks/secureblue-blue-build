# PaperWM

PaperWM is installed system-wide by `files/scripts/install-paperwm.sh` from a
pinned upstream commit. It is enabled by
`files/gschema-overrides/zz9-enabled-extensions.gschema.override`.

## Why not the `gnome-extensions` module

The BlueBuild `gnome-extensions` module installs only what
extensions.gnome.org (EGO) has approved. It reads `shell_version_map` from
`https://extensions.gnome.org/extension-info/?pk=6099` and fails the build if
the image's GNOME major has no entry. It never looks at GitHub.

When the secureblue base moved to GNOME 51 (first failing build:
2026-11-06, issue #64), EGO had no approved PaperWM build for 51:

| EGO version | `version-name` | Uploaded | Status |
|---|---|---|---|
| 148 | 50.0.1 | 2026-04-21 | Active (shells 45–50) |
| 150 | 51.0.0 | 2026-10-12 | Inactive |
| 151 | 51.0.0 | 2026-10-13 | **Rejected** |

The statuses come from
`https://extensions.gnome.org/api/v1/extensions/paperwm@paperwm.github.com/versions/`.
EGO's `STATUS_*` constants are `range(5)` (unreviewed, rejected, inactive,
active, waiting), so `1` means rejected. Only the author can see the reviewer's
reason.

The upstream `v51.0.0` tag does support GNOME 51: its `metadata.json` lists
45–51, and it contains the port, commit `9c31b82` ("Support GNOME 51",
PaperWM #1189). The tag was moved after it was first published. Some early
reports, such as the comment on PaperWM #1201 that the release lacks the port,
were made against the older target.

## How the installer works

- It downloads `https://github.com/paperwm/PaperWM/archive/<rev>.tar.gz` and
  checks it against a pinned SHA256. The commit is pinned, not the tag,
  because tags move.
- It fails the build if the image's `gnome-shell --version` major is not in
  `metadata.json`'s `shell-version`. GNOME Shell would otherwise refuse the
  extension at login without a visible error.
- It installs the same file set as PaperWM's `make release`: `*.js`, `*.ui`,
  `config/`, `resources/`, `metadata.json`, `stylesheet.css` and `LICENSE`.
- It compiles the schema into the extension's **own** `schemas/` directory.
  PaperWM opens `gschemas.compiled` from there, which is the same quirk the
  module special-cased.

## Updating

1. Pick a release commit:
   `gh api repos/paperwm/PaperWM/git/ref/tags/<tag> --jq .object.sha`.
2. Hash it:
   `curl -fsSL https://github.com/paperwm/PaperWM/archive/<sha>.tar.gz | sha256sum`.
3. Update `rev` and `sha256` together in `install-paperwm.sh`.

A failed build saying "does not support GNOME N" means the base moved to a new
GNOME before PaperWM declared support for it.

GitHub's generated archives have changed byte-for-byte once before (2023,
later reverted). A checksum mismatch on an unchanged `rev` is most likely
that, not tampering. Confirm with `git clone` + `git checkout <rev>` before
re-pinning.

## Known GNOME 51 issues upstream

- PaperWM #1198: mouse hover fails after switching desktops.
- PaperWM #1192: fails to load with multiple screens. It was reported before
  the 51 port, with only the version string patched, so it may already be
  fixed. Check it with the external HDMI display connected.
