# Dual-repo scenarios

An org pins o11n in its `flake.lock`. What a branch develops decides how that pin moves while it's developed, and how
it lands.

## The pieces

- An agent's handover, in each repo it changed: `nix flake check`, commit, `nix run .#write-stamps`, commit, push
  (AGENTS.md, "Workflow"). At the end of each of its turns, the repo's Stop hook already asks it for the stamps of
  what changed in the docs, so its work arrives stamped.
- The human's side, from each repo's devShell, with `O11N_DEV` in a `.env` git ignores:
  - `fetch.sh` pulls the branch and builds `stages.baseline`, which flags the stamps pending.
  - `write-stamps` writes them for what changed since their own latest commit, for work pushed without a handover.
  - `stamp.sh`, once they're stamped, builds the baseline, commits all as "stamp", even with nothing changed when the
    latest commit isn't theirs, pushes, and prints the revision the next session starts at.
  - `merge.sh` builds the baseline, squashes the branch onto main, pushes main and deletes the branch. It refuses an
    org whose `flake.lock` pins o11n to a commit that isn't on o11n's main.
- `check-org.sh`, from o11n's devShell with `ORG` in its `.env`, builds the org's `eval` stage with o11n's tree as its
  o11n. Nothing else runs it.

## 1. Just o11n

For what needn't reach a real host while it's developed.

The branch is in o11n alone. The org isn't touched, and its pin stays on a commit of o11n's main.

Between units of work, an agent hands over on o11n's branch. In o11n, the human runs `fetch.sh`, stamps, and runs
`stamp.sh` for the revision the next session starts at. o11n's stages, `vm` included, test the work, and `check-org.sh`
shows whether the org still evaluates against it.

Afterwards, `merge.sh` in o11n. The org takes it later as a unit of work of scenario 2, `nix flake update o11n`.

## 2. Just org

The branch is in the org alone. Its pin stays on the same commit of o11n's main throughout, unless a unit of work is to
take a newer one, with `nix flake update o11n`.

Between units of work, an agent hands over on the org's branch; in a session the org's checks need its stubs
(`tests/stubs/with-stubs.sh nix flake check`). In the org, the human runs `fetch.sh`, stamps, and runs `stamp.sh`. A
deploy from the branch deploys what was tested, o11n included.

Afterwards, `merge.sh` in the org, whose pin is on o11n's main.

## 3. Org and o11n

The branch has the same name in both, by convention: the scripts don't rely on it.

The org is handed over with its intended pin, the o11n commit of the same handover, after every unit of work. So o11n
is handed over first, then the org is pinned to the commit just pushed, then it's handed over:

- the org changed and o11n didn't: there's nothing to pin anew
- o11n changed and the org didn't: the org's handover is an "update o11n" commit alone
- both changed: the org's handover is that commit and its own

A human's stamp commit in o11n leaves the pin where it is: it changes docs alone, and hosts don't carry o11n's tree, so
the systems the org pins are the same.

Between units of work, the human runs `fetch.sh`, stamps and `stamp.sh` in o11n, then in the org. A deploy from the
org's branch deploys the o11n commit it pins, which is what was tested.

Afterwards, in this order, since o11n's branch commits go with its squash:

1. `merge.sh` in o11n, which prints o11n's new main revision.
2. In the org, on its branch: `nix flake lock --override-input o11n github:Kompismoln/o11n/<revision>`, commit
   "update o11n", push.
3. `merge.sh` in the org. It refuses until 2 is done.

## Open

- Pinning the org is done by hand, at an agent's handover and in step 2 above. In a session, which can't download
  GitHub archives, the agent computes the lock's `narHash` from the commit's tree with `git archive` and
  `nix hash path`. A script for it would serve both.
