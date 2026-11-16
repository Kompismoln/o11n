{ config, lib, ... }:
{
  options = {
    input = lib.mkOption {
      description = "the org's input whose packages.<system>.default is the app's mobilizon";
      type = lib.types.str;
      default = config.name;
      defaultText = lib.literalExpression "name";
    };
    from = lib.mkOption {
      description = "the address mobilizon's mail is from, which its principal sends as";
      type = lib.types.str;
      default = config.principal.mail.address;
      defaultText = lib.literalExpression "principal.mail.address";
    };
  };
}
