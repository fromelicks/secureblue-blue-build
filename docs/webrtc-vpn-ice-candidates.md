# WebRTC voice over a split-tunnel VPN

Why Discord voice hung at "DTLS Connecting" whenever a split-tunnel WireGuard
connection was up, and what this image does about it.

Addresses below are placeholders: `10.0.0.2` is the tunnel address,
`192.168.1.10` the wifi address, `100.64.0.10` NetBird's `wt0`.

## The symptom

Vesktop (flatpak `dev.vencord.Vesktop`) with a split-tunnel WireGuard profile
up: joining a voice channel stalled at **"DTLS Connecting"** indefinitely.
Joining with the VPN down and then bringing it up mid-call worked. A tunnel
whose AllowedIPs happened to cover the voice server never had the problem.

The tunnel carried RFC 1918 prefixes only, and the default route stayed on
wifi, so Discord's traffic was never routed into it.

## Ruled out

| Suspect | Why not |
|---|---|
| Discord routed into the tunnel | `ip route` / `ip rule`: default via wifi, AllowedIPs private-only. |
| Reverse-path filtering | Effective `rp_filter` is 2 (loose). |
| DNS | The voice server's IP arrives as a literal in the voice WebSocket `READY` payload; a DNS failure stalls earlier, at "Awaiting Endpoint". |
| `--force-webrtc-ip-handling-policy=…` | No effect in Vesktop: the tunnel socket still appeared. Electron exposes this policy only as `session.setWebRTCIPHandlingPolicy()`, which the app itself would have to call. |

## Root cause

Two defects, each harmless alone.

### 1. libwebrtc ranks an unrecognised tunnel above wifi

libwebrtc gathers an ICE host candidate on every local interface. `ss -unap`
during a join:

```
VPN up:    100.64.0.10:52089  10.0.0.2:45582  192.168.1.10:44299   (all UNCONN)
VPN down:  100.64.0.10:57291                  192.168.1.10:40903
```

The ranking is in `rtc_base/network.cc` (upstream `main`, 2026-09). On Linux
there is no `NetworkMonitor`, so the adapter type comes from the interface
**name** alone, and the match requires everything after the prefix to be
digits:

```c
bool MatchTypeNameWithIndexPattern(absl::string_view network_name,
                                   absl::string_view type_name) {
  if (!absl::StartsWith(network_name, type_name)) {
    return false;
  }
  return absl::c_none_of(network_name.substr(type_name.size()),
                         [](char c) { return !isdigit(c); });
}
```

The VPN prefixes are `ipsec`, `tun`, `utun`, `tap` and `tailscale`. Anything
unmatched is `ADAPTER_TYPE_UNKNOWN = 0`. `SortNetworks` orders by `type()`
**ascending**, so UNKNOWN sorts first and gets the highest preference; ties
fall through to IP precedence and then `a->key() < b->key()` — alphabetical by
interface name.

`wlp0s20f3` does not match `wlan` either, so wifi, the tunnel and NetBird's
`wt0` were all UNKNOWN. A tunnel named e.g. `office-vpn` sorts before
`wlp0s20f3` and wins; `wt0` sorts last, which is why NetBird never caused this.

### 2. The tunnel-address candidate is a black hole

A packet from the tunnel address to a destination the tunnel does not carry is
routed by destination alone. It leaves via wifi with a foreign source address
and is silently dropped upstream:

```
ping -I 10.0.0.2     8.8.8.8   ->  100% packet loss
ping -I 192.168.1.10 8.8.8.8   ->  reply
```

A top-ranked dead candidate is what stalled the handshake. It also explains the
two odd observations: candidate selection happens once, at connect time (so
enabling the VPN mid-call was harmless), and a tunnel that routes the voice
server gives its candidate a real path.

## Fix, part 1: name the interface `tun<N>`

```bash
nmcli con mod <profile> connection.interface-name tun0
```

The tunnel becomes `ADAPTER_TYPE_VPN = 8`, which sorts after UNKNOWN and so
after wifi. This alone fixed voice. The connection *id* can stay descriptive.

