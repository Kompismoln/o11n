# roles/mailserver.nix
{
  flake.nixosModules.mailserver =
    { org, lib, ... }:
    {
      imports = [
        ../nixos/mailserver.nix
      ];
      o11n.mailserver =
        let
          domains = lib.attrValues org.domain;
          relayDomains = builtins.filter (domain: !domain.mailbox) domains;
          mailboxDomains = builtins.filter (domain: domain.mailbox) domains;
        in
        {
          inherit (org.mailserver) endpoint;
          inherit (org.mailserver) dkimSelector;
          relayDomains = map (domain: domain.name) relayDomains;
          mailboxDomains = map (domain: domain.name) mailboxDomains;

          users = lib.mapAttrs (user: _: { aliases = org.user.${user}.inboxes; }) (
            lib.filterAttrs (_: userCfg: lib.hasAttr "mail" userCfg && userCfg.mail) org.user
          );
        };
    };
}
