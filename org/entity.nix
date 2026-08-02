# org/entity.nix
{
  name,
  lib,
  config,
  context,
  ...
}:
{
  options = {
    id = lib.mkOption {
      description = "numeric internal id used to seed other id's";
      default = null;
      type = with lib.types; nullOr int;
    };
    ids = lib.mkOption {
      description = "entity id in various formats";
      type = lib.types.nullOr context.types.ids.module;
      default = if config.id == null then null else { int = config.id; };
    };
    class = lib.mkOption {
      description = "entity class";
      type = context.types.class;
    };
    name = lib.mkOption {
      description = "name";
      default = name;
      type = lib.types.str;
    };
    description = lib.mkOption {
      description = "full name or short purpose description";
      default = "[${config.class}] ${config.name}";
      type = lib.types.str;
    };
    inventory = lib.mkOption {
      type = context.types.inventory.module;
    };
    grants = lib.mkOption {
      type = context.types.inventory.module;
      default = config.inventory;
    };
    principal = lib.mkOption {
      description = "optional attached principal";
      type = lib.types.nullOr (
        lib.types.submoduleWith {
          modules = [ ./principal.nix ];
          specialArgs = {
            inherit context;
            entity = config;
          };
        }
      );
      default = if config.id == null || config.class == "host" then null else { };
    };
    publicKeys = lib.mkOption {
      type = lib.types.submoduleWith {
        modules = [ ./public-keys.nix ];
        specialArgs = {
          inherit context;
          entity = config;
        };
      };
    };
    secrets = lib.mkOption {
      type = lib.types.submoduleWith {
        modules = [ ./secrets.nix ];
        specialArgs = {
          inherit context;
          entity = config;
        };
      };
    };
    settings = lib.mkOption {
      description = "entity-specific options, passed through as-is to the entity's configuration";
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };
}
