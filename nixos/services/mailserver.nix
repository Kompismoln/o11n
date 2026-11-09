{
  config,
  host,
  o11nInputs,
  lib,
  org,
  pkgs,
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

  owned = lib.concatMap (
    entity:
    map (address: { inherit address entity; }) (
      [ entity.principal.mail.address ] ++ entity.principal.mail.aliases
    )
  ) mailing;
  sendingAs = lib.concatMap (
    entity: map (address: { inherit address entity; }) entity.principal.mail.sendAs
  ) mailing;

  # Policy: a login sends as its address, its aliases and its sendAs, in the envelope (postfix) and in From (rspamd);
  # an address an account owns is its owner's alone.
  senderLogins = pkgs.writeText "sender-logins" (
    lib.concatMapStrings (
      { address, entity }:
      let
        pattern = lib.escapeRegex address;
      in
      "/${
        if lib.hasPrefix "@" address then pattern else "^${pattern}"
      }$/ ${entity.principal.mail.address}\n"
    ) sendingAs
  );
  luaTable =
    entries:
    "{\n${
      lib.concatMapStrings (
        { address, entity }:
        "  [${builtins.toJSON (lib.toLower address)}] = ${builtins.toJSON (lib.toLower entity.principal.mail.address)},\n"
      ) entries
    }}";
  fromLogin = pkgs.writeText "rspamd.local.lua" ''
    local owners = ${
      luaTable (owned ++ lib.filter ({ address, ... }: !lib.hasPrefix "@" address) sendingAs)
    }
    local domains = ${luaTable (lib.filter ({ address, ... }: lib.hasPrefix "@" address) sendingAs)}

    rspamd_config:register_symbol({
      name = 'O11N_FROM_LOGIN',
      type = 'prefilter',
      callback = function(task)
        local user = task:get_user()
        if not user then
          return
        end
        user = user:lower()
        local from = task:get_from('mime')
        if not from or #from ~= 1 or not from[1].addr or not from[1].domain then
          task:set_pre_result('reject', 'From must be one address', 'O11N_FROM_LOGIN')
          return
        end
        local address = from[1].addr:lower()
        local owner = owners[address] or domains['@' .. from[1].domain:lower()]
        if owner ~= user then
          task:set_pre_result('reject', string.format('%s may not send as %s', user, address), 'O11N_FROM_LOGIN')
        end
      end,
    })
  '';
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
      ++ lib.optional (mail.sendAs != [ ]) {
        assertion = mail.send;
        message = "${entity.handle} sends as ${lib.concatStringsSep ", " mail.sendAs} but doesn't send: set principal.mail.send, or drop principal.mail.sendAs.";
      }
      ++ map (
        address:
        let
          claimants = lib.filter (other: other.address == lib.toLower address) (
            map (other: other // { address = lib.toLower other.address; }) (owned ++ sendingAs)
          );
        in
        {
          assertion =
            lib.elem (domainOf address) (mailboxDomains ++ relayDomains)
            && (!lib.hasPrefix "@" address || lib.elem (domainOf address) relayDomains)
            && lib.length claimants == 1;
          message = "${entity.handle} sends as ${address}, which is to be an address or @<domain>, on a domain of the org's, any address on it only where it has no mailbox, and no other principal's address, alias or sendAs: change principal.mail.sendAs.";
        }
      ) mail.sendAs
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

    services.rspamd.localLuaRules = fromLogin;

    # Policy: what reads /etc/resolv.conf, as postfix, its TLS policy and rspamd do, asks kresd on loopback, which
    # validates: DANE takes validated answers alone, and blocklists refuse a shared resolver's. What looks up names
    # through nss still asks resolved, which knows the vpns' name servers.
    services.kresd.listenPlain = lib.mkIf config.mailserver.localDnsResolver [
      "[::1]:53"
      "127.0.0.1:53"
    ];
    environment.etc."resolv.conf" = lib.mkIf config.mailserver.localDnsResolver (
      lib.mkForce {
        text = ''
          nameserver 127.0.0.1
          nameserver ::1
          options edns0 trust-ad
        '';
      }
    );

    # Policy: a password is tried on submission and imaps alone, where a principal's own client may mistype it.
    services.fail2ban.jails =
      let
        login = filter: {
          settings = {
            inherit filter;
            port = "submission,imaps";
            maxretry = 5;
            findtime = "1h";
          };
        };
      in
      {
        postfix-sasl = login "postfix[mode=auth]";
        dovecot = login "dovecot[mode=normal]";
      };

    # Policy: nothing sends but a principal logged in as itself, on submission alone, whose sender restrictions smtp
    # lacks: no network is trusted to relay, and only root and dovecot, for sieve's redirects and replies, use
    # postfix's sendmail.
    services.postfix = {
      submissionOptions.smtpd_sender_login_maps = lib.mkForce "hash:/etc/postfix/vaccounts,pcre:${senderLogins}";
      settings.main = {
        smtpd_sasl_auth_enable = lib.mkForce false;
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
