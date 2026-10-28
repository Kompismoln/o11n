# WIP: remote builder over HTTPS

Status: deployed in Kompismoln/org (pelle builds, helsinki relays) and used from a Claude session. Facts are marked
"Verified" (seen working) or "Unverified" (to check on the real host).

## In short

- NixOS VM tests (`pkgs.testers.runNixOSTest`) need `/dev/kvm`. Claude's cloud sessions have none, and their outbound
  traffic is HTTPS through a proxy that only reaches the hosts the environment allows: no SSH, no remote builder over
  `ssh-ng://`.
- The `remote-builder` role puts Nix's own daemon protocol behind the host's endpoint on 443: a client evaluates locally
  and the host builds, with KVM, as an untrusted user of its nix-daemon. The same thing an operator gets from
  `ssh-ng://` in `wip-nixservice.md`, reachable where only HTTPS is.
- No CI and no GitHub in the loop: a session runs `tools/bin/nix-remote.sh build <installable>` and reads the build log
  as it streams.
- The connection is carried by gost's plain HTTP tunnel (PHT), because a Claude session's proxy carries neither
  WebSockets nor HTTP/2, and it reaches the builder through a relay, because that proxy connects only over IPv4.

## How it works

```
nix (client) --unix socket--> gost (PHT client)
  --POST/GET https://<endpoint>/nix-daemon/{push,pull}-->
  [relay: nginx on an IPv4 host --wg--> ] nginx (TLS, ACME, bearer)
  --> gost relay+pht in forward mode ([bindAddress]:8080)
  --> [bindAddress]:7337 (systemd socket, Accept=yes)
  --> nix-remote@.service: nix-daemon --stdio as nix-remote
  --> /nix/var/nix/daemon-socket/socket (the system daemon, client untrusted)
```

- `nixos/org/remote-builder.nix`, imported by `roles/remote-builder.nix`:
  - nginx (`nixos/nginx.nix`) with a vhost for `host.endpoint`, `forceSSL` and `enableACME`. `location /nix-daemon/`
    proxies to gost without buffering and returns 401 unless `Authorization` is exactly `Bearer <secret-key>`.
  - The check is a `map` that includes a sops template rendered from `nix-remote/secret-key`, so the token never reaches
    the store.
  - `nix-remote-tunnel.service`: gost's `relay+pht` listener on the service's bindAddress, its paths under
    `/nix-daemon/`, forwarding to the socket below. In forward mode the relay handler ignores the destination a client
    asks for and refuses to bind ports, so a client can only reach the daemon.
  - `nix-remote@.service` runs `nix-daemon --stdio` as the service's user, which relays to the system daemon. That user
    isn't in `trusted-users`, so the client can upload sources and `.drv` files and have them built in the sandbox, but
    can't import unsigned outputs or loosen settings.
- `nixos/org/remote-builder-relay.nix`, imported by `roles/remote-builder-relay.nix`, for clients that can't reach the
  builder: Claude's cloud sessions leave through a proxy that only connects over IPv4 (a builder with only an AAAA
  record got 502 "upstream request failed" from it, while IPv6 clients reached it). The relay serves the same location
  on its own endpoint and proxies to the builder over the first vpn they share, checking the builder's certificate
  against its endpoint and sending that as `Host`; without it, the builder's default vhost drops the request. The
  builder still checks the bearer. A tunnel sends a request per write, so the relay keeps its connections to the builder
  open (`keepalive`).
- `tools/bin/nix-remote.sh` (client): writes a gost config (unix socket for nix, an HTTP-proxy hop from `HTTPS_PROXY`
  when set, `phts` to the endpoint with the certificate checked), and runs
  `nix build --store unix://<socket> --eval-store auto -L` or `nix store info`. `check` builds each of the flake's
  checks that way. The token comes from `O11N_REMOTE_BUILDER_TOKEN`, or a proxy adds the header (a network secret in a
  Claude environment).
- gost's PHT client looks the server's name up itself before it dials, and a Claude session resolves only the names of
  its default allowlist: the proxy resolves the rest. `packages/gost.nix` (`o11n#gost`, which the session hook installs)
  patches it to fall back to the port when the name doesn't resolve; the hops before it dial by name. Not fixed upstream
  (go-gost/x master, 2026-10-21).
- gost logs nothing when the tunnel's HTTP requests fail (401, 502, TLS), at any level. When a build fails,
  `nix-remote.sh` asks the endpoint once for a path gost doesn't serve: 404 means the route and token are fine, 401 the
  token, anything else is printed.

## Verified (in a session, every hop on localhost)

