{
  app,
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
  };
}
