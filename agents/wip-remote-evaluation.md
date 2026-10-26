# WIP: evaluating an org's stages on the remote builder

Status: deployed in Kompismoln/org (pelle evaluates, helsinki relays), and tested in a VM (`vmTests.remote-eval`). Facts
are marked "Verified" (seen working) or "Unverified".

## In short

- Evaluating every host of an org doesn't belong in a session: Kompismoln/org's `stages.systems` peaked at ~11 GB and
  took ~3.5 minutes there, and with the standalone `homeConfigurations` it was killed at 14 GB of the session's 16 GB.
- `nix-remote.sh eval <stage> [o11n revision]`, from an org's clone, has the host with the remote-builder role evaluate
  and build that stage of the org at HEAD, with o11n at the revision given, and prints nix's output as it comes. Both
  revisions have to be pushed: the host fetches them itself.
- Only the stage and the revisions cross. The host fetches the org's flake from `[repository]` in its `org.toml`, and
  o11n from where the org's lock at that revision takes it, so a client can have it evaluate nothing but the org's
  stages. An org without `[repository]` has no `/nix-eval/`.

## How it works

```
nix-remote.sh eval --GET https://<endpoint>/nix-eval/<stage>/<org rev>[/<o11n rev>]-->
  [relay: nginx --wg--> ] nginx (TLS, the bearer, no buffering or compression)
  --> [bindAddress]:7338 (systemd socket, Accept=yes)
  --> nix-remote-eval@.service: nixos/org/nix-remote-eval.sh as nix-remote
  --> nix build <org at rev>#stages.<stage> [--override-input o11n <o11n at rev>], through the system daemon
```

- No gost: an evaluation is one request and a response that streams, which plain HTTP carries through the session's
  proxy, as it carries the PHT pull. The client needs curl alone, which o11n-tools now has.
- `nixos/org/remote-builder.nix` serves `/nix-eval/` next to `/nix-daemon/`, behind the same bearer, and the relay
  passes on both.
- `nix-remote-eval.sh` answers 400 with its usage to any other request, and 409 while another evaluation runs: one at a
  time, with a lock in its cache directory. Otherwise it streams nix's output, with a line every 30 s, because nginx
  closes a response that's silent for 60 s and evaluating is silent for minutes. A line it can't write means the client
  is gone, and it stops the build. Then comes the stage's output when it's a file, a report such as Kompismoln/org's
  `drvs`, which nix doesn't print again once it's built. The last line is `nix-remote-eval: exit <status>`, which
  `nix-remote.sh` exits with.
- With an o11n revision, it reads o11n's source from the org's lock at that revision (a `github` or `git` input) and
  overrides the input named `o11n`, as `check-org.sh` does.
- A `git` repository is fetched with all its refs (`allRefs=1`), for a revision on a branch: by revision alone, nix
  looks for it on the default branch.
- Private inputs, and a private org: when the org has `public-keys/service-nix-remote-ssh-key.pub`, git gets
  nix-remote's `ssh-key` secret, and takes a host's key the first time it sees it
  (`/var/cache/nix-remote-eval/known_hosts`) unless the system's known hosts have it already.
- It runs as nix-remote, untrusted, so the builds are sandboxed as `nix-remote.sh build`'s are, and the evaluation is
  pure: it reads nothing outside the store and what it fetches.

## Verified

In a VM (`vmTests.remote-eval`, Lix, built on pelle with `nix-remote.sh build`): the sample's gw with the
remote-builder module, its nginx and the sample's secrets, and an org flake in a repository on gw:

- A request without the bearer gets 401, and one that isn't for a stage and whole revisions gets 400 and the usage.
- A stage is built at the org's revision and its lock, with the private input fetched over ssh with nix-remote's key,
  the host's key taken the first time.
- `nix-remote.sh eval` with an o11n revision builds with o11n there and exits as nix did: a stage that fails, or that
  the org doesn't have, ends in `exit 1` with nix's error.
- A second evaluation while one runs gets 409. Stopping the first one's client stops its build, and the next one gets
  through.
- The org is private and served over ssh, and a revision on a branch other than its default is fetched too. Without
  `allRefs=1`, Lix fails: "Cannot find Git revision … in ref 'refs/heads/main'".
- A revision whose lock is incomplete fails with Lix's "cannot write modified lock file": the host evaluates what was
  pushed, locked. An o11n revision only makes nix warn that it doesn't write the lock.

Against pelle and helsinki, from a Claude session:

- The session's network secret for helsinki carries the bearer to `/nix-eval/` too: a request that isn't for a stage
  got pelle's 400 and usage.
- With `[repository]` as `github`, pelle's nix got 404 for the archive of Kompismoln/org, which is private: GitHub
  answers 404 to a download without a token. A private org is `git` over ssh with nix-remote's key.
- `nix-remote.sh eval systems`, at a revision on a branch: pelle fetched the org and its private inputs over ssh,
  evaluated every host's system and built the stage, in about three minutes. The lines every 30 s kept the response
  open through the proxy and both nginx.

## Unverified

- How long the session's proxy keeps a response open beyond the 3 minutes 20 seconds seen, with a line every 30 s.
- Room: nothing caps the evaluation's memory. `stages.systems` peaked at ~11 GB in a session.

## Setting it up in an org

- The remote-builder role on a host, and the remote-builder-relay role where clients need one (`wip-remote-builder.md`).
- `[repository]` in `org.toml`: the org's own flake, not `[flake]`, which is what the hosts' registry calls `o11n`. A
  public org can be `type = "github"`; a private one is `type = "git"` with
  `url = "ssh://git@github.com/<owner>/<repo>"`.
- For a private org or private inputs: `id-entities.sh -s nix-remote new ssh-key`, and its public half given read
  access to them. GitHub takes a deploy key for one repository only, so for several it's a machine user with the key.
- Room on the builder for the evaluation: Kompismoln/org's `stages.systems` peaked at ~11 GB in a session.

Then, from an org's clone: `<o11n clone>/tools/bin/nix-remote.sh eval systems [o11n revision]`.

## Considered

- The plan's gost tunnel to the service: HTTP does it with less.
- Running `nix build .#stages.systems` on pelle after `fetch.sh` and relaying what fails: needs nothing new, and still
  works.
- Evaluating inside a build on pelle with recursive-nix: it needs an experimental daemon feature and the network inside
  the sandbox to fetch the org's inputs.
