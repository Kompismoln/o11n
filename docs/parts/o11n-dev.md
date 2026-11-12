# o11n-dev

```sh
o11n-dev files [--unheld] <pattern>...   # NUL-separated
o11n-dev stamps check [dir] | pending [dir] | applied <doc> | write <commit> [--check]
o11n-dev base                            # the commit to stamp against
o11n-dev main                            # the main branch settings.toml names
o11n-dev hook <hook> refuse|tell         # the stages settings.toml has a hook refuse work for or tell of
o11n-dev parts check
o11n-dev refs check
o11n-dev index write | check
o11n-dev systems check [-- <nix argument>...]
o11n-dev systems compare <rev> <rev> <host>... [-- <nix argument>...]
o11n-dev costs write | show              # fold dev/check.sh's times into dev/costs.tsv and the docs | the medians
```

Each flags on stderr as `flag: ...`, and fails if it flags any.

## Systems

`systems` reads the org whose clone `ORG` names, with the clone's tree as its o11n, passing the nix arguments to each
evaluation, as an org's stub overrides (`crates/o11n-dev/src/systems.rs`):

- `check` builds the org's `eval` stage.
- `compare` evaluates each host's `toplevel.drvPath` at both revisions with `o11n.source.enable` off, the one place
  o11n's tree enters a system (`nixos/org/nix.nix`), so that equal paths are systems equal in all they're built from,
  says `<host> same` or `<host> differs: <old> <new>`, and fails when one differs. A revision from before
  `o11n.source.enable` doesn't evaluate.

## Packaging

- `crates/o11n-dev` has a workspace and `Cargo.lock` of its own, and `packages/o11n.nix` takes `crates/o11n` alone, so
  that a change to o11n-dev, or a dependency it adds, leaves `o11n` as it is: its `.drv` path is the same as before the
  crate. Verified.
- `packages/o11n-dev.nix` is in the runtimeInputs of `write` in `packages/dev.nix`, and so of `check`, `agent`,
  `operator` and the dev shell, and in the inputs of every stage of `tests/source.nix`.
- Bootstrap: in the sandbox, the stages build o11n-dev from the tree they check. Elsewhere, o11n-dev builds the o11n-dev
  of the clone `O11N_ROOT` names with `cargo build` when called, and runs that, so that a session's hooks don't run the
  one session-start built, and fails for an `O11N_ROOT` without the crate. The name follows `O11N_ORG_ROOT`; `O11N_DEV`
  names the operator's entity for `dev/operator.sh`.
- Dependencies: clap, regex, serde_json and toml. git runs as a command, as the scripts ran it, rather than through a
  library, so that what git ignores and how it detects renames stay git's; so do diff, prettier and nix.
