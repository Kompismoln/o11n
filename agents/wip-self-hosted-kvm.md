# WIP: CI with KVM

Status: an option, not decided. Nothing built. Facts are marked
"Verified" (read in the pinned nixpkgs or observed in a session) or
"Unverified" (to check before relying on them).

## In short
- NixOS VM tests (`pkgs.testers.runNixOSTest`) need `/dev/kvm` to run at a
  usable speed. Claude's cloud sessions have none; neither have o11n's,
  the org's or chatddx's repositories any CI.
- Recommended shape: GitHub Actions jobs on a self-hosted runner, on a
  host of the org that has KVM, configured by o11n as a role
  (`ci-runner`) from data in the org (`org.toml`), with its credential in
  sops.
- GitHub Actions rather than another CI, because a Claude session can
  then dispatch a run and read its logs through the GitHub tools it
  already has, with no network access to the org's hosts.

## Why

What a VM test catches that evaluation, unit tests and running the code
on a host without systemd can't (seen on chatddx's module,
`chatddx-remastered/nix/test.nix`):

- systemd at boot: ordering, a failed dependency taking its dependents
  down, restarts;
- NixOS activation: users declared in two places merged, homes and their
  modes, tmpfiles (a `Z` refused as an "unsafe path transition" from a
  user's home to a file of root's);
- `services.postgresql.ensureUsers` and `ensureDBOwnership` against a real
  cluster, peer authentication of system users;
- the services' sandboxing (`ProtectSystem=strict`, `SystemCallFilter`,
  `RestrictAddressFamilies`, `UMask`, ...) not breaking them;
- real nginx in front: TLS, headers, rate limits, proxying to an IPv6
  loopback address.

o11n has VM tests of its own (`tests/nixos/keycloak.nix`,
`tests/nixos/vllm.nix`) that AGENTS.md says can't run in a session.

### By emulation, in a session (verified)

QEMU falls back to TCG without `/dev/kvm`. On a 4-vCPU cloud session:

- A boot took 208 s once and over 300 s on another day. The test driver
  waits 300 s for the guest's shell (ten times 30 s, hard-coded in
  `test_driver/machine/__init__.py:connect`), and fails beyond.
- initdb outlasted `postgresql.service`'s `TimeoutSec = 120` (nixpkgs'
  default), and the units that require it failed on the dependency
  without being started again.
- A whole run took 20–30 minutes when it passed, with nothing else heavy
  beside it.

Workarounds exist (a test script that retries the shell's wait, run by the
driver outside the Nix sandbox; longer timeouts in the test), each
specific to emulation and none making a run cheap.

### From a session to an org host directly (verified: not possible)

The session's outbound traffic goes through an HTTPS proxy that doesn't
carry raw TCP, so no SSH to a host, so no remote builder
(`--store ssh-ng://...`, `--builders`) from a session.

## Hosts with KVM

From each host's `facter.json` (Kompismoln's org, as of this writing):

| Host | CPU | Virtualisation | Memory | Roles of note |
|---|---|---|---|---|
| stationary | 4 cores, vmx | bare metal | 8 GiB | build host, substituter, app-scheduler (dev apps) |
| pelle | Ryzen 7 5700G, 8c/16t, svm | bare metal | 48 GiB | build host, substituter, inference-server |
| malborg | Ryzen 7 9800X3D, 8c/16t, svm | bare metal | 60 GiB | inference-server |
| helsinki | no vmx/svm exposed | a KVM guest | | webserver; no nested virtualisation |

pelle fits best: a build host already (`org.build-hosts`), with the memory
for several VMs; vLLM uses its GPU, VM tests its CPU. stationary is small
and runs the dev apps.

## Options

### 1. Self-hosted GitHub Actions runner on an org host (recommended)

