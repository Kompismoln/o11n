{
  context,
  lib,
  name,
  ...
}:
let
  servers = lib.attrNames (
    lib.filterAttrs (_: app: app.kind or null == "mail") (context.spec.app or { })
  );
in
{
  options = {
    name = lib.mkOption {
      description = "domain name";
      type = lib.types.str;
      default = name;
    };
    mailbox = lib.mkEnableOption "mailbox";
    mail = lib.mkOption {
      description = "the app of kind mail that is the domain's mail server, which its principals' addresses log in to and its mail is signed by, or null";
      type = lib.types.nullOr (lib.types.enum servers);
      default = if lib.length servers == 1 then lib.head servers else null;
      defaultText = lib.literalMD "the org's app of kind mail, if it has one alone, or else `null`";
    };
  };
}
