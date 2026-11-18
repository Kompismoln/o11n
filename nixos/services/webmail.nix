{
  config,
  host,
  lib,
  org,
  ...
}:
let
  serving = lib.any (service: service.name == "mailserver") host.services;
  # Dependency: nixos/services/mailserver.nix serves the mailboxes as mail.<endpoint>.
  fqdn = "mail.${(if org.mailserver == null then org else org.mailserver).endpoint}";
  php = string: "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] string}'";
in
{
  imports = [
    ../nginx.nix
    ../postgresql.nix
  ];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = serving;
          message = "${host.name} has the webmail service, which serves the mail server's mailboxes on its own host, at mail.<endpoint>: give ${host.name} the mailserver service too, or drop webmail from its roles.";
        }
      ];
    }

    # Policy: a principal logs in with its own mail password, which Roundcube logs in to imaps and submission with, as
    # its own client would.
    (lib.mkIf serving {
      services.roundcube = {
        enable = true;
        hostName = fqdn;
        maxAttachmentSize = config.mailserver.messageSizeLimit / 1024 / 1024;
        extraConfig = ''
          $config['imap_host'] = 'ssl://${fqdn}:993';
          $config['smtp_host'] = 'tls://${fqdn}:587';
          $config['smtp_user'] = '%u';
          $config['smtp_pass'] = '%p';
          $config['product_name'] = ${php org.name};
        '';
      };

      o11n.postgresql.databases.${config.services.roundcube.database.dbname}.user =
        config.services.roundcube.database.username;

      services.nginx.virtualHosts.${fqdn} = {
        enableACME = false;
        forceSSL = true;
      };

      # Dependency: fail2ban's roundcube-auth filter reads Roundcube's own log, which it writes to syslog.
      services.fail2ban.jails.roundcube-auth.settings = {
        filter = "roundcube-auth";
        backend = "systemd";
        port = "http,https";
        maxretry = 5;
        findtime = "1h";
      };
    })
  ];
}
