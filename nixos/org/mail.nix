# nixos/org/mail.nix
{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  cfg = config.o11n.mail;
  inherit (org) mailserver;

  # Dependency: nixos/services/mailserver.nix serves submission as mail.<endpoint>.
  fqdn = "mail.${mailserver.endpoint}";
  serving = lib.any (service: service.name == "mailserver") host.services;

  principals = lib.listToAttrs (map (entity: lib.nameValuePair entity.handle entity) host.principals);
  sending = lib.filter (entity: entity.principal.mail.send) host.principals;
  secret = entity: config.sops.secrets."${entity.name}/mail".path;

  # Policy: a failure is told as the principal that failed, from its own account, to the mail server's admin.
  tell =
    entity:
    pkgs.writeShellApplication {
      name = "mail-failure-${entity.handle}";
      runtimeInputs = [
        pkgs.msmtp
        pkgs.systemd
        pkgs.util-linux
      ];
      text = ''
        unit=$1
        {
          printf 'From: %s\nTo: %s\nSubject: %s: %s failed\n\n' \
            ${
              lib.escapeShellArgs [
                entity.principal.mail.address
                mailserver.admin
                host.name
              ]
            } "$unit"
          systemctl status --no-pager --full --lines=50 "$unit" || true
        } | setpriv --reuid=${entity.name} --regid=${entity.name} --init-groups \
          msmtp -C /etc/msmtprc -a ${entity.handle} -- ${lib.escapeShellArg mailserver.admin}
      '';
    };
in
{
  options.o11n.mail.failures = lib.mkOption {
    description = "the units on the host whose failure mails the mail server's admin, each with the id of the principal that tells of it";
    default = { };
    type = with lib.types; attrsOf str;
  };

  config = lib.mkIf (mailserver != null) {
    assertions = lib.mapAttrsToList (unit: id: {
      assertion = principals ? ${id} && principals.${id}.principal.mail.send;
      message = "${unit} on ${host.name} tells of its failure as ${id}, which doesn't send mail: set principal.mail.send for ${id}.";
    }) cfg.failures;

    sops.secrets = lib.listToAttrs (
      map (
        entity:
        lib.nameValuePair "${entity.name}/mail" {
          inherit (entity.secrets) sopsFile;
          owner = entity.name;
          group = entity.name;
          mode = "0400";
        }
      ) sending
    );

    # Policy: each principal sends from an account whose password only it reads, and whose From is its address
    # whatever the mail says, unless it sends as others too, which the mail server then holds it to; there's no
    # default account, so mail that names none isn't sent.
    programs.msmtp = {
      enable = true;
      setSendmail = !serving;
      accounts = lib.listToAttrs (
        map (
          entity:
          lib.nameValuePair entity.handle {
            host = fqdn;
            port = 587;
            tls = true;
            tls_starttls = true;
            auth = true;
            user = entity.principal.mail.address;
            from = entity.principal.mail.address;
            set_from_header = if entity.principal.mail.sendAs == [ ] then "on" else "auto";
            passwordeval = "${pkgs.coreutils}/bin/cat ${secret entity}";
          }
        ) sending
      );
    };

    systemd.services =
      lib.mapAttrs (_: id: { onFailure = [ "mail-failure-${id}@%n.service" ]; }) cfg.failures
      // lib.listToAttrs (
        map (
          id:
          lib.nameValuePair "mail-failure-${id}@" {
            description = "mail ${mailserver.admin} that %i failed, as ${id}";
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${lib.getExe (tell principals.${id})} %i";
            };
          }
        ) (lib.filter (id: principals ? ${id}) (lib.unique (lib.attrValues cfg.failures)))
      );
  };
}
