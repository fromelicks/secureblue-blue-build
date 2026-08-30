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

## Hardware-specific notes and known issues

Documented findings for this machine's quirks. Read the linked doc before
touching the relevant subsystem.

| Area | Doc | Summary |
|---|---|---|
| WiFi + S2Idle suspend | [`docs/wifi-s2idle-suspend.md`](docs/wifi-s2idle-suspend.md) | Intel CNVi 9560 enters D3cold on S2Idle resume → firmware NMI → device stuck in reset across warm reboots. Fix: udev rule + sleep hook setting `d3cold_allowed=0`. S2Idle vs S3 tradeoff documented there. |
| Intermittent speaker xruns | [`docs/hda-pipewire-xruns.md`](docs/hda-pipewire-xruns.md) | One boot produced quiet, noisy, choppy ALC257 speaker output in both Niri and GNOME. PipeWire timer scheduling repeatedly drained the ALSA buffer; IRQ scheduling was clean, and reboot restored the default timer path. No workaround is enabled; the doc contains capture steps and a scoped WirePlumber fallback. |
| Desktop freezes under load | [`docs/desktop-responsiveness.md`](docs/desktop-responsiveness.md) | The hardening kargs make `fork`+`exec` ~3.3 ms (vs 0.5–1 ms stock), so fork-heavy apps starve the compositor. Fix: `session.slice` ≫ `app.slice` CPU/IO weights, `io.cost` to make `IOWeight` work on NVMe, and a starvation classifier so the hang monitor stops mistaking overload for a wedged shell. |
| GNOME hang detection | [`docs/gnome-hang-monitor.md`](docs/gnome-hang-monitor.md) | Continuous `org.gnome.Shell.Eval` probe with detached, bounded diagnostics and automatic session recovery. |
| Spontaneous instant reboots | [`docs/crash-capture.md`](docs/crash-capture.md) | secureblue's `kernel.panic=-1` reboots in zero seconds, EFI pstore is off, ramoops was unconfigured and this firmware has no BERT — so a panic left *no* evidence anywhere. Fix: `kernel.panic=30` override plus ramoops on a `reserve_mem=` named region. |
| Recipe kargs never reaching the cmdline | [`docs/kernel-arguments.md`](docs/kernel-arguments.md) | `kargs.d` is a **bootc-only** interface that rpm-ostree ignores silently, and bootc applies it as a *delta*, not desired state — so a karg first shipped under an rpm-ostree deployment is unreachable forever. Repair with `bootc loader-entries set-options-for-source`. Includes the `run0` quoting and SELinux gotchas. |

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
10. **secureblue's `kernel.panic=-1` makes crashes undiagnosable by default.**
    `/usr/lib/sysctl.d/55-hardening.conf` reboots with *zero* delay on panic, so on a KMS
    console a panic is a colour flash and nothing else. Combined with
    `efi_pstore.pstore_disable=Y` (Fedora default), no ramoops region, and no `BERT`/`HEST`
    tables on this firmware, every crash-capture path was closed — a real reboot on
    2026-08-26 left no evidence at all. Overridden to `kernel.panic=30` in
    `files/rootfs/etc/sysctl.d/99-fromelicks-panic-visibility.conf` — which wins on the
    `99-` prefix, NOT on the directory: `sysctl.d(5)` sorts all files across `/etc`,
    `/run` and `/usr/lib` by basename and takes the last, and `/etc` only overrides
    `/usr/lib` for a file of the *same name*. Never renumber it below `55-`. Plus ramoops
    on a `reserve_mem=` named region. Do NOT set `panic_on_oops=1` to "improve" this —
    secureblue deliberately pairs `panic_on_oops=0` with `oops_limit=100`, and flipping it
    converts survivable oopses into reboots.
    **Expected consequence:** `ujust audit-secureblue` will now permanently fail its
    "Ensuring no sysctl overrides" check with `kernel.panic should be -1, but is actually
    30`. `audit_secureblue.py:audit_sysctl()` diffs every key of `55-hardening.conf`
    against `/proc/sys`, and `audit_utils.validate_sysctl` has no special case for
    `kernel.panic`, so it falls through to exact equality. That one line is the accepted
    trade; any *other* sysctl finding in that check is real and must be investigated.
    See [`docs/crash-capture.md`](docs/crash-capture.md).
