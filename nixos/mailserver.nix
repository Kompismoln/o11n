# nixos/mailserver.nix
{
  config,
  o11nInputs,
  lib,
  org,
  ...
}:

let
  cfg = config.o11n.mailserver;
in
{
  imports = [
    o11nInputs.nixos-mailserver.nixosModules.default
  ];

  options.o11n.mailserver = {
    enable = lib.mkEnableOption "mailserver on this host";
    endpoint = lib.mkOption {
      description = "The fqdn of this mailserver.";
      type = lib.types.str;
    };
    dkimSelector = lib.mkOption {
      description = "Label for the DKIM key currently in use.";
      type = lib.types.str;
    };
    users = lib.mkOption {
      description = "Configure user accounts.";
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              enable = (lib.mkEnableOption "this user") // {
                default = true;
              };
              email = lib.mkOption {
                description = "User email";
                type = lib.types.str;
                default = "${name}@${org.endpoint}";
              };
              catchAll = lib.mkOption {
                description = "Make the user recipient of a whole domain.";
                type = with lib.types; listOf str;
                default = [ ];
              };
              aliases = lib.mkOption {
                description = "Make the user recipient of alternative emails";
                type = with lib.types; listOf str;
                default = [ ];
              };
            };
          }
        )
      );
    };
    relayDomains = lib.mkOption {
      description = "List of domains to relay";
      type = with lib.types; listOf str;
    };
    mailboxDomains = lib.mkOption {
      description = "List of domains to manage";
      type = with lib.types; listOf str;
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {

      o11n.preserve.directories = with config.mailserver; [
        dkim.keyDirectory
        storage.path
      ];

      preservation.preserveAt."/srv/database" = {
        directories = [
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
      };

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
        dkim.defaults.selector = cfg.dkimSelector;
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
    })
  ];
}
