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

  containersDir = "/var/lib/${lib.optionalString (lib.versionAtLeast config.system.stateVersion "22.05") "nixos-"}containers";
  snapshotSuffix = lib.concatStrings (lib.replicate 16 "[0-9a-f]");

  # Piggyback on preservation's options for files and directories
  preserveAtOptions = options.preservation.preserveAt.type.nestedTypes.elemType.getSubOptions [ ];
in
{
  imports = [
    o11nInputs.preservation.nixosModules.preservation
  ];

  options.o11n.preserve = rec {
    inherit (preserveAtOptions) files directories;
    databases = directories;
    enable = lib.mkEnableOption "ephemeral root on this host";
    storage = lib.mkOption {
      description = "permanent storage";
      type = lib.types.str;
      default = "/srv/storage";
    };
    database = lib.mkOption {
      description = "permanent no-cow storage";
      type = lib.types.str;
      default = "/srv/database";
    };
  };

  config = lib.mkIf cfg.enable {

    preservation = {
      enable = true;
      preserveAt.${cfg.storage} = {
        directories = [
          "/var/lib/nixos"
          "/var/lib/systemd"
        ]
        ++ lib.optional (config.containers != { }) {
          directory = containersDir;
          mode = "0700";
        }
        ++ cfg.directories;
        inherit (cfg) files;
      };
      preserveAt.${cfg.database} = {
        directories = cfg.databases;
      };
    };

    # nspawn snapshots an ephemeral container next to its root, which upstream keeps on /run.
    systemd.services = lib.mapAttrs' (
      name: _:
      lib.nameValuePair "container@${name}" {
        environment.root = lib.mkForce "${containersDir}/%i";
        unitConfig.RequiresMountsFor = [ "${containersDir}/%i" ];
        # A container killed before nspawn removes its snapshot leaves it behind.
        preStart = lib.mkBefore "rm -rf -- ${containersDir}/.#snapshot.${name}${snapshotSuffix}";
      }
    ) (lib.filterAttrs (_: container: container.ephemeral) config.containers);

    security.sudo = {
      extraConfig = ''
        Defaults lecture = never
      '';
    };

    fileSystems."/keys".neededForBoot = true;

    environment.etc."machine-id".text = host.ids.hex32 + "\n";

    boot.initrd.systemd.enable = true;

    services.journald.settings.Journal = {
      SystemMaxUse = "100M";
      SystemKeepFree = "200M";
      MaxRetentionSec = "1week";
    };
  };
}