- NixOS has `services.github-runners.<name>` (verified, pinned nixpkgs,
  `nixos/modules/services/continuous-integration/github-runner/`):
  - auth by `tokenFile` (a fine-grained PAT with read/write on
    "self-hosted runners", or a registration token, which expires after
    an hour) or by `githubApp` (`id`, `login`, `privateKeyFile`): on each
    start it derives a short-lived installation token, then a registration
    token. No long-lived PAT on the host.
  - `orgs.<name>`: one entry serves several organisations (or
    repositories), one service per runner, `github-runner-<name>-<org>-<n>`;
    the App's `login` changes per org. The repositories here span three
    owners: `chatddx-administration`, `Kompismoln`, `ahbk`.
  - `ephemeral`: one job per registration, state wiped, re-registered.
  - `count`, `extraLabels` (e.g. `kvm`), `extraPackages` (the runner needs
    `nix` and `git` on PATH), `serviceOverrides`.
  - The service runs as a `DynamicUser` with `PrivateDevices`,
    `ProtectSystem=strict` and the like.
- KVM reaches the builds, not the runner: a job's `nix build` runs in the
  nix-daemon's sandbox as a build user. NixOS' default
  `nix.settings.system-features` include `kvm` and `nixos-test` (verified,
  `nixos/modules/config/nix.nix`). Nix gives a derivation that requires
  `kvm` the host's `/dev/kvm` in its sandbox, and systemd's udev rules make
  `/dev/kvm` 0666 (Unverified on Lix 2.95 and the hosts' systemd: check
  with a test run). The runner's own sandbox can stay as it is.
- The runner reaches GitHub over outbound HTTPS (long polling); nothing
  inbound, so a host behind NAT is fine.
- Self-hosted runners cost no Actions minutes.
- A workflow per repository, e.g. chatddx's:

  ```yaml
  on:
    push:
    workflow_dispatch:
  jobs:
    module:
      runs-on: [self-hosted, kvm]
      steps:
        - uses: actions/checkout@v4
        - run: nix build -L .#checks.x86_64-linux.module .#checks.x86_64-linux.module-eval
  ```

  `workflow_dispatch` lets a Claude session start a run
  (`actions_run_trigger`) and read it (`actions_get`, `get_job_logs`); a
  session subscribed to a pull request gets check results as events.

### 2. GitHub-hosted runners

- Unverified: GitHub's hosted Linux runners expose `/dev/kvm`; the Nix
  community's workflows add a udev rule
  (`KERNEL=="kvm", GROUP="kvm", MODE="0666"`) and run NixOS tests on
  `ubuntu-latest`. Whether a private repository's standard runner has it,
  on the owners' plans, is to be checked with a one-step workflow
  (`ls -l /dev/kvm`).
- Nix installed per job (`cachix/install-nix-action` or
  `DeterminateSystems/nix-installer-action`), `system-features` with
  `kvm nixos-test` in its config.
- Private repositories spend the owner's Actions minutes. Each run builds
  from cache.nixos.org and PyPI, not from the org's substituters, which
  aren't reachable from GitHub (Unverified).
- Nothing to run or patch on the org's hosts.

### 3. GitHub-hosted runner with an org host as remote builder

- The job evaluates and sends the build to a host with KVM:
  `nix build --eval-store auto --store ssh-ng://nix-build@<host> ...`, as
  `agents/wip-nixservice.md` plans for the operator (ForceCommand
  `nix-daemon --stdio`, an untrusted user that can build).
- Needs the host's sshd reachable from GitHub's runners, and the
  `nix-build` key in the repository's secrets. Whoever can run a
  workflow can then build on the host.
- Only after wip-nixservice's change; until then `nix-build`'s
  ForceCommand runs nixservice, which this doesn't fit.

### 4. Other CI on an org host

All in nixpkgs (verified: `nixos/modules/services/continuous-integration/`
has hydra, buildbot, hercules-ci-agent, forgejo-runner, gitea-actions-runner,
woodpecker, ...):

