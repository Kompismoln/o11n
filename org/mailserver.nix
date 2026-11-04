{
  config,
  context,
  lib,
  ...
}:
{
  options = {
    dkimSelector = lib.mkOption {
      description = "the selector of the mail server's dkim keys";
      type = lib.types.str;
    };
    endpoint = lib.mkOption {
      description = "the domain the mail server is mail.<endpoint> of, and the principals' addresses are on by default";
      type = lib.types.str;
      default = context.org.endpoint;
    };
    admin = lib.mkOption {
      description = "the address that hears of what goes wrong on the org's hosts, such as a unit that fails";
      type = lib.types.str;
      default = "admin@${config.endpoint}";
      defaultText = lib.literalExpression ''"admin@''${endpoint}"'';
    };
  };
}
