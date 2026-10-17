# AmneziaWG without the AmneziaVPN client (`awg-quick`)

AmneziaWG is WireGuard plus traffic obfuscation. The image ships the userspace
stack — `awg`, `awg-quick`, `amneziawg-go` — and nothing else. Tunnels are
ordinary `awg-quick@<iface>.service` units reading
`/etc/amnezia/amneziawg/<iface>.conf`.

The GUI client was tried first and removed on 2026-09-30. It could not work
here, and the way it failed took the machine's network down with it.

Addresses below are placeholders — `<server-ip>`, `<vpn-dns>`, `<lan-router>`,
`100.x.y.z` — because this repo is public. Substitute the real values from
`~/.local/share/amneziawg/` locally.

## Why the AmneziaVPN client was abandoned

Four separate walls, in the order they were hit.

1. **X11-only.** The `.run` bundles Qt 6.10.1 with exactly one platform
   plugin, `libqxcb.so`. secureblue runs `gnome-shell --no-x11` (AGENTS.md
   constraint 7), so `DISPLAY` is empty and the xcb fallback aborts. Workable
   via `/usr/libexec/fromelicks-xwayland-isolated`, but only the first wall.
2. **No `pkexec`.** The Qt Installer Framework's sole Linux elevation helper
   is `/usr/bin/pkexec`; secureblue ships neither it nor `sudo`, only `run0`.
   The GUI installer can never elevate. Headless (`--platform minimal in -t
   …`) under `run0` sidesteps this.
3. **`post_install.sh` calls `sudo` on every privileged line** and writes into
   immutable `/usr` (`/usr/share/applications`, `/usr/share/pixmaps`). Run as
   root it still fails every step — the install looks fine and nothing is
   wired up.
4. **The daemon cannot install routes on this machine.** This is the one that
   ended it.

### The route failure, and the kill switch it stranded

```
LinuxFirewall    : 310.blockDNS(IPv4): OFF -> ON      ← kill switch armed first
LinuxRouteMonitor: Adding exclusion route for <server-ip>/32
LinuxRouteMonitor: Invalid destination prefix         ← every add fails
LinuxRouteMonitor: Adding exclusion route for /999999
LinuxRouteMonitor: Adding route to 0.0.0.0/1
LinuxRouteMonitor: Invalid destination prefix
Daemon           : Routing configuration failed for 0.0.0.0/0
DaemonLocalServerConnection : Failed to activate the interface
```

