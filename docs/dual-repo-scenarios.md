# Dual-repo scenarios

An org pins o11n in its `flake.lock`. What a branch develops decides how that pin moves while it's developed, and how it
lands.

## The pieces

- The agent's side, `./dev/agent.sh`, o11n's in both clones (AGENTS.md, "Workflow"): at the end of each turn, what the
  turn changed in a clone is written, stamped against the commit the turn started at, committed and pushed; at a
  hand-over, the same and then the checks. It sees to o11n first and then to the org beside it, whose `./write.sh` pins
  o11n to what o11n just pushed. In a session with the org alone, the org's `dev/agent.sh` runs that of the o11n it
  pins.
- A session's first prompt names a commit of each clone it's to work on, `At <o11n revision> <org revision>`. A clone it
  names none of is left as it is for the session, and o11n then pinned by nothing.
- The operator's side, from each clone's devShell, with `O11N_DEV` in a `.env` git ignores: `./dev/operator.sh` in o11n,
  `operator` in the org.
  - `fetch` switches to the branch, brings it up to its tip on origin, and says what's pending.
  - `stamp`, once nothing is pending, commits all as "stamp", pushes, and prints the revision the next session starts
    at.
  - `merge`, once nothing is pending and `stages.eval` builds, squashes the branch onto main, pushes main and deletes
    the branch. It refuses an org whose `flake.lock` pins o11n to a commit that isn't on o11n's main.
  - `check-org`, in o11n with `ORG` in its `.env`, builds the org's `eval` stage with o11n's tree as its o11n. Nothing
    else runs it.
- The org's `./write.sh`, with `O11N` set to an o11n clone, pins o11n to that clone's HEAD.

## 1. Just o11n

For what needn't reach a real host while it's developed.

The branch is in o11n alone, and the first prompt names o11n's commit alone. The org isn't touched, and its pin stays on
a commit of o11n's main.

Between units of work, the agent hands over on o11n's branch. In o11n, the operator fetches, stamps, and runs `stamp`
for the revision the next session starts at. o11n's stages, `vm` included, test the work, and `check-org` shows whether
the org still evaluates against it.

Afterwards, `merge` in o11n. The org takes it later as a unit of work of scenario 2, `nix flake update o11n`.

## 2. Just org

The branch is in the org alone, and the first prompt names the org's commit alone. Its pin stays on the same commit of
o11n's main throughout, unless a unit of work is to take a newer one, with `nix flake update o11n`.

Between units of work, the agent hands over on the org's branch; in a session the org's checks evaluate with its stubs.
In the org, the operator fetches, stamps, and runs `stamp`. A deploy from the branch deploys what was tested, o11n
included.

Afterwards, `merge` in the org, whose pin is on o11n's main.

## 3. Org and o11n

The branch has the same name in both, by convention: the tools don't rely on it.

The first prompt names a commit of each. At the end of every turn, o11n's turn-end pushes first, and the org's then pins
o11n to the commit just pushed, so the org's branch always pins the o11n its work was done against, an "update o11n"
commit alone when only o11n changed.

The operator's stamp commit in o11n leaves the pin where it is: it changes docs alone, and hosts don't carry o11n's
tree, so the systems the org pins are the same.

Between units of work, the operator fetches, stamps and runs `stamp` in o11n, then in the org, and starts the next
session `At` the two revisions. A deploy from the org's branch deploys the o11n commit it pins, which is what was
tested.

Afterwards, in this order, since o11n's branch commits go with its squash:

1. `merge` in o11n, which prints o11n's new main revision.
2. In the org, on its branch, with o11n's clone on that main: `O11N=<o11n clone> ./write.sh`, commit "update o11n",
   push.
3. `merge` in the org. It refuses until 2 is done.

## Open

- That a session with both clones reads the hooks its setup script writes above them (`dev/README.md`) is to be seen in
  the first such session.
