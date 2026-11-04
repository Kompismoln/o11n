# nixos/services/mailserver.nix
{ org, lib, ... }:
let
  domains = lib.attrValues org.domain;
in
{
  imports = [
    ../mailserver.nix
  ];

  o11n.mailserver = {
    inherit (org.mailserver) endpoint dkimSelector;
    relayDomains = map (domain: domain.name) (lib.filter (domain: !domain.mailbox) domains);
    mailboxDomains = map (domain: domain.name) (lib.filter (domain: domain.mailbox) domains);

    users = lib.mapAttrs (user: _: { aliases = org.user.${user}.inboxes; }) (
      lib.filterAttrs (_: user: user.mail) org.user
    );
  };
}