`amn0` came up; not one route was installed. `LinuxRouteMonitor` reads the
kernel routing table over netlink into a **fixed 8 KiB buffer**. With a complex
routing setup the dump overflows, parsing collapses, and every subsequent add
is rejected — the nonsense `/999999` prefix is the fingerprint. Upstream
[#3090](https://github.com/amnezia-vpn/amnezia-client/issues/3090); the sibling
[#2549](https://github.com/amnezia-vpn/amnezia-client/issues/2549) reports the
same breakage specifically **when secondary route tables exist**.

This machine has them, from NetBird:

```
105:   from all lookup main suppress_prefixlength 0
110:   not from all fwmark 0x1bd00 lookup 7120
20053: not from all fwmark 0x4e55 lookup 20053 proto static
```

Still unfixed in 5.0.3.0, the newest release. Reporters note 4.8.21 works.

**The kill switch is armed before routing is attempted and is not rolled back
when activation fails.** Closing the GUI does nothing — the rules belong to the
root daemon. The chains are default-deny, and their order inside
`amnvpn.anchors` is what makes the failure total:

```
000.allowLoopback → 320.allowDNS → 310.blockDNS → 300.allowLAN → … → 110.allowNets → 100.blockAll
```

`310.blockDNS` REJECTs **all** port 53 and sits *above* both `allowLAN` and
`allowNets`. The only DNS permitted is `<vpn-dns>` out of `amn0`/`tun0`/
`tun2` — a tunnel that never came up. So no exception list can rescue DNS: the
client's own Exceptions page feeds `allowNets`, which is evaluated too late.

Resolution died at the last hop, which is why `dig` returned **SERVFAIL in
1 ms** — a local answer, not a timeout:

| hop | outcome |
|---|---|
| app → `100.x.y.z` (`/etc/resolv.conf`) | this machine's own `wt0`; routed via `lo` → `allowLoopback` permits it |
| NetBird resolver → `127.0.0.1` (unbound) | still `lo` → permitted |
| unbound → `<lan-router>:53` out `wlp0s20f3` | **REJECT** by `310.blockDNS` |

`ping 1.1.1.1` hit `100.blockAll` (`Destination Port Unreachable`, then
`sendmsg: Operation not permitted`). IPv6 was dead too, via `250.blockIPv6`,
which rejects everything not on loopback. Nothing persists the chains, so a
reboot cleared it.

A fifth problem would have surfaced even on success: `No suitable DNS manager
found.` The client only speaks systemd-resolved. See *DNS* below.

## What the image installs

`files/scripts/install-amneziawg.sh`, after the `dnf` module. Neither half is
packaged for Fedora — the upstream COPR (`amneziavpn/amneziawg`) enables EPEL
and CentOS chroots only, **zero Fedora chroots**, and its newest build is from
2024 — so both are built from source:

| | tag | commit |
|---|---|---|
| [`amneziawg-tools`](https://github.com/amnezia-vpn/amneziawg-tools) | `v3.1.20260812` | `ee0f0a9aa34ff0a0da4b3433b9512781cfe02843` |
| [`amneziawg-go`](https://github.com/amnezia-vpn/amneziawg-go) | `v3.1.20260828` | `b5928efb6ca19f0153958460c3d141f04abc5c2e` |

Pinned by tag **and** verified by commit SHA, because a tag is mutable. Only
`libmnl-devel` is added as a build dep and it is removed again; `gcc`, `make`,
`git`, `golang` and `libmnl` are already in the image.

The **v3.1 series is mandatory** for this server. Its config is
`protocol_version 3.1`, which uses `I1`–`I5`, `S3`/`S4`,
`HeaderProtectionKey`, `RandomTrailers`, `DisableCookies` and range-valued
timers (`RekeyAfterTime = 100-120`, `PersistentKeepalive = 25-35`). Anything
older — including every COPR build — rejects those keys. The build script
asserts `awg` contains them, so a future tag that drops one fails the build
instead of failing silently at connect time.

### No kernel module, deliberately

There is none for AmneziaWG here and we do not build one: it would need DKMS or
akmods against a secureblue kernel. `awg-quick`'s `add_if()` already falls back
to `amneziawg-go` when `/sys/module/amneziawg` is absent, so the fallback needs
no configuration — only the binary on `PATH`. One remote peer does not need
kernel-side crypto.

## Usage

```
ujust awg-import ~/path/to/awg0.conf   # installs to /etc/amnezia/amneziawg/awg0.conf, mode 600
ujust awg-up                           # start now
ujust awg-status                       # handshake, transfer, routes, DNS
ujust awg-down
ujust awg-enable                       # and at every boot
ujust awg-check                        # verify the stack
```

All take an optional interface name, defaulting to `awg0`.

The config is **per-machine runtime state and is never baked into the image**
(AGENTS.md principle 2) — it carries `PrivateKey`, `PresharedKey` and
`HeaderProtectionKey`. `/etc/amnezia/amneziawg` is created mode `0700` by the
build; `awg-quick` refuses a world-readable config.

### Converting an AmneziaVPN client config

The client stores everything in `~/.config/AmneziaVPN.ORG/AmneziaVPN.conf`, as
a QSettings `@ByteArray(...)` holding JSON with escaped newlines. The ready-to-
use tunnel config is at `containers[].awg.last_config`, itself a JSON string,
under the key `config`. Unescape `\\`, `\"` and `\n`, parse twice, and take
that field. Two edits are needed:

- `DNS = $PRIMARY_DNS, $SECONDARY_DNS` is left **unsubstituted** — the client
  fills it at connect time from the server object's `dns1`/`dns2`. Comment the
  line out and use the hook below.
- `MTU` is not in the template; take `last_config.mtu`.

## DNS

**Do not use `DNS =` in a tunnel config on this host.** `awg-quick` implements
it by shelling out to `resolvconf`, which here is a symlink to `resolvectl`
from systemd-resolved — and systemd-resolved is **masked**, because secureblue
resolves through **dnsconfd driving unbound**. That same dead end is what made
AmneziaVPN log `No suitable DNS manager found`.

Instead, `/usr/libexec/fromelicks-awg-dns` is called from the config:

```ini
PostUp  = /usr/libexec/fromelicks-awg-dns up <vpn-dns>
PreDown = /usr/libexec/fromelicks-awg-dns down
```

`up` runs `dnsconfd update --mode exclusive <server…>`. Exclusive means only
those servers may resolve anything, so lookups follow the default route into
the tunnel. This matters: with `AllowedIPs = 0.0.0.0/0` the tunnel carries
everything *except* what a more specific route keeps on the LAN — and the
resolver dnsconfd forwards to is usually the LAN router, which stays on the
LAN. Left alone, every lookup leaks to the router in cleartext while the rest
of the traffic is tunnelled.

If `dnsconfd` is not active, `up` **fails**, and `awg-quick` then tears the
interface back down. A tunnel whose DNS still points at the LAN router is worse
than no tunnel. `down` never fails, because `awg-quick` runs `PreDown` while
dismantling the interface.

`down` restores by restarting `dnsconfd` rather than replaying a saved list.
dnsconfd is a NetworkManager DNS plugin and repopulates itself from NM on
start, which restores the per-connection split-DNS — on this machine the work
WireGuard tunnel's internal zone and its forwarder — without this script having
to understand it.

## Coexisting with NetBird and the work tunnel

Three overlays want the network at once, and they do not compose by themselves:

- **NetBird** (`wt0`, `100.x.y.z/16`) installs the policy rules at
  priorities 105/110/20053 shown above, and **overwrites `/etc/resolv.conf`**
  (the dnsconfd original is parked at `/etc/resolv.conf.original.netbird`).
- **The work tunnel** is a NetworkManager-managed WireGuard connection. NM is
  what feeds dnsconfd its split-DNS, which is why `awg-quick` tunnels — created
  outside NM — get none of that automatically.
- **AmneziaWG** with `AllowedIPs = 0.0.0.0/0` wants the default route.

NM cannot carry AmneziaWG's obfuscation parameters, so importing the tunnel as
an NM connection is not an option — hence `awg-quick` plus the explicit DNS
hook.

If a tunnel comes up but carries no traffic, check for rule-priority conflicts
first: `awg-quick` installs its `suppress_prefixlength 0` rule at 32764, far
**below** NetBird's 105, so NetBird's rules are consulted first. `ujust
awg-status` prints `ip rule` for this reason. Stopping `netbird` is the fastest
way to tell whether it is implicated.

## Preserved from the client install

Kept out of the image, under `~/.local/share/amneziawg/` (mode `0700`):

- `amnezia-servers.json` — the decoded client settings, source of truth for the
  tunnel config.
- `awg0.conf` — generated from it, ready for `ujust awg-import`.
- `amneziawg-go.from-client-5.0.3.0` — the datapath binary the client shipped,
  known to speak protocol 3.1. A fallback if a built `amneziawg-go` ever
  regresses; set `WG_QUICK_USERSPACE_IMPLEMENTATION` to use it.

## Purging the client

For reference, since `post_uninstall.sh` is `sudo`-based and does not work
either:

```bash
run0 bash -c 'systemctl disable --now AmneziaVPN 2>/dev/null; rm -f /etc/systemd/system/AmneziaVPN.service; systemctl daemon-reload; rm -rf /opt/AmneziaVPN /var/log/AmneziaVPN /run/amneziavpn; rm -f /usr/local/bin/AmneziaVPN'
```

User-side: `~/.config/AmneziaVPN.ORG` and
`~/.local/share/applications/AmneziaVPN.desktop`.

The `amnvpn.*` firewall chains do not survive a reboot. To clear them live,
delete the `-j amnvpn.anchors` jumps from each hooked chain, then flush and
delete every `amnvpn.` chain across `raw`/`mangle`/`nat`/`filter` for v4 and
v6 — never a whole table, since firewalld shares them.
