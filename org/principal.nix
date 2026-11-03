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
      defaultText = lib.literalMD "the block `org/classes.nix` gives the entity's class, plus the entity's `id`";
      type = lib.types.int;
    };
    gid = lib.mkOption {
      description = "posix group id";
      default = config.uid;
      defaultText = lib.literalExpression "uid";
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
      defaultText = lib.literalMD "`/home/<name>` for a user and `/var/lib/<name>` for the rest, if it `hasHome`, or else `/var/empty`";
    };
    homeMode = lib.mkOption {
      description = "permissions of the principal's home";
      type = lib.types.str;
      default = "0750";
    };
    hasPasswd = lib.mkEnableOption "endow entity with a password" // {
      type = lib.types.bool;
      default = entity.class == "user";
      defaultText = lib.literalMD "true for a user";
    };
    hasPublicKey = lib.mkEnableOption "endow entity with a cryptographic identity" // {
      type = lib.types.bool;
      default = builtins.elem entity.class [
        "user"
        "service"
        "store"
        "app"
      ];
      defaultText = lib.literalMD "true for a user, service, store or app";
    };
    hasHome = lib.mkEnableOption "endow entity with a home" // {
      type = lib.types.bool;
      default = builtins.elem entity.class [
        "user"
        "store"
        "app"
      ];
      defaultText = lib.literalMD "true for a user, store or app";
    };
    hasBash = lib.mkEnableOption "force bash shell for non-normal users" // {
      type = lib.types.bool;
      default = entity.class == "user";
      defaultText = lib.literalMD "true for a user";
    };
    hasSFTP = lib.mkEnableOption "restrict the entity's ssh logins to sftp" // {
      type = lib.types.bool;
      default = builtins.elem entity.class [
        "app"
        "store"
      ];
      defaultText = lib.literalMD "true for an app or store";
    };
    archives = lib.mkOption {
      description = "the hosts with the archive role that archive the principal's home, as a list or each with a schedule; only an archive with a schedule has a timer";
      default = { };
      type =
        with lib.types;
        coercedTo (listOf context.types.host.ref) (hosts: lib.genAttrs hosts (_: { })) (
          attrsOf (submodule {
            options.schedule = lib.mkOption {
              description = "when to archive, as a systemd calendar event, or null to archive only when asked";
              default = null;
              type = nullOr str;
            };
          })
        );
    };
    bindAddress = lib.mkOption {
      description = "unique ipv6 loopback address for entity to bind to";
      default = "${context.org.loPrefix}::${toString config.uid}:${entity.ids.hex4}";
      defaultText = lib.literalExpression ''"''${org.loPrefix}::''${toString uid}:''${ids.hex4}"'';
      type = context.types.host6;
    };
  };
}
