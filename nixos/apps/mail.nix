{
  app,
  config,
  o11nInputs,
  lib,
  org,
  pkgs,
  ...
}:

let
  domainOf = address: lib.last (lib.splitString "@" address);
  mailboxDomains = map (domain: domain.name) (lib.filter (domain: domain.mailbox) app.domains);
  relayDomains = map (domain: domain.name) (lib.filter (domain: !domain.mailbox) app.domains);

  # Policy: a principal with an inbox or that sends has an account, at its address, on the server of its address's
  # domain, which it logs in to as itself.
  mailed = lib.filter (
    entity: entity.principal != null && (entity.principal.mail.inbox || entity.principal.mail.send)
  ) (lib.attrValues org.entities);
  mailing = lib.filter (entity: entity.principal.mail.server == app.name) mailed;
  unserved = lib.filter (entity: entity.principal.mail.server == null) mailed;

  dmarc = pkgs.writeShellApplication {
    name = "dmarc-reports";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      getent
      gnused
      gzip
      ripmime
      unzip
      xmlstarlet
    ];
    text = builtins.readFile ./mail/dmarc-reports.sh;
  };
  reading = app.principal != null && app.principal.mail.inbox;

  # Policy: the server keeps the records its mail is read by in the zones it can write, as it alone has its DKIM keys:
  # each zone's MX, with a mailbox, its DKIM key and its DMARC record, and an SPF record where there's none, and, in
  # the zone of the reports' address, each other domain's authorization to send its reports there (RFC 7489, 7.1).
  inherit (app) glesys;
  reports = if reading then app.principal.mail.address else null;
  reportsDomain = lib.mapNullable domainOf reports;
  related = inner: outer: inner == outer || lib.hasSuffix ".${outer}" inner;
  zones = lib.genAttrs (if glesys == null then [ ] else glesys.zones) (
    zone:
    lib.optional (lib.elem zone mailboxDomains) {
      kind = "mx";
      host = "@";
      data = app.endpoint;
    }
    ++ [
      {
        kind = "spf";
        host = "@";
        data = "v=spf1 a:${app.endpoint} -all";
      }
      {
        kind = "dkim";
        host = "${app.dkimSelector}._domainkey";
        data = "${zone}.${app.dkimSelector}.txt";
      }
      {
        kind = "dmarc";
        host = "_dmarc";
        data = "v=DMARC1; p=${glesys.dmarc}${lib.optionalString reading "; rua=mailto:${reports}"}";
      }
    ]
    ++ lib.optionals (zone == reportsDomain) (
      map
        (domain: {
          kind = "authorize";
          host = "${domain}._report._dmarc";
          data = "";
        })
        (
          lib.filter (domain: !related domain zone && !related zone domain) (
            map (domain: domain.name) app.domains
          )
        )
    )
  );
  glesysScript = pkgs.writeShellApplication {
    name = "glesys";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      jq
    ];
    text = builtins.readFile ./mail/glesys.sh;
  };
  php = string: "'${lib.replaceStrings [ "\\" "'" ] [ "\\\\" "\\'" ] string}'";
  inboxes = lib.filter (entity: entity.principal.mail.inbox) mailing;
  byHandle = lib.listToAttrs (map (entity: lib.nameValuePair entity.handle entity) mailing);

  ownerOf =
    address:
    lib.findFirst (
      entity:
      lib.elem (lib.toLower address) (
        map lib.toLower ([ entity.principal.mail.address ] ++ entity.principal.mail.aliases)
      )
    ) null inboxes;
  admin = ownerOf app.admin;

  # Policy: each domain with mailboxes has a postmaster, as RFC 5321 asks, the admin where no principal is.
  postmasters = lib.filter (address: ownerOf address == null) (
    map (domain: "postmaster@${domain}") mailboxDomains
  );
  aliasesOf =
    entity:
    entity.principal.mail.aliases
    ++ lib.optionals (admin != null && entity.handle == admin.handle) postmasters;

  owned = lib.concatMap (
    entity:
    map (address: { inherit address entity; }) ([ entity.principal.mail.address ] ++ aliasesOf entity)
  ) mailing;

  # Policy: a principal's readers see its mailboxes as Shared<separator><name>, the private namespace's separator
  # between, with the rights to list and read them and mark them seen for themselves; the ACL on its INBOX, which the
  # other mailboxes take theirs from, names them alone, and nothing else grants. Dovecot takes the owner's domain from
  # the reader's login.
  separator = config.mailserver.hierarchySeparator;
  sharing = lib.filter (entity: entity.principal.mail.readers != [ ]) inboxes;
  readersOf = entity: map (handle: byHandle.${handle}) entity.principal.mail.readers;
  shares = pkgs.writeText "mail-readers" (
    lib.concatMapStrings (
      entity:
      "${entity.principal.mail.address} ${
        lib.concatMapStringsSep "," (reader: reader.principal.mail.address) (readersOf entity)
      }\n"
    ) inboxes
  );
  share = pkgs.writeShellApplication {
    name = "mail-readers";
    runtimeInputs = [
      config.services.dovecot2.package
      pkgs.gawk
      pkgs.gnugrep
    ];
    text = ''
      readers() {
        doveadm -f tab acl get -u "$1" "$2" | awk -F '\t' 'NR > 1 && $1 ~ /^user=/ { print substr($1, 6) }'
      }
      while read -r owner wanted; do
        for reader in $(readers "$owner" INBOX); do
          [[ ",$wanted," == *",$reader,"* ]] || doveadm acl delete -u "$owner" INBOX "user=$reader"
        done
        IFS=, read -ra granted <<<"$wanted"
        for reader in "''${granted[@]}"; do
          doveadm acl set -u "$owner" INBOX "user=$reader" lookup read write-seen
        done
        mapfile -t mailboxes < <(doveadm mailbox list -u "$owner" | { grep -v -e '^INBOX$' -e '^Shared$' -e ${lib.escapeShellArg "^Shared${separator}"} || true; })
        # Fact: a mailbox that's made gets a copy of its parent's ACL, which outlives the INBOX's.
        for mailbox in "''${mailboxes[@]}"; do
          for reader in $(readers "$owner" "$mailbox"); do
            [[ ",$wanted," == *",$reader,"* ]] || doveadm acl delete -u "$owner" "$mailbox" "user=$reader"
          done
        done
        doveadm acl recalc -u "$owner"
        # Fact: a client such as Roundcube shows the folders the login subscribes to alone, and doveadm lists none of a
        # reader's shared ones.
        prefix=${lib.escapeShellArg "Shared${separator}"}''${owner%@*}
        for reader in "''${granted[@]}"; do
          doveadm mailbox subscribe -u "$reader" "$prefix" "''${mailboxes[@]/#/$prefix${separator}}"
        done
      done <${shares}
    '';
  };
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
  # Fact: nixos-mailserver's module is a function, which a second mail app on the host would declare the options of
  # again, so the app's host is checked before it's imported.
  imports = builtins.seq app.host [
    o11nInputs.nixos-mailserver.nixosModules.default
    ../nginx.nix
    ../org/mail.nix
    ../postgresql.nix
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
        assertion = admin != null;
        message = "app.${app.name}'s admin, ${app.admin}, hears of what goes wrong, and is no principal's address or alias with an inbox on it: make it one, or set admin under [app.${app.name}].";
      }
      {
        assertion =
          glesys == null
          || lib.all (zone: lib.elem zone (map (domain: domain.name) app.domains)) glesys.zones;
        message = "app.${app.name}.glesys.zones has ${
          lib.concatStringsSep ", " (
            lib.filter (zone: !lib.elem zone (map (domain: domain.name) app.domains)) (
              if glesys == null then [ ] else glesys.zones
            )
          )
        }, which the server isn't the mail of: drop it, or set mail = \"${app.name}\" under its [domain].";
      }
      {
        assertion = glesys == null || app.principal != null && app.keys ? ${glesys.key};
        message = "app.${app.name} keeps its zones' records as its principal, with the API key ${
          if glesys == null then "" else glesys.key
        }: give it an id, and keys.${
          if glesys == null then "" else glesys.key
        } = \"passphrase\", whose secret is the account's key.";
      }
      {
        assertion = app.domains != [ ];
        message = "app.${app.name} is the mail server of no domain: set mail = \"${app.name}\" under the [domain] it serves.";
      }
    ]
    ++ map (entity: {
      assertion = false;
      message = "${entity.handle} has mail at ${entity.principal.mail.address}, on no domain a mail app serves: declare [domain.\"${domainOf entity.principal.mail.address}\"] with mail, or set principal.mail.address.";
    }) unserved
    ++ lib.concatMap (
      entity:
      let
        inherit (entity.principal) mail;
        name = lib.head (lib.splitString "@" mail.address);
      in
      [
        {
          assertion = mail.inbox;
          message = "${entity.handle} has readers but no inbox for them to read: set principal.mail.inbox, or drop principal.mail.readers.";
        }
        {
          assertion = !lib.hasInfix separator name;
          message = "${entity.handle}'s readers see its mailboxes as Shared${separator}${name}, whose ${separator} the mail server takes as a level of folders: change principal.mail.address, or drop principal.mail.readers.";
        }
      ]
      ++ map (
        handle:
        let
          reader = byHandle.${handle} or null;
        in
        {
          assertion =
            reader != null
            && handle != entity.handle
            && reader.principal.mail.inbox
            && domainOf reader.principal.mail.address == domainOf mail.address;
          message = "${entity.handle}'s reader ${handle} is to be another principal with an inbox at an address on ${domainOf mail.address}, the domain the mail server takes from its login for Shared${separator}${name}: change principal.mail.readers.";
        }
      ) mail.readers
    ) (lib.filter (entity: entity.principal.mail.readers != [ ]) mailing)
    ++ lib.concatMap (
      entity:
      let
        inherit (entity.principal) mail;
      in
      [
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
          message = "${entity.handle} sends as ${address}, which is to be an address or @<domain>, on a domain app.${app.name}, its mail server, serves, any address on it only where it has no mailbox, and no other principal's address, alias or sendAs: change principal.mail.sendAs.";
        }
      ) mail.sendAs
    ) mailing;

    sops.secrets =
      lib.listToAttrs (
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
      )
      // lib.optionalAttrs (glesys != null) {
        "${app.name}/${glesys.key}" = {
          inherit (app.secrets) sopsFile;
          owner = app.name;
          group = app.name;
          mode = "0400";
        };
      };

    mailserver = {
      enable = true;
      stateVersion = 3;
      fqdn = app.endpoint;
      storage.path = config.o11n.preserve.onStorage "/var/vmail";
      dkim = {
        keyDirectory = config.o11n.preserve.onStorage "/var/dkim";
        defaults.selector = app.dkimSelector;
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
            aliases = aliasesOf entity;
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
      useACMEHost = config.mailserver.fqdn;
      enableACME = false;
      forceSSL = true;
    };

    services.rspamd.localLuaRules = fromLogin;

    services.dovecot2.settings = lib.mkIf (sharing != [ ]) {
      mail_plugins.acl = true;
      acl_driver = "vfile";
      acl_defaults_from_inbox = true;
      acl_sharing_map."dict file".path = "${config.mailserver.storage.path}/shared-mailboxes.db";
      "namespace shared" = {
        type = "shared";
        inherit separator;
        prefix = "Shared${separator}$username${separator}";
        mail_path = "%{owner_home}/mail";
        mail_index_private_path = "~/shared/%{owner_user}";
        subscriptions = false;
        list = "children";
      };
    };

    systemd.services.mail-readers = lib.mkIf (sharing != [ ]) {
      description = "Grant each principal's readers its mailboxes";
      requires = [ "dovecot.service" ];
      after = [ "dovecot.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [ shares ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = lib.getExe share;
      };
    };

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

    # Policy: a password is tried on submission and imaps, where a principal's own client may mistype it, and on
    # Roundcube's login.
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
        # Dependency: fail2ban's roundcube-auth filter reads Roundcube's own log, which it writes to syslog.
        roundcube-auth.settings = {
          filter = "roundcube-auth";
          backend = "systemd";
          port = "http,https";
          maxretry = 5;
          findtime = "1h";
        };
      };

    # Policy: nothing sends but a principal logged in as itself, on submission alone, whose sender restrictions smtp
    # lacks: no network is trusted to relay, and only root and dovecot, for sieve's redirects and replies, use
    # postfix's sendmail.
    services.postfix = {
      submissionOptions.smtpd_sender_login_maps = lib.mkForce "hash:/etc/postfix/vaccounts,pcre:${senderLogins}";
      settings.main = {
        smtpd_sasl_auth_enable = lib.mkForce false;
        myorigin = domainOf app.admin;
        mynetworks = lib.mkForce [ ];
        authorized_submit_users = [
          "root"
          config.mailserver.storage.owner
        ];
      };
      transport = lib.concatMapStringsSep "\n" (domain: "${domain} smtp:") relayDomains;
    };

    # Policy: the app's url is Roundcube's, where a principal logs in with its own mail password, which Roundcube logs
    # in to imaps and submission with, as its own client would.
    services.roundcube = {
      enable = true;
      hostName = config.mailserver.fqdn;
      maxAttachmentSize = config.mailserver.messageSizeLimit / 1024 / 1024;
      extraConfig = ''
        $config['imap_host'] = 'ssl://${config.mailserver.fqdn}:993';
        $config['smtp_host'] = 'tls://${config.mailserver.fqdn}:587';
        $config['smtp_user'] = '%u';
        $config['smtp_pass'] = '%p';
        $config['product_name'] = ${php org.name};
      '';
    };

    o11n.postgresql.databases.${config.services.roundcube.database.dbname}.user =
      config.services.roundcube.database.username;

    # Policy: the app's principal, with an inbox, is the address the org's rua names, and reads the reports there.
    o11n.mail.failures."${app.name}-dmarc-reports" = lib.mkIf reading app.handle;

    systemd.services."${app.name}-dmarc-reports" = lib.mkIf reading {
      description = "Read the DMARC reports in ${app.principal.mail.address}'s inbox";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      environment = {
        DMARC_SERVER = config.mailserver.fqdn;
        DMARC_LOGIN = app.principal.mail.address;
        DMARC_PASSWORD = config.sops.secrets."${app.name}/mail".path;
        DMARC_RETENTION = toString org.logRetention;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe dmarc;
        User = app.name;
        Group = app.name;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = "@system-service";
      };
    };

    systemd.timers."${app.name}-dmarc-reports" = lib.mkIf reading {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
      };
    };

    o11n.mail.failures."${app.name}-glesys" = lib.mkIf (glesys != null) app.handle;

    systemd.services."${app.name}-glesys" = lib.mkIf (glesys != null) {
      description = "Keep the mail records of ${lib.concatStringsSep ", " glesys.zones} in GleSYS's DNS";
      wantedBy = [ "multi-user.target" ];
      # Dependency: rspamd makes each domain's DKIM key as it starts.
      wants = [
        "network-online.target"
        "rspamd.service"
      ];
      after = [
        "network-online.target"
        "rspamd.service"
      ];
      environment = {
        GLESYS_ACCOUNT = glesys.account;
        GLESYS_KEY = config.sops.secrets."${app.name}/${glesys.key}".path;
        GLESYS_API = "https://api.glesys.com";
        GLESYS_ZONES = pkgs.writeText "${app.name}-glesys-zones.json" (builtins.toJSON zones);
        DKIM_DIR = config.mailserver.dkim.keyDirectory;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe glesysScript;
        User = app.name;
        Group = app.name;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
        ];
      };
    };

    systemd.timers."${app.name}-glesys" = lib.mkIf (glesys != null) {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}
