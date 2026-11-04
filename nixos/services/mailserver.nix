# nixos/services/mailserver.nix
{
  config,
  host,
  o11nInputs,
  lib,
  org,
  ...
}:

let
  domains = lib.attrValues org.domain;
  domainOf = address: lib.last (lib.splitString "@" address);
  mailboxDomains = map (domain: domain.name) (lib.filter (domain: domain.mailbox) domains);
  relayDomains = map (domain: domain.name) (lib.filter (domain: !domain.mailbox) domains);

  # Accommodating for an org without [mailserver], which an assertion asks for before anything reads it.
  cfg =
    if org.mailserver == null then
      {
        inherit (org) endpoint;
        dkimSelector = "";
      }
    else
      org.mailserver;

  # Policy: a principal with an inbox or that sends has an account, at its address, which it logs in to as itself.
  mailing = lib.filter (
    entity: entity.principal != null && (entity.principal.mail.inbox || entity.principal.mail.send)
  ) (lib.attrValues org.entities);
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

    assertions = [
      {
        assertion = org.mailserver != null;
        message = "${host.name} has the mailserver service, which takes its settings from [mailserver]: declare it.";
      }
    ]
    ++ lib.concatMap (
      entity:
      let
        inherit (entity.principal) mail;
      in
      [
        {
          assertion = lib.elem (domainOf mail.address) (mailboxDomains ++ relayDomains);
          message = "${entity.handle} has mail at ${mail.address}, on no domain of the org's: declare [domain.\"${domainOf mail.address}\"], or set principal.mail.address.";
        }
        {
          assertion = !mail.inbox || lib.elem (domainOf mail.address) mailboxDomains;
          message = "${entity.handle}'s inbox is at ${mail.address}, whose domain has no mailbox: set mailbox under [domain.\"${domainOf mail.address}\"], or principal.mail.address.";
        }
        {
          assertion = mail.inbox || mail.aliases == [ ];
          message = "${entity.handle} has aliases but no inbox: set principal.mail.inbox, or drop principal.mail.aliases.";
        }
      ]
      ++ map (alias: {
        assertion = lib.elem (domainOf alias) mailboxDomains;
        message = "${entity.handle}'s alias ${alias} is on a domain without a mailbox, which only mail from the mail server itself would reach: drop it, or set mailbox under [domain.\"${domainOf alias}\"].";
      }) mail.aliases
    ) mailing;

    sops.secrets = lib.listToAttrs (
      map (
        entity:
        lib.nameValuePair "${entity.name}/mail-sha512" {
          inherit (entity.secrets) sopsFile;
          restartUnits = [
            "dovecot.service"
            "postfix.service"
          ];
        }
      ) mailing
    );

    mailserver = {
      enable = true;
      stateVersion = 3;
      fqdn = "mail.${cfg.endpoint}";
      storage.path = config.o11n.preserve.onStorage "/var/vmail";
      dkim = {
        keyDirectory = config.o11n.preserve.onStorage "/var/dkim";
        defaults.selector = cfg.dkimSelector;
      };
      domains = mailboxDomains;
      domainsWithoutMailbox = relayDomains;
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

      accounts = lib.listToAttrs (
        map (
          entity:
          let
            inherit (entity.principal) mail;
          in
          lib.nameValuePair mail.address {
            inherit (mail) aliases;
            catchAll = [ ];
            sendOnly = !mail.inbox;
            hashedPasswordFile = config.sops.secrets."${entity.name}/mail-sha512".path;
          }
        ) mailing
      );
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

    # Policy: nothing sends but a principal logged in as itself: no network is trusted to relay, and only root and
    # dovecot, for sieve's redirects and replies, use postfix's sendmail.
    services.postfix = {
      settings.main = {
        myorigin = cfg.endpoint;
        mynetworks = lib.mkForce [ ];
        authorized_submit_users = [
          "root"
          config.mailserver.storage.owner
        ];
      };
      transport = lib.concatMapStringsSep "\n" (domain: "${domain} smtp:") relayDomains;
    };
  };
}
