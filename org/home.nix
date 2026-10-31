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
      description = "name of the home configuration";
      type = lib.types.str;
      default = "${config.username}@${host.name}";
    };
    username = lib.mkOption {
      description = "user the home belongs to";
      type = lib.types.str;
      default = name;
    };
    configurationFile = lib.mkOption {
      description = "path to specific configuration";
      type = lib.types.path;
      default = context.path + "/homes/${config.name}.nix";
    };
    roles = lib.mkOption {
      description = "roles the home has";
      type = with lib.types; listOf str;
    };
    hostname = lib.mkOption {
      description = "host the home is on";
      type = lib.types.str;
      default = host.name;
    };
    stateVersion = lib.mkOption {
      description = "nixos state version";
      type = with lib.types; nullOr str;
      default = host.stateVersion;
    };
  };
}
