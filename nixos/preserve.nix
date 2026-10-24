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

  containersRoot = cfg.onStorage "/var/lib/${lib.optionalString (lib.versionAtLeast config.system.stateVersion "22.05") "nixos-"}containers";
  snapshotSuffix = lib.concatStrings (lib.replicate 16 "[0-9a-f]");

  # Piggyback on preservation's options for files and directories
  preserveAtOptions = options.preservation.preserveAt.type.nestedTypes.elemType.getSubOptions [ ];
in
{
  imports = [
    o11nInputs.preservation.nixosModules.preservation
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

    systemd.tmpfiles.rules = lib.optional (
      config.containers != { }
    ) "d ${containersRoot} 0700 root root - -";

    # Upstream keeps container roots on /var, and an ephemeral one's on /run, where nspawn
    # snapshots it next to its root.
    systemd.services = lib.mapAttrs' (
      name: container:
      lib.nameValuePair "container@${name}" {
        environment.root = lib.mkForce "${containersRoot}/%i";
        unitConfig.RequiresMountsFor = [ "${containersRoot}/%i" ];
        # A container killed before nspawn removes its snapshot leaves it behind.
        preStart = lib.mkIf container.ephemeral (
          lib.mkBefore "rm -rf -- ${containersRoot}/.#snapshot.${name}${snapshotSuffix}"
        );
      }
    ) config.containers;

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
