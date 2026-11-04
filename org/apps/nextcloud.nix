{ context, lib, ... }:
{
  options = {
    collabora = lib.mkOption {
      description = "the collabora app whose endpoint nextcloud's office uses, or null";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
  };
}