11. **`systemd.user.enabled` in the recipe enables units GLOBALLY**, via
    `/etc/systemd/user/default.target.wants/`. GDM's greeter runs a full systemd user
    manager (`user@60578.service`, user `gdm-greeter` — a dynamic user, see
    `/var/lib/gdm/.migrated-dyn-users`), so every globally enabled user unit **also starts
    in the greeter, before login**. This silently broke Syncthing: the greeter instance
    generated its own device ID and held ports 22000/8384, so the real session could never
    bind. Any user unit that binds a port, touches shared state, or should be per-login
    needs a guard. `ConditionUser=!@system` is NOT enough (gdm-greeter's UID is 60578); use
    the pair ublue uses on `user-flatpak-setup.service`:
    `ConditionUser=!@system` + `ConditionPathIsDirectory=/var/home/%u`.
    Applied in `files/rootfs/usr/lib/systemd/user/syncthing.service.d/10-skip-greeter.conf`.
12. **The `linuxbrew` account is deliberately unusable via PAM.** `sysusers.d` creates it
    with the `u!` (locked) modifier, which sets a locked password *and* an expiry date of
    1970-01-02. Anything that opens a PAM session as `linuxbrew` — `run0 -u linuxbrew`
    (as brew-proxy's README suggests), `su`, `login` — fails with
    `PAM failed: User account has expired`. This is by design. The supported paths bypass
    PAM: the `/usr/bin/brew` shim → `brew-proxy` DBus service, and the
    `brew-update`/`brew-upgrade` units via `User=linuxbrew`. Use `ujust brew-shell`
    (systemd-run, no PAM) if a real linuxbrew shell is ever needed; `ujust check-brew`
    reports the state.
13. **Recipe `kargs` only apply if the deployment is created by `bootc`, and only as a
    *delta*.** BlueBuild's `kargs` module writes `/usr/lib/bootc/kargs.d/bluebuild-kargs.toml`.
    That path is read by `bootc` alone — `rpm-ostree`, `librpmostree` and `libostree` contain
    zero references to it — so `rpm-ostree rebase|upgrade` and `rpm-ostreed-automatic.service`
    ignore every karg in the recipe, silently. Worse, `bootc` does not treat `kargs.d` as
    desired state: `bootc_kargs.rs` diffs the **booted** deployment's `kargs.d` against the
    **incoming** image's and applies only `added=`/`removed=`. So a karg first shipped in a
    deployment that rpm-ostree created never lands in the BLS, and from then on both sides of
    every diff contain it — the delta is empty **forever** and no `bootc upgrade` will ever
    fix it. This is what kept the ramoops kargs off `/proc/cmdline` for days. Update with
    `bootc upgrade`, prefer `bootc-fetch-apply-updates.timer` over
    `rpm-ostreed-automatic.timer` (note the bootc unit uses `--apply`, i.e. it **reboots**),
    and always verify a new karg on `/proc/cmdline` after the reboot — the failure is silent.
    Repair a stuck one with `bootc loader-entries set-options-for-source`.
    **The Legion carries this drift right now:** its BLS entry has
    `x-options-source-fromelicks` pinning `reserve_mem=2M:4096:oops`,
    `ramoops.mem_name=oops` and `ramoops.ecc=1` independently of the recipe. Deleting
    those from `recipes/recipe.yml` will NOT take them off `/proc/cmdline` — the tracked
    source has to be dropped by hand with the same command and no `--options`. Check with
    `grep x-options-source /boot/loader/entries/*.conf`.
    See [`docs/kernel-arguments.md`](docs/kernel-arguments.md).

## Feature implementation plan

| Feature | Where | How | Notes / gotchas |
|---|---|---|---|
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
- **Local verification loop (user, on the Legion):** build → push → `run0 bootc upgrade` →
  reboot → `bootc status` → `ostree admin config-diff` (should be clean) →
  `ujust audit-secureblue`. Use `bootc`, **not** `rpm-ostree rebase|upgrade`: only `bootc`
  reads `/usr/lib/bootc/kargs.d/`, so an rpm-ostree deployment drops every karg the recipe
  declares without saying so (constraint 13). If the recipe changed a karg, also check
  `/proc/cmdline` after the reboot.
  `bootc upgrade` only refreshes the ref the deployment already points at. To install onto
  a fresh machine, or to change which image is tracked, the equivalent of the old
  `rpm-ostree rebase` is
  `run0 bootc switch --enforce-container-sigpolicy ghcr.io/fromelicks/secureblue-nvidia-open-hardened:latest`
  — the flag is **not** the default, and without it the origin is rewritten from
  `ostree-image-signed:` to `ostree-unverified-image:`, silently dropping cosign
  verification on that update and every one after.

## Suggested implementation order

Blockers first (they gate the rest): container-policy overlay, firewall rules, KVM-module check,
the system-extension + gschema-override mechanism, container-userns approach. Then features:
NetBird + Podman → distrobox manifest + editor → Syncthing/KeePassXC → PaperWM/GSConnect → Steam →
Firecracker (gVisor last / optional).
