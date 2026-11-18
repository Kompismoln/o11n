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
      default = "${entity.name}@${context.org.endpoint}";
      defaultText = lib.literalMD "`<name>@<endpoint>`, the org's endpoint";
      type = lib.types.str;
    };
    server = lib.mkOption {
      description = "the app of kind mail the principal logs in to, its address's domain's `mail`, or null for an address on no domain of the org's, or one without";
      readOnly = true;
      type = lib.types.nullOr lib.types.str;
      default = context.org.domain.${lib.last (lib.splitString "@" config.address)}.mail or null;
      defaultText = lib.literalMD "the `mail` of the domain of `address`";
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
    readers = lib.mkOption {
      description = "the principals, by handle, each with an inbox on the same domain, that read the principal's inbox and its other mailboxes as Shared.<name> under their own login";
      default = [ ];
      type = with lib.types; listOf str;
      example = [ "user-alice" ];
    };
    send = lib.mkOption {
      description = "whether the principal sends mail, as its address, by logging in to the mail server from the hosts it's on, as it does to tell of its failures";
      default = false;
      type = lib.types.bool;
    };
    sendAs = lib.mkOption {
      description = "the other addresses the principal sends as, each an address or, as @<domain>, any address on a domain of the org's without a mailbox";
      default = [ ];
      type = with lib.types; listOf str;
    };
    keys = lib.mkOption {
      description = "the keys the principal's entity has for its mail";
      internal = true;
      readOnly = true;
      default = lib.optionalAttrs (config.inbox || config.send) { mail = "password"; };
    };
  };
}