Lix 2.95.2's daemon on its own store with `nix-daemon --stdio` as an untrusted user per connection (socat standing in
for the systemd socket), gost 3.3.0 as PHT server and client, the builder's and the relay's `location` as NixOS
generates them (the sample's `gw` and `web`), and Nix 2.34 as the client, through a local HTTP proxy that alone resolves
the relay's name:

- `nix store info` shows `Trusted: 0`; a wrong or missing token: 401 at the builder, reported by `nix-remote.sh`;
- stock gost fails with "no such host" where only the proxy resolves the name; the patched one connects;
- `nix-remote.sh build` uploaded a local source, built in the remote sandbox, streamed the log; a failing build exits
  non-zero with its log;
- `nix-remote.sh check` from an empty remote store: 8601 paths, 200 MB (all but 3.6 MB of it sources such as nixpkgs;
  `.drv` files the rest), in 11655 POSTs and one pull, 70 s without latency;
- gixy accepts both generated nginx configs;
- `map_hash_bucket_size 128` is needed for the bearer's key; 64 fails.

Limits seen:

- With `unix://` as the store, nix treats it as a local filesystem store: `nix store cat`, `nix log` and
  `nix copy --from` fail on remote paths. Builds and their logs (`-L`) work, which is what a VM test needs.
- Without `--no-link`, `nix build` leaves a dangling `result`; `nix-remote.sh build` passes `--no-link`.
- `nix flake check --store <remote> --eval-store auto` (Nix 2.34) asks the remote store which checks need building
  before it has their derivations, builds none and passes. `nix-remote.sh check` builds them with `nix build`, which
  copies the derivations first.

Against the real hosts, from a Claude session:

- The proxy connects only over IPv4: the builder, with only an AAAA record, got 502 "upstream request failed"; IPv6
  clients reached it.
- Through the relay, plain requests arrive with the network secret's header (the builder's wstunnel answered 400 instead
  of nginx's 401).
- The proxy drops `Upgrade` and `Connection`: a WebSocket upgrade reached wstunnel as a plain GET ("Invalid protocol
  request"). It negotiates only HTTP/1.1 (no ALPN `h2`).
- Names resolve only for the default allowlist, not for hosts that are reachable through a network secret.
- A request through the relay takes about 0.25 s, and the proxy closes the connection after each response, so each one
  starts a new TLS handshake. A POST carries up to 32 KB (gost's pipe buffer) when nix writes faster than they return. A
  host that already has the client's nixpkgs, as a build host of the same org does, gets mostly `.drv` files.

On the real builder: switch-to-configuration does nothing for a changed `.socket` unit (a FIXME in
switch-to-configuration-ng, after an attempted fix was reverted upstream). When the relay's socket moved address,
systemd marked it "not functional until restarted" and kept it active, bound to nothing, and gost got "connection
refused". The socket is now `PartOf` the tunnel's service, which names the same address and so restarts when it changes.

Verified from a Claude session through helsinki to pelle:

- `nix-remote.sh info`: Lix 2.95.2, `Trusted: 0`.
- The proxy passes the PHT pull as it arrives: build logs streamed during runs of up to 80 s. Seven of the org's
  systems, of which pelle had most paths, took 79 s for 122 derivations, copying the missing `.drv` files included;
  bootstrap's 65 took 28 s.
- gost and the daemon relay under their systemd hardening, and both endpoints' ACME certificates (the client checks the
  relay's, the relay the builder's).
- A failing build exits non-zero with its log, and `nix-remote.sh` says the builder still answers. When the builder
  doesn't answer, it diagnoses: through pelle's own endpoint, which has no IPv4, the probe got 502.

## Unverified

- How long the proxy keeps the PHT pull open: a build that runs for hours could be cut.
- `/dev/kvm` in the build sandbox on the host: NixOS' default `system-features` include `kvm`, and udev makes `/dev/kvm`
  0666 (check with `ls -l /dev/kvm`).

## Setting it up in an org

- `[service.nix-remote]` with an `id`, `principal.hasPublicKey = false` and `grants = ["host:remote-builder"]`;
  `[role.remote-builder] services = ["nix-remote"]`; the role on a host with an `endpoint`.
- `id-entities.sh -s nix-remote init` and `id-entities.sh -s nix-remote new secret-key`; the token is
  `id-entities.sh -s nix-remote cat-secret secret-key`.
- Ports 80 and 443 reach the host (nginx opens them in its firewall).
- For IPv4-only clients, `[role.remote-builder-relay] services = []` and the role on a host with an endpoint reachable
  over IPv4 that shares a vpn with the builder. Clients then use `https://<relay endpoint>`, and a network secret goes
  on the relay's host.

## Security

- Whoever holds the token can build any derivation on the host as an untrusted user: CPU, disk and sandboxed network
  (fixed-output fetches). The same power as `nix-build` over `ssh-ng://` in `wip-nixservice.md`.
- Outputs land in the host's store, which a substituter serves to every peer. A peer only fetches the output of a
  derivation its own closure refers to.
- The token passes through any TLS-inspecting proxy between client and host, as a Claude session's does.
- Untrusted users can read any store path, as they can locally.

## Considered before

- GitHub Actions on a self-hosted runner on the host (the job dispatched and its logs read through GitHub's API),
  GitHub-hosted runners, another CI (Hydra, buildbot-nix, Forgejo Actions), a Claude Code self-hosted environment or
  Remote Control on the host. The tunnel needs no CI, no GitHub access for the host, and gives a session the same
  `nix build` as a local one.
- o11n's own VM test, `tests/vm/deploy.nix`, runs this way too (`nix-remote.sh build .#vmTests.deploy`); `tests/nixos/*`
  evaluate modules. chatddx-remastered's `nix/test.nix` was the first.

## Open

- Offer the gost patch upstream.
- `nix-remote.sh` is in o11n's `tools/` and copied into the org's.
