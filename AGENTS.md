# AGENTS.md — fromelicks/secureblue custom image

Context for continuing work on this custom BlueBuild image. Read this fully before acting.

## Project goal

A personal, hardened, **declarative** Fedora-Atomic workstation image built **on top of**
secureblue — not a fork. Inherit secureblue's daily hardening updates by using its published
image as the base; keep this repo a thin, auditable layer.

- **Base image:** `ghcr.io/secureblue/silverblue-nvidia-open-hardened`
- **Published as:** `ghcr.io/fromelicks/secureblue-nvidia-open-hardened:latest` (cosign-signed)
- **Hardware target:** Lenovo Legion 5 16IRX9 — i7-14650HX, **hybrid graphics** (Intel iGPU +
  NVIDIA RTX 4060, nvidia-open), 32 GB RAM. Dual-boots with BitLocker Windows on a *separate* SSD
  (independent bootloaders via UEFI boot order — no GRUB chainloading).
- **FDE:** LUKS2, passphrase now; TPM2 keyslot (sealed to PCR 7) added via
  `systemd-cryptenroll`, passphrase retained as fallback.

## Design principles (apply to every change)

1. **Three buckets.** Decide where each thing lives:
   - **Image (declarative):** packages, binaries, systemd *unit definitions*, dconf defaults,
     firewall rules, container-policy entries, system GNOME extensions, distrobox *manifests*.
   - **Runtime (per-machine):** secrets, distrobox *instances*, NetBird login, mount credentials,
     Syncthing/KeePassXC device state, SELinux userns toggle.
   - **User layer:** dotfiles, per-user service enablement, flatpak *user* overrides.
2. **Secrets never baked.** Use **systemd-creds (TPM-sealed)** for host-local secrets (NetBird
   setup key, JuiceFS/rclone creds, KeePassXC key file). Use **sops-age or Ansible Vault** for
   fleet-distributed secrets. Image layers are extractable even from a private registry.
3. **Drift control, not impermanence.** Goal is to *see and control* drift, not wipe root.
   `/usr` is immutable+verified; `/etc` is auditable via `ostree admin config-diff`; `/var` is
   mutable by design. Keep local `rpm-ostree` layering at **zero** — everything goes in the recipe.
4. **Capture-and-commit pattern.** For config that a `ujust` recipe would generate: run the recipe
   once, `ostree admin config-diff` to see exactly which files changed, commit those files to
   `files/system/<path>`, then revert the `/etc` change so config-diff stays clean.

## Repo layout

- `recipes/recipe.yml` — base-image + module list
- `files/system/*` → copied to `/` by the `files` module
- `files/scripts/` — scripts invoked by `script` modules
- `modules/` — custom modules
- `.github/workflows/build.yml` — **daily cron 06:00 UTC** (+push, +workflow_dispatch) already
  pulls the latest secureblue base. Requires repo secret `SIGNING_SECRET` to match `cosign.pub`.
- `cosign.pub` — signing pubkey (also baked into the image policy by the `signing` module)

## Cross-cutting secureblue constraints (MUST be handled)

These gate multiple features. Verified against secureblue source.

1. **Container signature policy is default-reject.** `/etc/containers/policy.json` rejects any
   docker-transport image not explicitly listed. Already-trusted namespaces include
   `ghcr.io/secureblue`, `ghcr.io/ublue-os`, `ghcr.io/blue-build/*`, `quay.io/toolbx-images`,
   `quay.io/fedora-ostree-desktops`. To pull dev/other images, add policy entries. **DECISION
   NEEDED:** which registries to trust and how (e.g. `insecureAcceptAnything` for `docker.io`
   vs. signed entries). Bake as a policy overlay scoped to only what's needed.
2. **firewalld is all-closed.** Open specific ports: Syncthing `22000/tcp+udp`, `21027/udp`;
   GSConnect/KDEConnect `1714-1764/tcp+udp`. Each is a conscious hole; bake via `files`.
3. **GNOME extensions:** `allow-extension-installation=false`, `enabled-extensions=[]`. **System**
   extensions in `/usr/share/gnome-shell/extensions` ARE trusted and load. Enable them with a
   `gschema-overrides` file that sorts AFTER `zz1-secureblue` (name it `zz2-`/`zzz-fromelicks`).
   Leave `allow-extension-installation=false` untouched.
4. **Container-domain userns is DISABLED by default** via SELinux CIL module
   `harden_container_userns`. distrobox and rootless Podman need `ujust set-container-userns on`
   (removes the module). **DECISION NEEDED:** first-boot oneshot that performs this automatically,
   vs. manual per-machine toggle. (`set-unconfined-userns` is a separate, unrelated toggle.)
5. **fuse2 removed.** Use fuse3 (JuiceFS/rclone are fine).
6. **KVM modules may be blacklisted.** Verify `kvm-intel` is loadable for Firecracker; un-blacklist
   via a `files/system/usr/lib/modprobe.d/` drop-in if blocked.
7. **Xwayland is off.** Toggle on for Steam/gaming (`ujust set-xwayland on`, needs relogin).
   Electron apps (VSCode) need `--ozone-platform-hint=auto` for native Wayland.
