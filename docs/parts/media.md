# Media

A host with the `media-server` service runs Jellyfin as the service's principal, reached on the service's `vpn` alone,
at its address there, `<prefix>:ffff:<host id>:<uid>:<id>`, as `media-server-<host>.<namespace>`, on port 8096, over
http, which the vpn encrypts (`docs/parts/vpns.md`). A host with the service but no `vpn`, or not on it, fails
evaluation.

```toml
[service.media-server]
id = 15
vpn = "wg0"
principal.hasPublicKey = false

[role.media-server]
services = ["media-server"]

[service.torrent-server]
principal.members = ["media-server"]
```

## On the host

`nixos/services/media-server.nix`:

- Jellyfin keeps its state in `/var/lib/media-server` and its cache in `/var/cache/media-server`, where the host keeps
  them, as it won't start with less than 2 GiB free for either, which an ephemeral root may not have.
- It answers on 8096 of the host's IPv4 addresses, and `media-server`, a socket at the service's address, hands what
  reaches it there to Jellyfin on loopback; the host's firewall opens 8096 on the vpn's interface and no other.
  Jellyfin's own IPv6 stays off, as it would bind the service's address before the socket.
- It reads the allotments whose principals have it among their `members`, as their group's member, as the
  torrent-server's (`docs/parts/allotments.md`, `docs/parts/torrent.md`).

Its users and libraries are Jellyfin's own, in its state: its setup, as it first answers, makes its first user and its
libraries, an allotment's `path` among them.

## Work in progress

- Nothing archives its state.
- Its users are Jellyfin's own, and none Keycloak's.
- No GPU transcodes for it.
- Only a host that's on the vpn reaches it, by the name the host has for it there.
