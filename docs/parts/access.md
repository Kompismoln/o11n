# Access

What a host lets in from outside its vpns, and what bans those who try it. A host with the `server` role runs fail2ban
(`nixos/org/fail2ban.nix`): one failure bans for a day, longer each time, unless a jail says otherwise, and the org's
own addresses, `<prefix>::/48` and `<prefix4>.0.0/16`, are spared, as sshd's penalties spare them (`nixos/org/ssh.nix`).
It bans with nftables, in sets of its own table, `inet f2b-table`, as iptables refuses the chain of a jail whose name is
over 24 characters, as a jail named after an app can be. `vmTests.mailboxes` bans an address in each of `mx`'s jails,
one of them named that long, and finds it in the jail's set. A jail that reads the journal opens all of the host's local
journals, as journald keeps the lines of a service that runs as an app in a journal of the app's uid, which fail2ban
would otherwise read only if it was there as the jail started.

## Points and jails

| Port             | Module                         | Login                       | Jail                                             |
| ---------------- | ------------------------------ | --------------------------- | ------------------------------------------------ |
| 22               | `nixos/org/ssh.nix`            | keys alone                  | `sshd`, and sshd's `PerSourcePenalties`          |
| 2602             | `nixos/org/reverse-tunnel.nix` | a password, while it's open | `reverse-tunnel`: 5 failures, an hour            |
| 587, 993         | `nixos/apps/mail.nix`          | a principal's mail password | `postfix-sasl`, `dovecot`: 5 failures in an hour |
| 25               | `nixos/apps/mail.nix`          | none                        | none: a ban would refuse a sender's mail         |
| 80, 443          | `nixos/nginx.nix`              | each app's own              | per app, below                                   |
| a vpn's udp port | `nixos/org/wireguard.nix`      | the peer's key              | none: wireguard answers no one without a key     |

On 80 and 443:

- `wordpress-<app>` (`nixos/apps/wordpress.nix`): 5 failed logins, POSTs to `wp-login.php` answered with anything but a
  redirect, or POSTs to `xmlrpc.php` in an hour, as nginx logs them; `eval-fail2ban-wordpress` runs nginx with a host's
  log format and checks the filter against what it logs.
- each WordPress denies `xmlrpc.php`.
- `roundcube-auth` (`nixos/apps/mail.nix`): 5 failed logins to Roundcube in an hour, as it logs them, which also limits
  failed logins to 3 a minute from an address.
- keycloak locks a user out after failed logins (`bruteForceProtected`), and `keycloak-<app>`
  (`nixos/apps/keycloak.nix`) bans an address after 5 wrong passwords, names that aren't a user's, or tries at a locked
  user in an hour, at a login or a reset of a password, as Keycloak logs them, a missing cookie or an expired code not
  counted. Keycloak reads the client's address from `X-Forwarded-For`, which nginx sets to the client's address alone,
  so that a client can't name another to be banned. `vmTests.keycloak` logs in wrong from `mx`, naming another address,
  and finds `mx` banned.
- Nextcloud throttles failed logins itself.
- `mobilizon-<app>` (`nixos/apps/mobilizon.nix`): 10 names tried in an hour, GETs for a profile, `/@<name>` and what's
  under it, or for a webfinger, that mobilizon answers as not found, as nginx logs them; `eval-fail2ban-mobilizon`
  checks the filter as `eval-fail2ban-wordpress` does. A failed login is a GraphQL answer to a POST to `/api` like any
  other, so nothing jails it.
- the django apps and jitsi have no jail.

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
- coolwsd on loopback, at a port of each drive's (`nixos/apps/drive.nix`), which serves that drive's `url` alone.
- prosody on loopback (`nixos/apps/jitsi.nix`), for jicofo, the videobridge and nginx.
- keycloak's cache is local (`nixos/apps/keycloak.nix`), with no cluster to listen for.
- mobilizon runs without Erlang distribution (`nixos/apps/mobilizon.nix`), so neither epmd nor a node listens; it stops
  on SIGTERM, and `mobilizon_ctl` evaluates its commands rather than calling the node.
- nginx's exporter on `127.0.0.1` (`nixos/nginx.nix`).
- nix-serve, each vLLM server and the vLLM report on loopback, for `o11n.vpnProxies` to pass on.
- a vLLM container talks over loopback alone (`nixos/services/vllm.nix`), so its engine's store, on a port of its own
  choosing and every address, answers no one else.
- a `hypr-devstation`'s MariaDB on `127.0.0.1` (`roles/hypr-devstation.nix`).
- resolved answers neither LLMNR nor mDNS (`nixos/org/networking.nix`).

## Reading the logs

A host with the `logs` service (`nixos/services/logs.nix`) lets the service in with its ssh-key to run the summary
`o11n logs` reads (`docs/parts/o11n.md`), and nothing else: no shell, tty or forwarding. The service reads the journal
as a member of `systemd-journal`, and nginx's logs by an ACL, without root. Each keeps 14 days, fewer if it outgrows its
share of `/var` (`docs/parts/state.md`).

A container's journal goes with it. mobilizon logs its warnings and errors alone, to its container's console too
(`nixos/apps/mobilizon.nix`), which the host keeps as `container@<app>`'s, and the summary lists them by kind;
`vmTests.mobilizon` has one fail on a request and checks that its error reaches the host and its routine doesn't.
