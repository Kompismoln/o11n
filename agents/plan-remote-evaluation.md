# Plan: evaluate an org's hosts on pelle

## The note

Evaluation of all hosts should not happen in cloud containers. The process belongs on a host that may happen to need
the builds anyway, like pelle. Agents should run them there instead, and say what they need for that to be possible.

## Take

- Measured in a session: Kompismoln/org's `stages.systems`, every host's system evaluated whole in one process, peaks at
  ~11 GB and takes ~3.5 minutes. With the standalone `homeConfigurations` added it was killed at 14 GB in the session's
  16 GB. `nix flake check` only sees that each host's system is a derivation, so it stays cheap. No script runs
  `stages.systems`, and AGENTS.md says not to run it in a session.
- The remote builder doesn't cover it as it is. Nix's daemon protocol has no operation for evaluating, so
  `nix-remote.sh build` evaluates in the session and only builds on pelle. Evaluating on pelle means running `nix`
  there: a command, not a store operation.
- Proposal: an evaluation endpoint next to the build one. `nixos/org/remote-builder.nix` gets a second path,
  `/nix-eval/`, behind the same bearer token, which gost tunnels to a socket-activated service on pelle with one thing
  to do: given an org revision, an o11n revision and a stage, fetch both from GitHub and run
  `nix build github:<org>/<rev>#stages.<stage> --override-input o11n github:<o11n>/<rev>`, streaming the log back.
  `nix-remote.sh eval <stage>` would be the session's side, with the revisions it has just pushed. Only revisions and
  a stage name cross, so a session can't run anything else on pelle.
- What it takes from you:
  1. A go on the design. The simpler alternative needs nothing new: you run `nix build .#stages.systems` on pelle
     after `fetch.sh`, and relay what fails.
  2. Read access for the evaluating user on pelle to the org's private inputs (sverigesval, chatddx and swift, over
     ssh): a deploy key or a machine user. `nix-remote`, the untrusted user the builds run as, has none.
  3. Room on pelle for ~11 GB next to what it runs, or evaluating the hosts in separate processes there.
  4. A deploy of pelle and helsinki once the module and a VM test of it exist.
- Considered and dropped: evaluating inside a build on pelle with recursive-nix. It needs an experimental daemon feature
  and the network inside the sandbox to fetch the org's inputs.
