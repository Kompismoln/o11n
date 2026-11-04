{ context, lib, ... }:
{
  options = {
    keycloak = lib.mkOption {
      description = "the keycloak app jitsi authenticates with";
      type = context.types.app.ref;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of jitsi's client";
      type = lib.types.str;
    };
  };
}
