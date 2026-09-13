# ── WireGuard split-tunnel source confinement ──────────────────────────────

# A split tunnel's own address must only reach the tunnel's own routes;
# otherwise WebRTC can pick it as an ICE candidate that black-holes, which hung
# Discord voice at "DTLS Connecting". The confinement lives in the
# NetworkManager profile, which is per-machine runtime state (it holds the WG
# private key), so it is applied with these recipes rather than baked. See
# docs/webrtc-vpn-ice-candidates.md.

# Example: ujust wg-confine office-vpn
# Confine a split-tunnel WireGuard profile's address to the tunnel's own routes.
[group('VPN')]
[positional-arguments]
wg-confine CONNECTION:
    @/usr/libexec/fromelicks-wg-split-confine apply "$1"

# Remove the confinement from a WireGuard profile.
[group('VPN')]
[positional-arguments]
wg-unconfine CONNECTION:
    @/usr/libexec/fromelicks-wg-split-confine remove "$1"

# Report confinement for the named WireGuard profiles, or for all of them.
[group('VPN')]
[positional-arguments]
check-wg-confine *CONNECTIONS:
    @/usr/libexec/fromelicks-wg-split-confine status "$@"
