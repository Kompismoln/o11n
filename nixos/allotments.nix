{
  config,
  lib,
  ...
}:
let
  cfg = config.o11n.allotments;

  allotment = {
    options = {
      dataset = lib.mkOption {
        description = "the allotment's ZFS dataset, under a parent that holds nothing else, which the unit makes unmounted if it's missing";
        type = lib.types.str;
      };
      size = lib.mkOption {
        description = "the dataset's refquota";
        type = lib.types.str;
      };
      path = lib.mkOption {
        description = "the dataset's mountpoint";
        type = lib.types.str;
      };
      uid = lib.mkOption {
        description = "the owner of the allotment's root";
        type = lib.types.int;
      };
      gid = lib.mkOption {
        description = "the group of the allotment's root";
        type = lib.types.int;
      };
      mode = lib.mkOption {
        description = "the mode of the allotment's root";
        type = lib.types.enum [
          "0700"
          "0750"
        ];
        default = "0700";
      };
    };
  };

  unit = id: allotment: {
    description = "the allotment of ${id}";
    wantedBy = [ "multi-user.target" ];
    requires = [ "zfs-mount.service" ];
    after = [ "zfs-mount.service" ];
    path = [ config.boot.zfs.package ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      parent=${lib.escapeShellArg (dirOf allotment.dataset)}
      dataset=${lib.escapeShellArg allotment.dataset}
      if ! zfs list -H -o name "$parent" >/dev/null 2>&1; then
        zfs create -o canmount=off -o mountpoint=none "$parent"
      fi
      if zfs list -H -o name "$dataset" >/dev/null 2>&1; then
        zfs set refquota=${allotment.size} "$dataset"
      else
        zfs create -o refquota=${allotment.size} -o mountpoint=${lib.escapeShellArg allotment.path} "$dataset"
      fi
      chown ${toString allotment.uid}:${toString allotment.gid} ${lib.escapeShellArg allotment.path}
      chmod ${allotment.mode} ${lib.escapeShellArg allotment.path}
    '';
  };
in
{
  options.o11n.allotments = lib.mkOption {
    description = "each allotment on the host, by its id, which allotment@<id> makes and keeps to its size";
    default = { };
    type = lib.types.attrsOf (lib.types.submodule allotment);
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services = lib.mapAttrs' (
      id: allotment: lib.nameValuePair "allotment@${id}" (unit id allotment)
    ) cfg;
  };
}
