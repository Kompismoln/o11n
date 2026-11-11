# Torrent

A host with the `torrent-server` service runs Transmission as the service's principal, which owns nothing it downloads:
it downloads into the allotments on the host with `torrent = true`, each as its principal's, which bounds what it holds
by its `size` (`docs/parts/allotments.md`). A host with the service and no such allotment, or a service without its
`ssh-key`, fails evaluation, as does an allotment with `torrent = true` on a host without the service, or with
`replicas`, which would sync what's still downloading and break its seeding as they change it.

```toml
[service.torrent-server]
id = 14
actors = ["user-alice"]

[service.torrent-server.hosts.web]
upload = 200
ratio = 2

[role.torrent-server]
services = ["torrent-server"]

[allotment."service-media-server@web"]
size = "500G"
torrent = true
```

## On the host

`service.torrent-server.hosts.<host>` limits the server (`org/services/torrent-server.nix`): `upload` and `download`, in
KiB/s, and `ratio`, which a torrent stops seeding at, each without a limit when null, and `peerPort`, 51413 by default,
which it takes peers on, TCP and UDP, open in the host's firewall (`nixos/services/torrent-server.nix`):

- `torrent-server-mount@<handle>`, once `allotment@<handle>` has made the allotment, bind-mounts it at
  `/run/torrent-server/<handle>`, mapping the principal's uid and gid to the service's, and Transmission, which starts
  once each is mounted, has each at the allotment's own `path`: what it writes there is the principal's, and it seeds
  from it as the principal's too, while it reaches nothing else of the principal's
- a download goes into its directory as it is, a file still downloading by its name with `.part` after it
- its RPC answers on loopback alone, and its state is in `/var/lib/torrent-server`, where the host keeps it
- a host behind a router reaches peers that dial it once the router forwards `peerPort` to it, as a `uci` redirect does
  (`docs/parts/openwrt.md`).

Where a download goes is `o11n.torrent-server` of the host's configuration: by default an allotment's `path` for each
allotment, and the one there is when there's one; the media-server files them in its library (`docs/parts/media.md`).

## From the operator

`o11n torrent [--host <host>] <action>` (`crates/o11n/src/torrent.rs`) logs in to the host with the service, the one
there is unless `--host` names one, with service-torrent-server's ssh-key, which an operator who is one of its `actors`
decrypts:

- `add [--to <handle>|--as <kind>] <link>...`: adds each magnet link or URL, or a `.torrent` file of the operator's,
  sent on stdin, into the allotment of the principal `--to` names, or where the media-server's *arrs take a kind from,
  as `--as movies`, `tv` or `music`, or else where the host downloads by default. A link with whitespace in it fails, as
  ssh would split it there, as do an allotment and a kind the server doesn't download into, and an `add` without either
  where the host has no default.
- `list`: the torrents, each by its id.
- `remove [--delete] <id>...`: removes the torrents, and with `--delete` what they downloaded.

The host lets the key in as the principal to run `nixos/services/torrent-server.sh` alone, with nothing forwarded and no
tty, which runs `transmission-remote` on the RPC.
