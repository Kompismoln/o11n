{
  app,
  context,
  lib,
  ...
}:
{
  options = {
    allowedHosts = lib.mkOption {
      description = "the urls of the hosts collabora accepts WOPI from, and no other";
      type = lib.types.listOf lib.types.str;
      default = map (other: other.url) (
        lib.filter (other: (other.nextcloud.collabora or null) == app.name) (lib.attrValues context.org.app)
      );
      defaultText = lib.literalMD "the `url` of each nextcloud app whose `nextcloud.collabora` is this one";
    };
  };
}
