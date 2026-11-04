{
  config,
  name,
  lib,
  ...
}:
{
  options = {
    name = lib.mkOption {
      description = "name of the disk in disko";
      type = lib.types.str;
      default = name;
    };
    layout = lib.mkOption {
      description = "layout in disk-layouts/ that partitions the disk";
      type = lib.types.str;
    };
    devices = lib.mkOption {
      description = "unix path to device(s)";
      type = with lib.types; either str (listOf str);
    };
    mountpoint = lib.mkOption {
      description = "where the layout mounts the disk, for a layout that takes one";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    encrypted = lib.mkOption {
      description = "whether the layout encrypts the disk with the host's luks-key";
      type = lib.types.bool;
      # Dependency: of the layouts in disk-layouts/, these two read no host.luksKeyFile.
      default =
        !lib.elem config.layout [
          "single-xfs"
          "raid1-xfs"
        ];
      defaultText = lib.literalMD "`true` but for the `single-xfs` and `raid1-xfs` layouts";
    };
  };
}
