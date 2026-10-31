{
  description = "o11n nixos fleet manager";

  inputs = {
    nixpkgs.url = "github:Kompismoln/nixpkgs?rev=31ecbaca1bdefa45dffc409f0250bd8039ea0010";

    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";

    nixos-mailserver.url = "gitlab:ahbk/nixos-mailserver/relay";
    nixos-mailserver.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    preservation.url = "github:nix-community/preservation";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake
      {
        inherit inputs;
      }
      (
        { lib, ... }:
        let
          importDir = dir: (lib.mapAttrsToList (name: _: /${dir}/${name}) (builtins.readDir dir));

          o11nLib = import ./lib {
            inherit lib;
            o11nInputs = inputs;
          };
        in
        {
          systems = [ "x86_64-linux" ];

          imports = [ inputs.home-manager.flakeModules.home-manager ] ++ (importDir ./roles);

          _module.args.o11nLib = o11nLib;

          flake = {
            inherit (inputs) nixpkgs;
            inherit (o11nLib) fromFlake fromPath fromInventory;
            # Policy: not a host role, an org builds its stick from it, passing `org` as a specialArg.
            nixosModules.rescue-usb = ./nixos/org/rescue-usb.nix;
          };

          perSystem =
            { config, pkgs, ... }:
            let
              categories = import ./tests {
                inherit pkgs o11nLib;
                inherit (config.packages) o11n;
              };
              stage =
                name: checks:
                pkgs.linkFarm "stage-${name}" (
                  lib.mapAttrsToList (check: path: {
                    name = check;
                    inherit path;
                  }) checks
                );
            in
            {
              checks = lib.concatMapAttrs (_: checks: checks) categories;

              legacyPackages.index = import ./dev/index.nix {
                inherit lib;
                src = inputs.self;
                inherit (lib.importTOML ./dev/parts.toml) parts;
              };

              legacyPackages.stages = lib.mapAttrs stage categories // {
                vm = stage "vm" config.legacyPackages.vmTests;
              };

              packages = {
                gost = pkgs.callPackage ./packages/gost.nix { };
                o11n = pkgs.callPackage ./packages/o11n.nix { };
                o11n-tools = pkgs.callPackage ./packages/o11n-tools.nix { inherit (config.packages) gost; };
              }
              // pkgs.callPackages ./packages/dev.nix { inherit (config.packages) o11n-tools; };

              legacyPackages.vmTests.deploy = import ./tests/vm/deploy.nix {
                inherit pkgs;
                o11nInputs = inputs;
                outputs = o11nLib.fromInventory { path = ./tests/inventories/sample; };
              };

              legacyPackages.vmTests.phone-home = import ./tests/vm/phone-home.nix {
                inherit pkgs;
                o11nInputs = inputs;
                outputs = o11nLib.fromInventory { path = ./tests/inventories/sample; };
              };

              legacyPackages.vmTests.remote-eval = import ./tests/vm/remote-eval.nix {
                inherit pkgs;
                o11nInputs = inputs;
                outputs = o11nLib.fromInventory { path = ./tests/inventories/sample; };
              };

              legacyPackages.vmTests.containers = import ./tests/vm/containers.nix { inherit pkgs; };

              # Policy: the dev shell runs each package's source as it is, with what the package runs,
              # bats and socat for their tests, and
              # cargo, rustc and clippy for o11n's crate.
              devShells.default = pkgs.mkShell {
                packages = lib.unique (
                  lib.concatMap (package: package.runtimeInputs or [ ]) (lib.attrValues config.packages)
                  ++ [
                    config.packages.gost
                    config.packages.o11n-tools
                    pkgs.bats
                    pkgs.cargo
                    pkgs.clippy
                    pkgs.rustc
                    pkgs.socat
                  ]
                );
                shellHook = ''
                  if [[ -f .env ]]; then
                    set -a && source .env && set +a
                  fi
                '';
              };
            };
        }
      );
}
