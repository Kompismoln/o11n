# nixos/services/mailserver.nix
{
  config,
  o11nInputs,
  lib,
  org,
  ...
}:

let
  domains = lib.attrValues org.domain;

  cfg = {
    inherit (org.mailserver) endpoint dkimSelector;
    relayDomains = map (domain: domain.name) (lib.filter (domain: !domain.mailbox) domains);
    mailboxDomains = map (domain: domain.name) (lib.filter (domain: domain.mailbox) domains);
    users = lib.mapAttrs (name: user: {
      email = "${name}@${org.endpoint}";
      catchAll = [ ];
      aliases = user.inboxes;
    }) (lib.filterAttrs (_: user: user.mail) org.user);
  };
in
{
  imports = [
    o11nInputs.nixos-mailserver.nixosModules.default
  ];

  config = {
    o11n.preserve.databases = [
      {
        directory = "/var/lib/rspamd";
        user = "rspamd";
        group = "rspamd";
      }
      {
        directory = "/var/lib/redis-rspamd";
        user = "redis-rspamd";
        group = "redis-rspamd";
        mode = "0700";
      }
    ];

    sops.secrets =
      lib.concatMapAttrs (user: _: {
        "${user}/mail-sha512" = {
          inherit (org.user.${user}.secrets) sopsFile;
          restartUnits = [
            "dovecot.service"
            "postfix.service"
          ];
        };
      }) cfg.users
      // {
        "dmarc-reports/mail-sha512" = {
          inherit (org.service.dmarc-reports.secrets) sopsFile;
          restartUnits = [
            "dovecot.service"
            "postfix.service"
          ];
        };
      };

    mailserver = {
      enable = true;
      stateVersion = 3;
      fqdn = "mail.${cfg.endpoint}";
      storage.path = config.o11n.preserve.onStorage "/var/vmail";
      dkim = {
        keyDirectory = config.o11n.preserve.onStorage "/var/dkim";
        defaults.selector = cfg.dkimSelector;
      };
      domains = cfg.mailboxDomains;
      domainsWithoutMailbox = cfg.relayDomains;
      enableSubmission = true;
      enableSubmissionSsl = false;
      mailboxes = {
        Drafts = {
          auto = "subscribe";
          special_use = "\\Drafts";
        };
        Junk = {
          auto = "subscribe";
          special_use = "\\Junk";
        };
        Sent = {
          auto = "subscribe";
          special_use = "\\Sent";
        };
        Trash = {
          auto = "subscribe";
          special_use = "\\Trash";
        };
        Archive = {
          auto = "subscribe";
          special_use = "\\Archive";
        };
      };

      accounts = lib.mkMerge [
        (lib.mapAttrs' (user: userCfg: {
          name = userCfg.email;
          value = {
            inherit (userCfg) catchAll aliases;
            hashedPasswordFile = config.sops.secrets."${user}/mail-sha512".path;
          };
        }) cfg.users)
        {
          "dmarc-reports@${cfg.endpoint}" = {
            hashedPasswordFile = config.sops.secrets."dmarc-reports/mail-sha512".path;
            catchAll = [ ];
            aliases = [ ];
          };
        }
      ];
      x509.useACMEHost = config.mailserver.fqdn;
    };

    security.acme.certs.${config.mailserver.fqdn} = {
      group = "nginx";
      webroot = "/var/lib/acme/acme-challenge";
    };

    services.nginx.virtualHosts.${config.mailserver.fqdn} = {
      locations."^~ /.well-known/acme-challenge/" = {
        root = "/var/lib/acme/acme-challenge";
        extraConfig = ''
          auth_basic off;
          auth_request off;
        '';
      };
    };

    services = {
      postfix = {
        settings.main = {
          myorigin = cfg.endpoint;
          mynetworks = [
            "[::1]/128"
            "127.0.0.1/32"
          ]
          ++ (builtins.concatMap (vpn: [
            vpn.addressWithBrackets
            vpn.address4
          ]) (lib.attrValues org.vpn));
        };
        transport =
          let
            transportsList = map (domain: "${domain} smtp:") cfg.relayDomains;
            transportsCfg = lib.concatStringsSep "\n" transportsList;
          in
          transportsCfg;
      };
    };
  };
}
