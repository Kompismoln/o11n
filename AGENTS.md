# AGENTS.md

Notes for anyone, human or agent, changing o11n.

o11n is a library. An org, such as Kompismoln/org, describes itself in `org.toml`
and calls `o11n.fromFlake self` to get its NixOS, home-manager and disko
configurations. o11n has no org of its own, so it is tested against small orgs in
`tests/inventories/`. An org's own expectations live in that org's checks, not here.

## Checks

`nix flake check` runs everything in about half a minute. Checks are found from
the layout of `tests/`; nothing lists them by hand.

| File | Check | Arguments it can ask for |
| --- | --- | --- |
| `tests/nixos/<module>.nix` | `nixos-<module>` | `pkgs`, `lib`, `evalNixosModule` |
| `tests/inventories/<name>/tests.nix` | `inventory-<name>` | the above and `outputs` |
| each NixOS host of an inventory | `inventory-<name>-<host>` | |

- A test file returns an attrset of `test_* = { expr; expected; }` and asks only
  for the arguments it uses. `outputs` is what `fromInventory` makes of the
  inventory: `org` and the NixOS, home and disko configurations.
- A failing check prints each failing test's name, expected value and result.
- `inventory-<name>-<host>` evaluates the host's whole system without building it,
  then walks every derivation and input source the system is built from
  (`tests/leaks.py`) and fails on names from the org o11n was first written for
  (`leakPatterns` in `tests/default.nix`).
- Only code an inventory uses is checked. A role or module that no inventory
  uses can be broken without any check noticing.
- Tests run during evaluation. Passing checks all resolve to the same empty
  file, so `nix flake check` reports few checks as run. A test whose expression
  throws takes its whole check down rather than failing alone.

## Inventories

- `base`: an org with nothing in it.
- `principals`: one host with the inference-server and app-scheduler roles.
- `sample`: a cluster meant to use every role. It has `gw` (wg0 gateway and DNS,
  rescue mode, grub) and `web`, both with the nixos, peer and server roles, and
  an admin user. Grow it rather than adding inventories, unless a case can't
  live alongside the rest.

Evaluate inventories with `o11nLib.fromInventory { path; inputs ? { }; }`, not
`fromPath`. `fromPath` reads the directory with `getFlake`, which pure
evaluation refuses, and leaves the org's files as Nix paths. A real org, read
with `fromFlake`, gives store path strings, and options typed as strings, such
as root's `hashedPasswordFile`, reject Nix paths.

### Keys and secrets in `sample`

They are real, made by `generate-keys.sh` with the org tooling in `tools/bin`.

- `keys/root-1` is a committed throwaway root identity. With
  `SOPS_AGE_KEY_FILE=keys/root-1`, `sops decrypt enc/<file>` shows any secret.
- To add an entity, declare it in `org.toml`, then from the inventory directory
  run `id-entities.sh -<class> <name> init` and `id-entities.sh -<class> <name> new <key>`
  for each key the configuration reads, as `generate-keys.sh` does. Create hosts
  before what is granted to them: they have to exist to be recipients.
- The tools need age, jq, mkpasswd, nix, openssl, sops, ssh-keygen, toml2json,
  wg and envsubst on PATH. `nix build .#nixpkgs.legacyPackages.x86_64-linux.<package>`
  gives each from o11n's own nixpkgs.
- In tests, compare with the files on disk (`builtins.readFile ./public-keys/...`)
  rather than with values computed by the same o11n code that is under test.

## What o11n assumes of an org

- A table for every entity class, even when empty (`[app]`, `[store]`, ...).
  Without one, evaluation fails deep in `org/types.nix` and `org-toml.sh`
  queries fail.
- `[mailserver]` when any host has the server role: `nixos/org/sendmail.nix`
  reads it.
- `[flake]` when any host has the peer role: `nixos/org/nix.nix` reads it.
- An `endpoint` on the gateway of each vpn.
- For each NixOS host, a `facter.json` (`{"version":1,"system":"x86_64-linux"}`
  is enough in tests), a root file system, and a way for root or a wheel user to
  log in; NixOS rejects a system without them.
