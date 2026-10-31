{ name, lib, ... }:
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
  };
}
