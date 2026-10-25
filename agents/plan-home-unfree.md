# Plan: standalone homeConfigurations with the role's unfree allowance

## The note

homeConfigurations are cheaper than nixosConfigurations, and being able to evaluate them separately is neat. Put the
predicate in the role.

## Take

- Today Kompismoln/org's `homeConfigurations."ami@adele"` and `"ami@henrik"` don't evaluate. `home/office.nix`, which
  the cinnamon-office role imports, installs `zoom-us`. The role's NixOS module allows `zoom` with
  `nixpkgs.config.allowUnfreePredicate`, and a host's homes get that through home-manager's `useGlobalPkgs`, so the
  hosts evaluate. `mkHomeConfigurations` in `lib/default.nix` imports nixpkgs with no config for the standalone ones.
- Proposal: the role holds the list once and applies it on both sides.

  ```nix
  let
    unfree = [ "zoom" ];
  in
  {
    flake.homeModules.cinnamon-office =
      { lib, osConfig ? null, ... }:
      {
        nixpkgs.config = lib.mkIf (osConfig == null) {
          allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) unfree;
        };
      };
    flake.nixosModules.cinnamon-office =
      { lib, ... }:
      {
        nixpkgs.config.allowUnfreePredicate = pkg: lib.elem (lib.getName pkg) unfree;
      };
  }
  ```

  The `mkIf` because home-manager refuses `nixpkgs.*` under `useGlobalPkgs`, which hosts use. A standalone home then
  gets a nixpkgs of its own with that config, at the cost of a second import.
- `allowUnfreePredicate` is one function, so two roles that each set it conflict on a host with both: inference-server
  sets one too. A list option, say `o11n.unfree`, that roles add names to and o11n turns into the one predicate, on
  both sides, avoids that. It's the same idea, a step further.
- Then an `eval` check that every inventory home's `activationPackage` evaluates, with a home that has the
  cinnamon-office role in the sample inventory. Homes are cheap enough for that to run in a session, unlike whole
  systems.
