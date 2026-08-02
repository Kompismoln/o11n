{ lib, context, ... }:
{
  options = {
    dkimSelector = lib.mkOption {
      description = "dkim selector";
      type = lib.types.str;
    };
    endpoint = lib.mkOption {
      description = "endpoint";
      type = lib.types.str;
      default = context.org.endpoint;
    };
    host = lib.mkOption {
      description = "host";
      type = lib.types.str;
    };
    int = lib.mkOption {
      description = "internal name";
      type = lib.types.str;
    };
    ext = lib.mkOption {
      description = "external name";
      type = lib.types.str;
    };
  };
}
