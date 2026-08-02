{
  name,
  lib,
  context,
  ...
}:
{
  options = {
    name = lib.mkOption {
      description = "domain name";
      type = lib.types.str;
      default = name;
    };
    services = lib.mkOption {
      description = "services bundled in this role";
      type = lib.types.listOf context.types.service.ref;
      default = [ ];
    };
    stores = lib.mkOption {
      description = "stores bundled in this role";
      type = lib.types.listOf context.types.store.ref;
      default = [ ];
    };
  };
}
