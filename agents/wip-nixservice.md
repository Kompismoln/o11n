# WIP: retire nixservice

Status: all three stages done; evaluation then moved to the build host (see
"Evaluation on the build host").

## In short
- Building: `nix-build`'s ForceCommand becomes `nix-daemon --stdio`, and the
  operator runs `nix build --eval-store auto --store ssh-ng://nix-build@<build-host> ...`.
  The operator's machine evaluates, the build host builds and keeps the result.
  On Lix 2.95.2, an untrusted user connecting this way can upload sources and
  `.drv` files and have them built, but can't import unsigned outputs; a whole
  system (the sample's `web`) built this way.
- Distribution: every host substitutes from the hosts with the substituter
  role, signed with the nix-serve key; `pull` goes away.
- Switching: `nix-switch` keeps a narrow root command: realise the path, set the
  system profile, run `switch-to-configuration`.
- `org.build-hosts` is where the operator builds; each must have the substituter
  role.

## Why

Deploying today (`tools/bin/apply.sh <target>`) goes through
`tools/remote/nixservice.sh`, run by sshd ForceCommands on every peer:

1. `build.sh`: as `nix-push`, copy the org's working tree to the build host;
   then as `nix-build`, `ssh -A nix-build@<build-host> build <target> <source>`.
   nixservice evaluates and builds there. `-A` forwards the operator's agent so
   the build host can fetch the org's private `git+ssh` inputs.
2. As `nix-build` on the target: `pull <path> http://<build-host>:5000`, a
   `nix copy` from the build host's nix-serve.
3. As `nix-switch` on the target: `sudo nixservice switch <path>`.

Problems:

- The ForceCommand doesn't restrict much. nixservice appends any arguments after
  `--` to `nix build` and accepts any flake reference as the source, so whoever
  holds the `nix-build` key can make a build host evaluate a flake of their
  choosing with options of their choosing (for example
  `--option allow-unsafe-native-code-during-evaluation true`): code running as
  `nix-build`, outside the build sandbox.
- `ssh -A` exposes the operator's agent to the build host for as long as a
  build runs.
- The `nix-build` key needs read access to the org's private repositories.
- Hand-written command parsing, defaults that went stale (`BUILD_HOST`,
  `REPO`; removed in 4af6633), and `rm -rf ~/.cache/nix/*` before every build.

## Target

Use Nix's own protocol wherever a Nix operation is all that's needed, and keep
one narrow command for the privileged step.

### nix-build: build over ssh-ng

- ForceCommand: `${config.nix.package}/bin/nix-daemon --stdio`. The connection
  reaches the system daemon as the untrusted user `nix-build`.
- Operator:
  `nix build --eval-store auto --store ssh-ng://nix-build@<build-host> .#nixosConfigurations.<target>.config.system.build.toplevel --no-link --print-out-paths`.
  The operator's machine evaluates, with its own credentials for private
  inputs; it uploads sources and `.drv` files; the build host builds and keeps
  the result.
- No agent forwarding, no working-tree copy, no GitHub access for the
  `nix-build` key, no `BUILD_WORKING_TREE`, no `src` output in the org flake.
- Cost: evaluation (10–30 s, 1–2 GB per host) moves to the operator. Accepted
  at first; see "Evaluation on the build host".

### Evaluation on the build host

- On hosts in `build-hosts`, `nix-build`'s ForceCommand also takes
  `build-system <flake store path> <host>`; anything else is the daemon. Other
  hosts give `nix-build` the daemon alone.
- `build.sh` sends the org's flake with `nix flake archive --to ssh-ng://...`:
  its source and every locked input, private ones too, all content-addressed,
  which the untrusted daemon accepts. Then `build-system` runs a pure
  `nix build path:<store path>#nixosConfigurations.<host>...toplevel`, no other
  options; the inputs are in the store already, so nothing is fetched.
- The build host still needs no access to the private repositories, and nothing
  is forwarded. What the key adds: having a build host evaluate any flake it was
  sent, purely, as `nix-build` (CPU, memory, eval-time fetches of locked URLs).
- A `path:` copy of a flake has no `rev`, and Lix gives it `lastModified` 0 and
  refuses another (`'lastModified' attribute mismatch`); Nix 2.34 takes either
  from the reference. Both reached systems only through `nix.registry.self`,
  which NixOS fills with a flake's `rev`, `lastModified` and `narHash`, so o11n
  registers `self` without the first two. Every host's system then depends on
  the org's tree alone: the same from a checkout, clean or dirty, and from its
  copy (all of Kompismoln's hosts, evaluated both ways, with Nix and Lix).

### Distribution: substituters from the org

- Every host substitutes from each other host with the `substituter` role,
  at `http://<host>.<namespace>:5000?priority=50`, signed with the nix-serve
  key every peer already trusts (`nixos/org/nix.nix`).
- The namespace is that of the first vpn the two hosts share, in the order of
  the consuming host's `vpns`. Hosts that share no vpn get no entry.
  `nixos/nginx.nix` hardcodes wg0 for the same question; one helper in `org`
  ("how host Y reaches host X") should serve both.
- `priority=50` keeps cache.nixos.org (40) first for public paths, so a host
  far away (helsinki) doesn't pull nixpkgs over wg from a home connection.
- Set `connect-timeout` (e.g. 5) and `fallback = true`, so an offline
  substituter costs seconds and falls back to building.
- `pull` goes away: the switch command realises the path, which substitutes.
- `org.build-hosts` keeps one job, on the operator's side: where to build.
  Every build host must have the substituter role, or targets can't fetch its
  builds. Enforce with a NixOS assertion in `nixos/org/nix.nix`.

### nix-switch: one narrow command

`switch-system <store-path | generation | nothing>`, run as root via sudo, with
the same arguments nixservice `switch` takes today:

- store path: `nix-store --realise <path> --option narinfo-cache-negative-ttl 0`,
  then `nix-env -p /nix/var/nix/profiles/system --set <path>`, then
  `<path>/bin/switch-to-configuration switch`. The negative TTL matters: a
  lookup made before the build finished is otherwise cached as "missing" for an
  hour.
- generation number: `--switch-generation`, then switch.
- nothing: list generations.

Refuse a path that isn't a NixOS system (no `bin/switch-to-configuration`).

### nix-push: unchanged

`nix-store --serve --write` as a trusted user. It's the only way to import
unsigned builds, used when the operator builds locally (`BUILD_HOST=localhost`)
and copies to the target.

## Tooling

- `tools/bin/build.sh`: the ssh-ng build above; for `localhost`, a local
  `nix build`. Check that `BUILD_HOST` is `localhost` or in `org.build-hosts`;
  default to the first entry of `build-hosts`.
- `tools/bin/apply.sh`: build, then (localhost builds only) copy with
  `nix-push`, then switch. No `pull`, no `BUILD_HOST_ADDRESS:5000`.
- `tools/bin/switch.sh`: unchanged interface.
- Delete `tools/remote/nixservice.sh`. Add `switch-system` (in
  `tools/remote/` or as a `writeShellApplication` in `nixos/org/nix.nix`).
- The org runs its own copy of `tools/`, which has drifted from o11n's. Either
  apply the same changes there, or first let the org's devShell use o11n's
  km-tools (needs km-tools to `--set-default` rather than `--set` `REPO_ROOT`,
  so the operator's working tree can win).

## Tests (in tests/inventories/sample)

- Give `gw` the substituter role and make it the org's build host.
- Pin per host: each identity's sshd Match block and ForceCommand, the sudo
  rules for `nix-switch`, and the substituter list (`web` gets
  `http://gw.sample:5000?priority=50`; `gw` gets none of its own).
- The assertion fires when a build host lacks the substituter role.
- The leak check keeps any org name out of the new code.
- With KVM, `tests/vm/deploy.nix`: an operator, a build host and a target run
  the whole deploy: build over ssh-ng, switch, substitute.

## Rolling out to an existing org

nixservice is what makes a host deployable, so the alternative goes in next to
it before nixservice goes:

1. Hosts. `nix-build`'s ForceCommand dispatches: `build` and `pull`, the
   old tooling's commands, still go to nixservice; anything else, such as an
   ssh-ng client's `nix-daemon --stdio`, reaches the daemon. `nix-switch`
   runs `switch-system`, which takes what nixservice `switch` took, and
   realising an already valid path is a no-op. Hosts get the substituters.
   The old tooling works against hosts before and after, so they can be
   deployed with it in any order.
2. Tooling. The org's `build.sh` and `apply.sh` move to ssh-ng and
   substitution, and every host is deployed again with them. Against a host
   still on its old configuration they fail before anything switches: the
   build host's nixservice rejects `nix-daemon --stdio`, and an old target
   finds no substituter for the path.
3. Retire nixservice: the ForceCommand becomes `nix-daemon --stdio` alone,
   `tools/remote/nixservice.sh` and its package go, in o11n and in the org's
   copy of `tools/`.

If a step fails halfway, `remote.sh login` as admin and `nixos-rebuild switch
--rollback` on the affected host still work, independent of all this.

## Verified

On Lix 2.95.2 (the version pinned by o11n's nixpkgs), in a sandbox standing in
for a host: a Lix daemon, sshd with ForceCommand `nix-daemon --stdio`, and a
client evaluating in its own store.

- The connection is classified as untrusted.
- Sources (a file and a directory) and `.drv` files upload; the daemon
  substitutes from cache.nixos.org and builds; the result stays on the daemon
  side.
- A whole NixOS system (the sample's `web`) built this way: 285 derivations
  built by the daemon, the rest substituted.
- Copying an unsigned, non-content-addressed output is refused: "lacks a
  signature by a trusted key".

`tests/vm/deploy.nix` (`.#vmTests.deploy`), run on the remote builder (KVM)
from a session: an operator, `gw` as build host and substituter, `web` as
target, both on o11n's `nixos/org/nix.nix` with the sample org; `gw` runs
`nixos/org/nix-serve.nix`, its key decrypted by sops-nix with `keys/root-1`.

- ssh-ng as `nix-build` reaches the daemon untrusted; the operator evaluates,
  `gw` builds and keeps the result; an unsigned output is refused.
- `switch-system` realises from `http://gw.sample:5000` before it checks the
  path: a non-system is refused after it is fetched; web switched to a system
  only `gw` had (3 paths substituted), then back by generation number.
- Before stage 3, through the dispatcher: the old tooling's `pull` copied from
  nix-serve, and its `build` reached nixservice.
- km-tools' `apply.sh`, with the sample's keys: builds on the first build host
  and the target substitutes; `BUILD_HOST=localhost` builds on the operator and
  copies as `nix-push`; `build.sh` refuses a host not in `build-hosts`.

Pitfalls seen there:
- `ssh` in a test driver command needs `-n`: without it, the driver hung after
  the command had finished.
- Test VMs leave out `switch-to-configuration` unless
  `system.switch.enable = true`, and have no bootloader to install.
- `switch-to-configuration` reloads each user manager and exits 4 when one is
  stopping, as one does for 10 s after an ssh session ends.

## Open

- Should `switch-system` also accept a `boot` mode (set profile, activate on
  next boot)?
- The org's `[flake]` then only feeds the `o11n` registry entry on hosts;
  consider renaming it to say so.
