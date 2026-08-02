# org/principal.nix
{
  config,
  context,
  lib,
  entity,
  ...
}:
{
  options = {
    uid = lib.mkOption {
      description = "posix user id";
      default = context.classes.${entity.class}.block + entity.id;
      type = lib.types.int;
    };
    gid = lib.mkOption {
      description = "posix group id";
      default = config.uid;
      type = lib.types.int;
    };
    groups = lib.mkOption {
      description = "principal's extra groups";
      type = with lib.types; listOf str;
      default = [ ];
    };
    members = lib.mkOption {
      description = "members of the principal's groups";
      type = with lib.types; listOf str;
      default = [ ];
    };
    home = lib.mkOption {
      description = "endow entity with /home (for users) or /var/lib (for non-users)";
      type = lib.types.str;
      default =
        if config.hasHome then
          (
            {
              user = "/home/${entity.name}";
            }
            .${entity.class} or "/var/lib/${entity.name}"
          )
        else
          "/var/empty";
    };
    homeMode = lib.mkOption {
      type = lib.types.str;
      default = "0750";
    };
    hasPasswd = lib.mkEnableOption "endow entity with a password" // {
      type = lib.types.bool;
      default = entity.class == "user";
    };
    hasPublicKey = lib.mkEnableOption "endow entity with a cryptographic identity" // {
      type = lib.types.bool;
      default = builtins.elem entity.class [
        "user"
        "service"
        "app"
      ];
    };
    hasHome = lib.mkEnableOption "force bash shell for non-normal users" // {
      type = lib.types.bool;
      default = builtins.elem entity.class [
        "user"
        "store"
        "app"
      ];
    };
    hasBash = lib.mkEnableOption "force bash shell for non-normal users" // {
      type = lib.types.bool;
      default = entity.class == "user";
    };
    bindAddress = lib.mkOption {
      description = "unique ipv6 loopback address for entity to bind to";
      default = "${context.org.loPrefix}::${toString config.uid}:${entity.ids.hex4}";
      type = context.types.host6;
    };
  };
}
