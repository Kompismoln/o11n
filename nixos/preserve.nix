# nixos/preserve.nix
{
  config,
  host,
  o11nInputs,
  lib,
  options,
  ...
}:

let
  cfg = config.o11n.preserve;

  preserveAtOptions = options.preservation.preserveAt.type.nestedTypes.elemType.getSubOptions [ ];
in
{
  imports = [
    o11nInputs.preservation.nixosModules.preservation
    ./containers.nix
    ./preserve-paths.nix
  ];

  options.o11n.preserve = rec {
    inherit (preserveAtOptions) files directories;
    databases = directories;
  };

  config = lib.mkIf cfg.enable {

    preservation = {
      enable = true;
      preserveAt.${cfg.storage} = {
        directories = [
          "/var/lib/nixos"
          "/var/lib/systemd"
        ]
        ++ cfg.directories;
        inherit (cfg) files;
      };
      preserveAt.${cfg.database} = {
        directories = cfg.databases;
      };
    };

    security.sudo = {
      extraConfig = ''
        Defaults lecture = never
      '';
    };

    fileSystems."/keys".neededForBoot = true;

    environment.etc."machine-id".text = host.ids.hex32 + "\n";

    # Fact: /var is 1G and nginx's logs share it (nixos/nginx.nix); a SystemKeepFree they can cross has journald vacuum
    # its whole history.
    services.journald.settings.Journal = {
      SystemMaxUse = "256M";
      SystemKeepFree = "100M";
    };
  };
}
