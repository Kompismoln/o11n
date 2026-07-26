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
    config:
    (lib.evalModules {
      modules = [
        { inherit config; }
        ./context.nix
      ];
    }).config;

  mkConfigurations = context: {
    inherit context;
    inherit (context) org;

    diskoConfigurations = mkDiskoConfigurations context;
    homeConfigurations = mkHomeConfigurations context;
    nixosConfigurations = mkNixosConfigurations context;
  };

  mkNixosConfigurations =
    context:
    lib.genAttrs' (lib.filter (host: lib.elem "nixos" host.roles) (lib.attrValues context.org.host)) (
      host:
      lib.nameValuePair host.name (
        o11nInputs.nixpkgs.lib.nixosSystem {
          specialArgs = {
            inherit (context) inputs org;
            inherit host o11nInputs;
            diskoConfigurations = lib.filterAttrs (name: _: lib.hasPrefix "${host.name}-" name) (
              mkDiskoConfigurations context
            );
          };
          modules =
            (lib.optionals (host.disk-layouts != { }) [ ../nixos/disko.nix ])
            ++ map (role: o11nInputs.self.nixosModules.${role}) (
              lib.unique (host.roles ++ (lib.concatMap (home: home.roles) (lib.attrValues host.home)))
            );
        }
      )
    );

  mkHomeConfigurations =
    context:
    lib.listToAttrs (
      lib.concatMap (
        host:
        (map (
          home:
          lib.nameValuePair home.name (
            o11nInputs.home-manager.lib.homeManagerConfiguration {
              pkgs = import o11nInputs.nixpkgs {
                inherit (host) system;
                overlays = [
                  (import ../overlays/tools.nix)
                ];
              };
              extraSpecialArgs = {
                inherit (context) inputs org;
                inherit
                  home
                  o11nInputs
                  ;
              };
              modules = [
                home.configurationFile
              ]
              ++ map (role: o11nInputs.self.homeModules.${role}) home.roles;
            }
          )
        ) (lib.attrValues host.home))
      ) (lib.attrValues context.org.host)
    );

  mkDiskoConfigurations =
    context:
    lib.listToAttrs (
      lib.concatMap (
        host:
        (map (
          disk:
          lib.nameValuePair "${host.name}-${disk.name}" (

            (import ../disk-layouts/${disk.layout}.nix) {
              inherit (context) org;
              inherit
                host
                disk
                lib
                ;
              pkgs = o11nInputs.nixpkgs.legacyPackages.${host.system};
            }
          )
        ) (lib.attrValues host.disk-layouts))
      ) (lib.attrValues context.org.host)
    );
}
