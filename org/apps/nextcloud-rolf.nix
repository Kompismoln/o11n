{
  app,
  config,
  context,
  lib,
  ...
}:
{
  options = {
    input = lib.mkOption {
      description = "the org's input whose packages.<system> has the site's packages";
      type = lib.types.str;
      default = app.name;
      defaultText = lib.literalExpression "name";
    };
    nextcloud = lib.mkOption {
      description = "the nextcloud app whose files the site is built from, and whose user builds it";
      type = context.types.app.ref;
    };
    user = lib.mkOption {
      description = "the Nextcloud user whose folder the site is built from";
      type = lib.types.str;
      default = "rolf";
    };
    folder = lib.mkOption {
      description = "the user's folder the site is built from, a bind of the nextcloud's, which it makes";
      type = lib.types.str;
      default = "+pub";
    };
    path = lib.mkOption {
      description = "the directory on the nextcloud's hosts that is the folder";
      internal = true;
      readOnly = true;
      type = lib.types.str;
      default = "${
        context.org.app.${config.nextcloud}.principal.home
      }/binds/${config.user}/${config.folder}";
      defaultText = lib.literalExpression ''"''${org.app.''${nextcloud}.principal.home}/binds/''${user}/''${folder}"'';
    };
  };
}
