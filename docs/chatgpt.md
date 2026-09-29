# ChatGPT desktop app

The image installs OpenAI's official `chatgpt` RPM from its signed repository.
The daily image rebuild picks up the latest package; updates reach the host
through `bootc upgrade` and a reboot. No local RPM layering is needed.
Sign-in and app state remain in the user account.

## Package and trust

`files/dnf/chatgpt.repo` enables both package and repository-metadata signature
verification. The key is shipped under `files/rootfs/etc/pki/rpm-gpg/` before
the dnf module runs. Its fingerprint is
`3BFA0E4AE8B8CC16A2D9BA684A3B4A566C4660E4`.

The key and repository configuration were checked against the official RPM
linked by the [Linux installation guide](https://learn.chatgpt.com/docs/linux/linux-app)
and the [reference integration PR](https://github.com/superkisa/bazzite-gnome-nvidia-open/pull/14).
Both the RPM and repository metadata signatures verified locally.
Key rotation requires reviewing and updating the pinned key and repo together.

The inspected package, `26.924.51851-1.x86_64`, installs the application into
`/usr/lib/chatgpt`, with `/usr/bin/chatgpt` pointing to `codex-launcher` there.
No `/opt` relocation is necessary. The RPM owns the desktop entry, its
`codex://` handler and `/usr/share/pixmaps/chatgpt.png` icon. The icon is outside
the hicolor cache. The integration script refreshes and checks the desktop
MIME cache explicitly, since ostree's zero mtimes hide stale caches.

## Native Wayland and allocator

After dnf, `files/scripts/chatgpt-integration.sh` replaces `codex-launcher` with:

```sh
exec /usr/bin/with-standard-malloc /usr/lib/chatgpt/ChatGPT --ozone-platform=wayland "$@"
```

Both the terminal command and the desktop entry use this launcher. Build
checks fail if the package layout or desktop commands change unexpectedly.
An explicit command-line flag can override the default for troubleshooting.

The Wayland flag follows OpenAI's documented native Wayland invocation. The
upstream default prefers XWayland when available; this image explicitly
selects Wayland and does not enable XWayland for ChatGPT. Native Wayland is
experimental upstream: floating windows, positioning, focus and keyboard
shortcuts may have limitations.

The standard allocator wrapper applies the same per-app compatibility policy
as the image's other Electron apps. It removes `LD_PRELOAD` and masks
`/etc/ld.so.preload` for the launched process tree. The inspected app's login
shell probe runs `env -0`, so no VS Code-style `profile.d` hook is added.
Chromium's sandbox remains enabled; no userns or SELinux policy is changed.

## Verification after deployment

```sh
rpm -q chatgpt
cat /usr/lib/chatgpt/codex-launcher
grep x-scheme-handler/codex /usr/share/applications/mimeinfo.cache
chatgpt
```

Fully quit an existing instance before testing. Check desktop launch, sign-in
callback, file selection and shortcuts in the actual GNOME/Niri session.
`WAYLAND_DEBUG=1 chatgpt` can confirm a native Wayland connection; keep that
diagnostic output local. A full image build and interactive hardware checks
are separate from package inspection and the local integration checks.
