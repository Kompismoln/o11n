{
  app,
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
    source = lib.mkOption {
      description = "the folder in the app's home the site is built from";
      type = lib.types.str;
      default = "files";
    };
  };
}