- Services without an `id` get no user, but their public keys can still be read
  (rescue, nix-serve).

## o11n must not know its orgs

No org names, hosts, domains or namespaces in o11n: take them from `org`, or from
`org.toml` in the tools. The host checks enforce this for code the inventories
use. The remaining hardcoding is in modules that no role imports:
`nixos/org/monitor.nix`, `nixos/monitor-node.nix`, `nixos/backup.nix` and
`nixos/glesys-updaterecord.nix`.

## Deploying: where it is going

nixservice is being retired. Agreed so far:

- Building: `nix-build`'s ForceCommand becomes `nix-daemon --stdio`, and the
  operator runs `nix build --eval-store auto --store ssh-ng://nix-build@<build-host> ...`.
  The operator's machine evaluates, the build host builds and keeps the result.
  On Lix 2.95.2, an untrusted user connecting this way can upload sources and
  `.drv` files and have them built, but can't import unsigned outputs.
- Distribution: every host substitutes from the hosts with the substituter
  role, signed with the nix-serve key; `pull` goes away.
- Switching: `nix-switch` keeps a narrow root command: realise the path, set the
  system profile, run `switch-to-configuration`.
- `org.build-hosts` is where the operator builds; each must have the substituter
  role.

## Working in a Claude Code cloud sandbox

- Downloads of GitHub archives, which `github:` inputs use, are refused with
  HTTP 403; git over https works. Fetch the same revisions over git once, and
  plain `nix` commands work for the rest of the session, because the inputs are
  then in the store under the same content hash:

  ```sh
  python3 - flake.lock /tmp/flake.git.lock <<'EOF'
  import json, sys
  lock = json.load(open(sys.argv[1]))
  for node in lock["nodes"].values():
      locked = node.get("locked", {})
      if locked.get("type") == "github":
          node["locked"] = {
              "type": "git",
              "url": f"https://github.com/{locked['owner']}/{locked['repo']}",
              "rev": locked["rev"],
              "narHash": locked["narHash"],
              "lastModified": locked["lastModified"],
              "shallow": True,
          }
  json.dump(lock, open(sys.argv[2], "w"))
  EOF
  nix flake archive --reference-lock-file /tmp/flake.git.lock --no-write-lock-file
  ```

- The clone is shallow. When referring to it as `git+file://`, for example to
  check a single commit, add `shallow=1`:
  `nix flake check "git+file://$PWD?rev=$(git rev-parse HEAD)&shallow=1"`.
- There is no `/dev/kvm`, so NixOS VM tests can't run.
- An org's private `git+ssh` inputs can't be fetched. Override them with stub
  flakes (`--override-input <input> path:<stub>`) that have the attributes the
  org reads.
- Nix runs in single-user mode on this session's `/nix`. Point any other daemon,
  such as Lix's, at its own store with `NIX_REMOTE="local?root=<dir>"`
  (Lix's `nix-daemon` ignored `--store`).
- `pkill -f <pattern>` can match the command line of the shell running it.
  Kill by PID.

## Nix pitfalls met here

- `builtins.pathExists drv.outPath` builds the derivation during evaluation.
- `exportReferencesGraph` on a `.drv` also requires every output it refers to,
  so it can't read a build plan without building it; read the `.drv` files
  instead, as `tests/leaks.py` does.
- When searching store contents for short names, match whole words: store
  hashes can contain them (`ahbk` is valid base32).
- `nix flake check` stops at the first error; `--keep-going` shows them all.

## Style

- Format Nix with nixfmt and lint it with statix and deadnix. statix has
  existing warnings in `nixos/`; keep new code free of them. Shell scripts in
  `tools/` pass shellcheck (the km-tools package runs it on `bin/` and `libexec/`).
- Commits: `<area>: <what changed>`, lowercase, with a body that says why.
  Each commit passes the checks on its own.
- `tools/` is also copied into Kompismoln/org, and the copies have drifted.
  Hosts get o11n's copy through km-tools; operators run the org's copy.
