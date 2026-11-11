# Media

A host with the `media-server` service keeps a media library in the service's allotment on the host,
`allotment."service-media-server@<host>"`, which the torrent-server on the host downloads into, and Radarr, Sonarr and
Lidarr file what it downloads there, which Jellyfin serves. Each runs as the service's principal, reached on the
service's `vpn` alone, at its address there, `<prefix>:ffff:<host id>:<uid>:<id>`, as `media-server-<host>.<namespace>`,
over http, which the vpn encrypts (`docs/parts/vpns.md`). A host with the service but no `vpn`, or not on it, fails
evaluation, as does one without the allotment, or without the torrent-server or the allotment's `torrent = true`.

```toml
[service.media-server]
id = 15
vpn = "wg0"
principal.hasPublicKey = false

[role.media-server]
services = ["media-server"]

[allotment."service-media-server@web"]
size = "500G"
torrent = true
```

## The library

The allotment holds `movies/`, `tv/` and `music/`, the library, and `downloads/`, where the torrent-server downloads by
default, and each *arr's kind of it, `downloads/movies/`, `downloads/tv/` and `downloads/music/`, what
`o11n torrent add --as` names (`docs/parts/torrent.md`):

- each *arr takes what's downloaded into its kind's directory, of a title it has, into its kind of the library, as a
  hardlink, as both are in one allotment, renamed as it names them and with Kodi's `.nfo` files and images, which any
  player reads; a title it doesn't have, its UI imports
- each removes a torrent of its own once Transmission stops seeding it, at the torrent-server's `ratio`, and what it
  downloaded with it, which leaves the library's link
- what's downloaded into `downloads/` itself, no *arr takes.

## On the host

`nixos/services/media-server.nix`:

- Jellyfin keeps its state in `/var/lib/media-server` and its cache in `/var/cache/media-server`, and Radarr, Sonarr and
  Lidarr theirs in `/var/lib/media-server-<arr>`, where the host keeps them, as Jellyfin won't start with less than 2
  GiB free for either, which an ephemeral root may not have.
- Jellyfin answers on 8096 of the host's IPv4 addresses, and Radarr on 7878, Sonarr on 8989 and Lidarr on 8686 of
  loopback's, and `media-server-<app>`, a socket at the service's address on each port, hands what reaches it there to
  its app on loopback; the host's firewall opens the ports on the vpn's interface and no other. Jellyfin's own IPv6
  stays off, as it would bind the service's address before the socket.
- The *arrs ask for no login, as `External`, the vpn alone keeping others from them.
- `media-server-<arr>-setup`, once the *arr and the allotment are up, makes the directories of its kind, and has the
  *arr with its kind of the library as its root folder, Transmission's RPC as its download client, `torrent-server`, of
  its kind's directory, its renaming on and its Kodi metadata, through its API, with the key it keeps in its
  `config.xml` (`nixos/services/media-server-setup.sh`).

Jellyfin's users and libraries are its own, in its state: its setup, as it first answers, makes its first user and its
libraries, of the library's `movies/`, `tv/` and `music/`.

## Work in progress

- Nothing archives its state.
- Its users are Jellyfin's own, and none Keycloak's.
- No GPU transcodes for it.
- Only a host that's on the vpn reaches it, by the name the host has for it there.
- The *arrs search no indexers: they take what the operator adds.
