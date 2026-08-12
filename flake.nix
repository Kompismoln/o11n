# flake.nix
{
  description = "o11n nixos fleet manager";

  inputs = {
    nixpkgs.url = "github:Kompismoln/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    nixvim.url = "github:nix-community/nixvim";

    nixos-mailserver.url = "gitlab:ahbk/nixos-mailserver/relay-26.05";
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
            inherit (o11nLib) fromFlake fromPath;
          };

          perSystem =
            { pkgs, ... }:
            {
              checks = import ./tests { inherit pkgs o11nLib; };

              devShells.default = pkgs.mkShell {
                buildInputs = [ ];
                shellHook = "";
              };
            };
        }
      );
}
