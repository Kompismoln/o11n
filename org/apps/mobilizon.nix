{ app, lib, ... }:
{
  options = {
    input = lib.mkOption {
      description = "the org's input whose packages.<system>.default is the app's mobilizon";
      type = lib.types.str;
      default = app.name;
      defaultText = lib.literalExpression "name";
    };
    mailServer = lib.mkOption {
      description = "the SMTP relay mobilizon sends through, or null";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };
}