- Hydra: flake jobsets; no GitHub statuses without its plugin; its web UI
  needs exposing.
- buildbot-nix (nix-community, a flake, not in nixpkgs): evaluates every
  flake check (nix-eval-jobs), reports statuses through a GitHub App; needs
  a public URL for webhooks (helsinki could front it).
- hercules-ci-agent: the agent on the host, the dashboard at
  hercules-ci.com (a paid service for private repositories, Unverified).

Their logs live in their own web UI, which a Claude session reads only if
it is reachable over HTTPS on 443 and allowed by the session's network
policy. With GitHub Actions the logs stay in GitHub.

## Target shape in o11n (for option 1)

- `[service.github-runner]` in `org.toml`, with an `id` (a user; or none,
  with the module's `DynamicUser`) and its credential in sops: the GitHub
  App's private key or a fine-grained PAT. `org/classes.nix` has no key
  type for either; `secret-key` would do, or a new `github-app-key`.
- `[role.ci-runner] services = ["github-runner"]`, and a host's
  `roles = [..., "ci-runner"]`.
- `nixos/org/github-runner.nix`, imported by `roles/ci-runner.nix`:
  `services.github-runners.<name>` from the org: the App's `id`, the
  owners (`orgs`), `count`, `ephemeral = true`, `extraLabels = [ "kvm" ]`,
  `extraPackages = [ config.nix.package pkgs.git ]`, the key from
  `sops.secrets` with `restartUnits`. No org names in o11n: owners and
  repositories come from `org.toml` (where, e.g. `[ci]` or the service's
  own settings, is open).
- An assertion that a host with the role has `kvm` among
  `nix.settings.system-features`.

### Private inputs

The org's flake has `git+ssh://git@github.com/...` inputs (sverigesval,
the chatddx repositories, swift-dx-guide). A job evaluating the org needs
read access to them: an installation token of a GitHub App installed on
those repositories, with git's `url."https://x-access-token:<token>@github.com/".insteadOf
"ssh://git@github.com/"` for the job (`actions/create-github-app-token`
makes the token). Deploy keys are per repository and can't be shared.
chatddx-remastered's inputs are all public GitHub repositories.

## Security

- A job runs whatever its workflow says, as the runner's user, on the
  host. Self-hosted runners only for private repositories, or with
  workflows from forks disabled; GitHub's own advice is never to attach
  them to public repositories' pull requests. o11n's visibility decides
  whether it gets a runner.
- `ephemeral` runners, so a job leaves nothing for the next.
- Builds go through the host's nix-daemon as an untrusted user: sandboxed,
  no `--option` that loosens it. Their outputs land in the host's store,
  which nix-serve signs and serves to every peer. An output is only ever
  the one of its derivation, so a peer fetches it only if its own closure
  refers to that derivation; still, a host that is a substituter now also
  holds whatever the CI built.
- The credential (App key or PAT) can register runners for its scope:
  keep it to the repositories' owners and the "self-hosted runners"
  permission.

## Tests (in tests/inventories)

- `principals` or `sample`: a host with the role gets
  `github-runner-*` services, the label `kvm`, `nix` on their PATH, the
  secret from the service's sops file, and `kvm` among the system
  features; a host without it gets none.
- The leak check keeps any org name out of the new code.
- With KVM, nothing here can run the runner itself: it needs GitHub.

## Open

- Which host: pelle, as recommended, or stationary (both build hosts).
- GitHub App (recommended: short-lived tokens, one App across the three
  owners) or a fine-grained PAT per owner.
- Where in `org.toml` the owners and repositories are named.
- Which repositories, and on what events: chatddx-remastered's
  `checks.x86_64-linux.module`, o11n's `nix flake check` with its VM tests,
  the org's `nix flake check` (needs the private inputs).
- Whether GitHub-hosted runners (option 2) are enough after all, checked
  with one workflow before anything is built here.
