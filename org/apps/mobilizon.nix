{ app, lib, ... }:
{
  options = {
    input = lib.mkOption {
      description = "the org's input whose packages.<system>.default is the app's mobilizon";
      type = lib.types.str;
      default = app.name;
      defaultText = lib.literalExpression "name";
    };
    from = lib.mkOption {
      description = "the address mobilizon's mail is from, which its principal sends as";
      type = lib.types.str;
      default = app.principal.mail.address;
      defaultText = lib.literalExpression "principal.mail.address";
    };
  };
}
