# Notes

## TPM2 LUKS unlock stops working after rebase / kernel update

`ujust setup-luks-tpm-unlock` seals to **PCR 7 + PCR 14**. PCR 14 covers the MOK list and
boot entries, so it changes on every image rebase or kernel update. When it does, the TPM
portion fails even with the correct PIN and LUKS falls back to prompting for the PIN then the
passphrase.

**Fix:** re-run `ujust setup-luks-tpm-unlock`, answer `y` to "Wipe it and re-enroll?", enter
the LUKS passphrase, and set a new PIN. This re-seals the slot to the current PCR values.

You'll need this after every rebase until/unless the enrollment is changed to omit PCR 14.

---

## Coexisting WireGuard VPN and NetBird

### Problem

Running a split-tunnel WireGuard VPN alongside NetBird on Linux causes two conflicts:

1. **Port collision** — both default to `listen-port=51820`. The kernel can't bind the same UDP port to two WireGuard interfaces.
2. **DNS** — NetBird overwrites `/etc/resolv.conf` with its own resolver, which doesn't know about internal corporate domains.

### Fix

**Port collision** — set the work VPN's listen port to `0` (ephemeral). A VPN client doesn't need a fixed listen port; only servers do.

```bash
nmcli connection modify <connection-name> wireguard.listen-port 0
nmcli connection up <connection-name>
```

**DNS for internal domains** — add a NetBird Nameserver in the management UI instead of editing `resolv.conf` or writing dispatcher scripts:

1. NetBird admin UI → **DNS → Nameservers → Add nameserver**
2. DNS server: the corporate nameserver IP (must be in the VPN's `AllowedIPs`), port 53
3. Match domains: the internal domain suffix (e.g. `corp.example.com`)
4. Apply to your peer group

NetBird's resolver forwards matching queries through the tunnel to the corporate DNS. Works automatically whenever the WireGuard VPN is up. No effect when the VPN is down — expected, since internal domains aren't reachable anyway.

### Why not put the WireGuard config on a NetBird router peer?

The NetBird Networks approach (one peer holds the WireGuard config and advertises the corporate subnets to the whole mesh) is the right architecture for **multi-device** access. For a single machine, it adds unnecessary infrastructure and moves corporate credentials to another host. The nameserver-only fix is sufficient for single-device use.
