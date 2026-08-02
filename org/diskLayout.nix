{ name, lib, ... }:
{
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      default = name;
    };
    layout = lib.mkOption {
      type = lib.types.str;
    };
    luksKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "/luks-key";
    };
    devices = lib.mkOption {
      description = "unix path to device(s)";
      type = with lib.types; either str (listOf str);
    };
    mountpoint = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
}
