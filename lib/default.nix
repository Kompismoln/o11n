# lib/default.nix
{
  lib,
  o11nInputs,
}:
rec {
  fromPath =
    path:
    mkConfigurations (evalContext {
      inherit path;
    });

  fromFlake =
    flake:
    mkConfigurations (evalContext {
      inherit flake;
    });

  evalContext =
    context:
    (lib.evalModules {
      modules = [
        { config = context; }
        ./context.nix
      ];
    }).config;

  mkConfigurations = context: {
    inherit context;

    diskoConfigurations = mkDiskoConfigurations context;
    homeConfigurations = mkHomeConfigurations context;
    nixosConfigurations = mkNixosConfigurations context;
  };

  mkPkgs = system: o11nInputs.nixpkgs.legacyPackages.${system};

  mkNixosConfigurations =
    context:
    lib.mapAttrs (
      _: host:
      o11nInputs.nixpkgs.lib.nixosSystem {
        specialArgs = {
          inherit (context) inputs inventory;
          inherit host o11nInputs;
          diskoConfigurations = lib.filterAttrs (_: diskLayout: diskLayout.host == host.name) (
            mkDiskoConfigurations context
          );
        };
        modules = map (role: o11nInputs.self.nixosModules.${role}) host.roles;
      }
    ) (lib.filterAttrs (_: host: host.stateVersion != null) context.inventory.host);

  mkHomeConfigurations =
    context:
    lib.mapAttrs (
      _: home:
      let
        pkgs = mkPkgs home.system;
      in
      o11nInputs.home-manager.lib.homeManagerConfiguration {
        extraSpecialArgs = {
          inherit (context) inputs inventory;
          inherit
            pkgs
            home
            o11nInputs
            ;
        };
        modules = [
          home.configurationFile
        ];
      }
    ) context.inventory.home;

  mkDiskoConfigurations =
    context:
    lib.mapAttrs (
      _: diskLayout:
      let
        host = context.inventory.host.${diskLayout.${diskLayout.host}};
        pkgs = mkPkgs host.system;
      in
      (import diskLayout.diskoFile) {
        inherit (context) inventory;
        inherit
          host
          pkgs
          diskLayout
          lib
          ;
      }
    ) context.inventory.diskLayout;
}
