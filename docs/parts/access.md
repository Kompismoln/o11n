# Access

What a host lets in from outside its vpns, and what bans those who try it. A host with the `server` role runs fail2ban
(`nixos/org/fail2ban.nix`): one failure bans for a day, longer each time, unless a jail says otherwise, and the org's
own addresses, `<prefix>::/48` and `<prefix4>.0.0/16`, are spared, as sshd's penalties spare them (`nixos/org/ssh.nix`).

## Points and jails

| Port             | Module                          | Login                       | Jail                                             |
| ---------------- | ------------------------------- | --------------------------- | ------------------------------------------------ |
| 22               | `nixos/org/ssh.nix`             | keys alone                  | `sshd`, and sshd's `PerSourcePenalties`          |
| 2602             | `nixos/org/reverse-tunnel.nix`  | a password, while it's open | `reverse-tunnel`: 5 failures, an hour            |
| 587, 993         | `nixos/services/mailserver.nix` | a principal's mail password | `postfix-sasl`, `dovecot`: 5 failures in an hour |
| 25               | `nixos/services/mailserver.nix` | none                        | none: a ban would refuse a sender's mail         |
| 80, 443          | `nixos/nginx.nix`               | each app's own              | per app, below                                   |
| a vpn's udp port | `nixos/org/wireguard.nix`       | the peer's key              | none: wireguard answers no one without a key     |

On 80 and 443:

- `wordpress-<app>` (`nixos/apps/wordpress.nix`): 5 failed logins, POSTs to `wp-login.php` answered with anything but a
  redirect, or POSTs to `xmlrpc.php` in an hour, as nginx logs them; `eval-fail2ban-wordpress` runs nginx with a host's
  log format and checks the filter against what it logs.
- each WordPress denies `xmlrpc.php`.
- keycloak locks a user out after failed logins (`bruteForceProtected`), and reads the client's address from nginx's
  headers.
- nextcloud throttles failed logins itself.
- mobilizon, the django apps and jitsi have no jail.

sshd's filter matches each sshd's `sshd-session`, so the `sshd` jail reads `sshd.service` alone, and the reverse
tunnel's has its own.

## On a host's vpns

A vpn that's `trusted` has no firewall (`nixos/org/wireguard.nix`), and wireguard checks only where a packet comes from:
a peer that routes the org's addresses through the host reaches whatever listens there, the principals' own addresses
included, as each host routes `org.loCidr` to its loopback. On one that isn't, a host opens what its peers reach it for,
each module its own:

- `nixos/org/vpn-proxy.nix`: each of `o11n.vpnProxies`, a port on each of the host's addresses on its vpns, which
  `systemd-socket-proxyd` passes on to a server on loopback: nix-serve's (`nixos/services/nix-serve.nix`), and each vLLM
  server's and the report's, unless it's meant for the host alone (`nixos/services/vllm.nix`).
- `nixos/services/archive.nix` and `nixos/org/allotments.nix`: the archive's and each allotment's port on its vpn.
- `nixos/org/wireguard.nix`: DNS on the vpns the host resolves for, and each vpn's `allowedTCPPorts` and
  `allowedUDPPorts`.

## Listeners

What a host's peers have no need of listens on loopback, or not at all:

- MariaDB on `127.0.0.1` (`nixos/mysql.nix`): its clients use its socket.
- coolwsd on loopback (`nixos/apps/collabora.nix`), which serves the hosts in `collabora.allowedHosts` alone, by default
  each nextcloud that names it.
- prosody on loopback (`nixos/apps/jitsi.nix`), for jicofo, the videobridge and nginx.
- keycloak's cache is local (`nixos/apps/keycloak.nix`), with no cluster to listen for.
- mobilizon runs without Erlang distribution (`nixos/apps/mobilizon.nix`), so neither epmd nor a node listens; it stops
  on SIGTERM, and `mobilizon_ctl` evaluates its commands rather than calling the node.
- nginx's exporter on `127.0.0.1` (`nixos/nginx.nix`).
- nix-serve, each vLLM server and the vLLM report on loopback, for `o11n.vpnProxies` to pass on.
- a vLLM container talks over loopback alone (`nixos/services/vllm.nix`), so its engine's store, on a port of its own
  choosing and every address, answers no one else.
- a `hypr-devstation`'s MariaDB on `127.0.0.1` (`roles/hypr-devstation.nix`), and it runs no transmission, which a
  `hypr-mediastation` does.
- resolved answers neither LLMNR nor mDNS (`nixos/org/networking.nix`).

## Reading the logs

A host with the `logs` service (`nixos/services/logs.nix`) lets the service in with its ssh-key to run the summary
`o11n logs` reads (`docs/parts/o11n.md`), and nothing else: no shell, tty or forwarding. The service reads the journal
as a member of `systemd-journal`, and nginx's logs by an ACL, without root. Each keeps 14 days, fewer if it outgrows its
share of `/var` (`docs/parts/state.md`).
