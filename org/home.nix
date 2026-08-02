# org/spec-v1/home.nix
{
  name,
  lib,
  host,
  config,
  context,
  ...
}:
{
  options = {
    name = lib.mkOption {
      type = lib.types.str;
      default = "${config.username}-${host.name}";
    };
    username = lib.mkOption {
      type = lib.types.str;
      default = name;
    };
    hostname = lib.mkOption {
      type = lib.types.str;
      default = host.name;
    };
    configurationFile = lib.mkOption {
      type = lib.types.path;
      default = context.path + "/homes/${config.name}.nix";
    };
    roles = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
    };
    stateVersion = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = host.stateVersion;
    };
  };
}