| Interface name | libwebrtc type | Effect |
|---|---|---|
| `tun0`, `tun9` | VPN | Sorts after wifi. **Use this** (`tun9` if something else claims `tun0`). |
| `utun0`, `tap0`, `ipsec0`, `tailscale0` | VPN | Same effect, misleading on Linux. |
| `tun-office` | UNKNOWN (letters after `tun`) | Sorts before `wlp…` and wins. |
| `wg0` | UNKNOWN | `wg` < `wl`, so it wins. **The conventional WireGuard name is the worst choice.** |

Upstream disclaims this heuristic in a comment above `GetAdapterTypeFromName`,
so part 1 is a nudge, not a guarantee.

## Fix, part 2: confine the tunnel address to the tunnel's routes

This removes the black hole itself, for every WebRTC application, with no
naming heuristic involved.

```bash
ujust wg-confine <profile>       # apply to the profile, and live via nmcli device reapply
ujust check-wg-confine           # report every WireGuard profile
ujust wg-unconfine <profile>     # remove
```

`/usr/libexec/fromelicks-wg-split-confine` writes everything into the
NetworkManager profile, per address family:

| Setting | Value | Purpose |
|---|---|---|
| `route-table` | `T` (18000–18009) | The tunnel's routes, device and peer routes included, live in `T` instead of `main`. |
| rule 90 | `from <tunnel addr> table T` | The tunnel address reaches the tunnel's destinations… |
| rule 91 | `from <tunnel addr> type unreachable` | …and nothing else: `ENETUNREACH` at once, so the candidate is discarded. |
| rule 92 | `from all table T` | Everything else still reaches the tunnel's destinations; `T` has no default, so a miss falls through to `main`. |

Because `T` is dedicated, the tunnel address is also cut off from LAN, NetBird
and container routes in `main`, which a "`main` minus the default route" rule
would have missed. The tables are named `wgsplit0`–`wgsplit9` in
`/usr/share/iproute2/rt_tables.d/fromelicks-wg-split.conf`, clear of 51820
(wg-quick's full-tunnel table), NetBird (7120) and NetworkManager's routed-dns
(20053).

The helper refuses non-WireGuard connections, a family that is a full tunnel
(a peer routes `/0`, a gateway, or a static `/0` route — NetworkManager's
`ip4-auto-default-route` already handles those), and a family whose
`route-table` is already set outside the reserved range.

After changing a tunnel's address, run `ujust wg-confine` again: the rules name
the address, and `check-wg-confine` reports the mismatch as `STALE`.

### Never put an unreachable route where `suppress_prefixlength` reaches it

The first version put `0.0.0.0/0 type=unreachable` inside `T`, paired with
`from all lookup T suppress_prefixlength 0`. While that tunnel was up, **every**
lookup failed. A lookup that lands on an unreachable route ends with that error
on the spot: `suppress_prefixlength` does not hide it and later rules are never
tried. Hence the block is a rule, and `T` holds only the tunnel's routes.

## Verification

Confined tunnel on `tun0`, table 18000:

```
from 10.0.0.2 -> internet, Discord voice range, LAN, NetBird   Network is unreachable
from 10.0.0.2 -> tunnel destinations                            dev tun0 table 18000
unbound       -> internet                                       via wifi
unbound       -> tunnel destinations                            dev tun0 table 18000
unbound       -> NetBird                                        dev wt0
```

Pings, TCP 443 and DNS over the tunnel and to the internet all worked. On
throwaway profiles the helper was also checked for: IPv6 handled like IPv4,
idempotent re-apply, `STALE` detection and repair, `remove` restoring routes to
`main`, refusals, and two profiles sharing one address — NetworkManager keeps
the identical rule 91 once and it survives the other profile's teardown. The
IPv6 path was checked structurally only; the test network had no IPv6.

A confined tunnel's routes are no longer in `main`: use
`ip route show table <T>` or `ip -N rule show` when debugging.

## Importing a wg-quick `.conf`

- The interface name comes from the **file name**; there is no key for it.
  Import `tun0.conf`, not `office-vpn.conf`.
- Leave `ListenPort` out so the kernel picks a random port.
- Don't edit the profile in GNOME Settings: its WireGuard editor writes
  `listen-port=51820` for a blank field, which collides with NetBird's `wt0`
  (`set-device … rejected: Address already in use`). Repair with
  `nmcli con mod <profile> wireguard.listen-port 0`.

```bash
nmcli connection import type wireguard file ./tun0.conf
ujust wg-confine tun0
ujust check-wg-confine
```
