{
  config,
  context,
  entity,
  lib,
  ...
}:
{
  options = {
    address = lib.mkOption {
      description = "the address the principal receives at with an inbox, and sends as";
      default = "${entity.name}@${
        (if context.org.mailserver == null then context.org else context.org.mailserver).endpoint
      }";
      defaultText = lib.literalMD "`<name>@<endpoint>`, the mail server's endpoint";
      type = lib.types.str;
    };
    inbox = lib.mkOption {
      description = "whether the principal has a mailbox on the mail server, at its address and its aliases";
      default = false;
      type = lib.types.bool;
    };
    aliases = lib.mkOption {
      description = "the other addresses the principal's inbox receives at, as the mail server's aliases";
      default = [ ];
      type = with lib.types; listOf str;
    };
    send = lib.mkOption {
      description = "whether the principal sends mail, as its address, by logging in to the mail server from the hosts it's on, as it does to tell of its failures";
      default = false;
      type = lib.types.bool;
    };
    keys = lib.mkOption {
      description = "the keys the principal's entity has for its mail";
      internal = true;
      readOnly = true;
      default = lib.optionalAttrs (config.inbox || config.send) { mail = "password"; };
    };
  };
}
