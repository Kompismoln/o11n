# Torrent

A host with the `torrent-server` service runs Transmission as the service's principal, and downloads into the service's
allotment on the host, `allotment."service-torrent-server@<host>"`, which bounds what it holds by its `size`
(`docs/parts/allotments.md`). A host with the service and no such allotment, or a service without its `ssh-key`, fails
evaluation.

```toml
[service.torrent-server]
id = 14
actors = ["user-alice"]

[service.torrent-server.hosts.web]
upload = 200
ratio = 2

[role.torrent-server]
services = ["torrent-server"]

[allotment."service-torrent-server@web"]
size = "500G"
sftp = ["app-cloud"]
```

## On the host

`service.torrent-server.hosts.<host>` limits the server (`org/services/torrent-server.nix`): `upload` and `download`, in
KiB/s, and `ratio`, which a torrent stops seeding at, each without a limit when null, and `peerPort`, 51413 by default,
which it takes peers on, TCP and UDP, open in the host's firewall (`nixos/services/torrent-server.nix`):

- it starts once `allotment@service-torrent-server` has made the allotment, and keeps what it downloads at the
  allotment's root, as the principal's, a file still downloading by its name with `.part` after it
- its RPC answers on loopback alone, and its state is in `/var/lib/torrent-server`, where the host keeps it
- a host behind a router reaches peers that dial it once the router forwards `peerPort` to it, as a `uci` redirect does
  (`docs/parts/openwrt.md`).

An allotment's `sftp` reaches what it downloaded, as for any allotment, as a nextcloud's `external` mounts it.

## From the operator

`o11n torrent [--host <host>] <action>` (`crates/o11n/src/torrent.rs`) logs in to the host with the service, the one
there is unless `--host` names one, with service-torrent-server's ssh-key, which an operator who is one of its `actors`
decrypts:

- `add <link>...`: adds each magnet link or URL, or a `.torrent` file of the operator's, sent on stdin; a link with
  whitespace in it fails, as ssh would split it there.
- `list`: the torrents, each by its id.
- `remove [--delete] <id>...`: removes the torrents, and with `--delete` what they downloaded.

The host lets the key in as the principal to run `nixos/services/torrent-server.sh` alone, with nothing forwarded and no
tty, which runs `transmission-remote` on the RPC; its other logins, as the allotment's sftp clients', are as their own
have them.