8. **hardened_malloc is globally preloaded.** Some apps (Steam) require it disabled per-app.
9. Trivalent defaults WebRTC to disable_non_proxied_udp — breaks browser-based real-time voice/video (Discord, Meet, Jitsi); relax per-need or use a dedicated client.

## Feature implementation plan

| Feature | Where | How | Notes / gotchas |
|---|---|---|---|
| `registries.d` + key | image | likely already baked by `signing` module — verify `/usr/share/pki/containers/` and `/usr/etc/containers/registries.d/` first; only add via `files` if pulling other images from the namespace | probably redundant |
| **NetBird** | image | `dnf` module + NetBird's own repo (`pkgs.netbird.io/yum/netbird.repo`); `systemd` enable; auth key via systemd-creds at runtime | `ujust install-vpn` does NOT support NetBird (only ivpn/mullvad/proton/tailscale, and it layers = drift). Switch DNS to systemd-resolved when bringing NetBird up. |
| **Container runtime** | image (built-in) | use **Podman** (already present); enable Podman docker-compat socket if Docker API needed | Do NOT install Docker — root daemon + `docker` group is a root-equivalent hole secureblue's audit flags. `ujust install-docker` layers it = drift. |
| **Firecracker** | image | `script` module fetches binary | needs `/dev/kvm` → see constraint 6 |
| **gVisor (runsc)** | image | `script` module (NOT in secureblue at all) | collides with userns (constraint 4) + ptrace hardening + needs kvm/seccomp exceptions. Reconsider value on top of existing SELinux+userns hardening. |
| **JuiceFS** | image (binary) + runtime (mount) | `script` fetches binary; mount via systemd unit; creds via systemd-creds | fuse3 |
| **rclone** | image (binary) + runtime (mount) | `dnf install rclone`; mount via systemd unit; `rclone.conf` is a secret → systemd-creds/user layer | fuse3 |
| **distrobox + VSCode** | manifest in image, instance at runtime | distrobox likely present (else `dnf`); ship a `distrobox assemble` manifest in `files/system/etc/distrobox/`; install editor INSIDE the box and `distrobox-export` it | **DECISION NEEDED: VSCode vs VSCodium.** Box needs `set-container-userns on` (constraint 4). |
| **Steam** | run `ujust install-steam` once (recommended) | the helper does hardened_malloc opt-out + a specific flatpak permission set + ia32 karg removal + ptrace/anticheat + Xwayland — the flatpak alone is insufficient | If fully declarative is wanted, bake `com.valvesoftware.Steam` via `default-flatpaks` AND replicate the overrides as a first-boot/user step. |
| **Syncthing** | image + user service | `dnf install syncthing`; enable as *user* systemd service; open firewall (constraint 2) | device keys are per-machine runtime state |
| **KeePassXC** | image | `dnf install keepassxc` (better integration than flatpak); key-file unlock, optionally TPM-seal the key file via systemd-creds | **DECISION NEEDED:** auto-unlock convenience vs. "unlocked session = vault exposed" tradeoff. No native TPM-unlock; it's a small systemd-creds wrapper. |
| **PaperWM** | image | `gnome-extensions` BlueBuild module (installs system-wide to `/usr/share/...`) + `gschema-overrides` to add UUID to `enabled-extensions` (sort after `zz1-`) | watch the documented "extension-only gschemas.compiled location" quirk |
| **GSConnect / KDEConnect** | image | use Fedora `dnf` package `gnome-shell-extension-gsconnect` (NOT the gnome-extensions module — the EGO build is hard-coded to user paths and fails system-wide); enable via gschema-override; open firewall 1714-1764 | |

## Open decisions (confirm with the user before implementing)

1. **VSCode vs VSCodium** for the distrobox dev environment.
2. **Container policy:** which registries to trust, and `insecureAcceptAnything` vs. signed entries.
3. **Container-userns:** bake a first-boot oneshot, or leave as a manual per-machine toggle.
4. **KeePassXC quick-unlock:** is the auto-unlock security tradeoff acceptable?

## Scope of what can be done here vs. locally

- **Claude Code (cloud) CAN:** author `files/`, `script`s, `gschema-overrides`, `dnf`/`systemd`/
  `default-flatpaks`/`gnome-extensions` modules; validate with `bluebuild build` / GitHub Actions;
  lint and structure the repo.
- **Claude Code (cloud) CANNOT:** test hardware-dependent behavior — NVIDIA hybrid graphics, TPM
  sealing, Secure Boot, boot/rebase. Do NOT place real secrets in the repo or cloud env.
- **Local verification loop (user, on the Legion):** build → push → `rpm-ostree rebase
  ostree-image-signed:docker://ghcr.io/fromelicks/secureblue-nvidia-open-hardened:latest` → reboot
  → `rpm-ostree status` / `bootc status` → `ostree admin config-diff` (should be clean) →
  `ujust audit-secureblue`.

## Suggested implementation order

Blockers first (they gate the rest): container-policy overlay, firewall rules, KVM-module check,
the system-extension + gschema-override mechanism, container-userns approach. Then features:
NetBird + Podman → distrobox manifest + editor → Syncthing/KeePassXC → PaperWM/GSConnect → Steam →
Firecracker (gVisor last / optional).
