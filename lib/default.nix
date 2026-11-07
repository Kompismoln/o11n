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

  fromInventory =
    {
      path,
      inputs ? { },
    }:
    let
      outPath = "${path}";
    in
    mkConfigurations (evalContext {
      path = outPath;
      flake = { inherit outPath inputs; };
    });

  evalContext =
    config:
    (lib.evalModules {
      modules = [
        { inherit config; }
        ../org/context.nix
      ];
    }).config;

  mkConfigurations = context: {
    inherit context;
    inherit (context) org;

    diskoConfigurations = mkDiskoConfigurations context;
    homeConfigurations = mkHomeConfigurations context;
    nixosConfigurations = mkNixosConfigurations context;
    openwrtConfigurations = mkOpenwrtConfigurations context;
  };

  # Policy: a router's configuration is the files o11n writes on it, as a tree, and its image, which holds those
  # without a secret; the image is built on x86_64-linux, the only system OpenWrt's ImageBuilder runs on.
  mkOpenwrtConfigurations =
    context:
    let
      pkgs = o11nInputs.nixpkgs.legacyPackages.x86_64-linux;
      tree =
        name: files:
        pkgs.runCommand name
          {
            nativeBuildInputs = [ pkgs.jq ];
            files = builtins.toJSON files;
          }
          ''
            mkdir -p $out
            jq -r 'keys[]' <<<"$files" | while read -r path; do
              mkdir -p "$out$(dirname "$path")"
              jq -j --arg path "$path" '.[$path]' <<<"$files" > "$out$path"
            done
          '';
    in
    lib.mapAttrs (
      name: host:
      let
        inherit (host) openwrt;
        target = lib.splitString "/" openwrt.target;
      in
      {
        inherit (openwrt)
          release
          target
          profile
          packages
          ;
        files = tree "openwrt-${name}-files" openwrt.files;
        image = import "${o11nInputs.openwrt-imagebuilder}/builder.nix" {
          inherit pkgs;
          inherit (openwrt) release profile packages;
          target = lib.head target;
          variant = lib.last target;
          files = tree "openwrt-${name}-image-files" openwrt.imageFiles;
          extraImageName = name;
        };
      }
    ) (lib.filterAttrs (_: host: host.openwrt != null) context.org.host);

  mkNixosConfigurations =
    context:
    lib.genAttrs' (lib.filter (host: host.nixos) (lib.attrValues context.org.host)) (
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
          modules = [
            host.configurationFile
            ../nixos/org/boot.nix
            ../nixos/org/system.nix
            ../nixos/org/principals.nix
            ../nixos/org/ssh.nix
            ../nixos/org/networking.nix
            ../nixos/org/nix.nix
            ../nixos/org/sops.nix
          ]
          ++ lib.optional (host.vpns != [ ]) ../nixos/org/wireguard.nix
          ++ lib.optional (host.disk-layouts != { }) ../nixos/disko.nix
          ++ lib.optional (host.allotments != [ ] || host.replicas != [ ]) ../nixos/org/allotments.nix
          ++ map (service: service.configurationFile) (
            lib.filter (service: service.configurationFile != null) host.services
          )
          # Policy: a role is its services and stores; one with more than those has a module of its own.
          ++ lib.concatMap (
            role: lib.optional (o11nInputs.self.nixosModules ? ${role}) o11nInputs.self.nixosModules.${role}
          ) (lib.unique (host.roles ++ (lib.concatMap (home: home.roles) (lib.attrValues host.home))));
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
