{
  app,
  config,
  lib,
  org,
  pkgs,
  ...
}:

let
  cfg = {
    inherit (app)
      name
      endpoint
      database
      ssl
      ;
    inherit (app.principal) bindAddress uid gid;
    home = "${app.principal.home}/immich";
    cache = config.o11n.preserve.onStorage "/var/cache/${app.name}";
    port = 2283;
    learningPort = 3003;
    user = app.name;
  };

  hostConfig = config;
  postgresql = config.services.postgresql.package;
  pgPort = toString config.services.postgresql.settings.port;
  inherit (app.principal) mail;

  # Dependency: org/apps/immich.nix derives the client, which the keycloak app keeps.
  inherit (app.immich) client shares;
  keycloak = org.app.${client.keycloak};
  realm = keycloak.keycloak.realms.${client.realm} or { displayName = client.realm; };
  libraries = lib.attrNames app.immich.storages;

  media = "/var/lib/immich";
  secret = "/run/secrets/oidc-secret";
  mailSecret = "/run/secrets/mail";
  libraryOf = user: "${cfg.home}/library/${user}";
  passwordOf = handle: "${app.name}/${handle}/smb-password";
  credentialsOf = user: "${app.name}/${user}-smb-credentials";
  local = "http://[${cfg.bindAddress}]:${toString cfg.port}";
  sending = mail.send && org.mailserver != null;

  psql = "${postgresql}/bin/psql -h /run/postgresql -p ${pgPort} -d ${cfg.database} -qtAX -v ON_ERROR_STOP=1";

  # Policy: a user's library is their storage label, the Keycloak username they first logged in with, which no one
  # changes; one with a box has no quota, as the box is their library, and any other a quota of nothing, as their
  # library would be the app's state.
  # Fact: Immich makes a user as they first log in, with no hook but its database, and reads the quota from there at
  # each request.
  quotas = pkgs.writeText "${cfg.name}-quotas.sql" ''
    create schema if not exists o11n;
    create or replace function o11n.immich_quota(label text) returns bigint language sql immutable as $$
      select case when label = any(${
        if libraries == [ ] then
          "array[]::text[]"
        else
          "array[${lib.concatMapStringsSep ", " (user: "'${user}'") libraries}]"
      }) then null else 0 end
    $$;
    create or replace function o11n.immich_user() returns trigger language plpgsql as $$
    begin
      if tg_op = 'UPDATE' then
        new."storageLabel" := old."storageLabel";
      end if;
      new."quotaSizeInBytes" := o11n.immich_quota(new."storageLabel");
      return new;
    end $$;
    create or replace trigger o11n_immich_user before insert or update of "quotaSizeInBytes", "storageLabel"
      on "user" for each row execute function o11n.immich_user();
    update "user" set "quotaSizeInBytes" = null
      where "quotaSizeInBytes" is distinct from o11n.immich_quota("storageLabel");
  '';

  # Policy: the app is Immich's admin, at its own address, which no one logs in as: password logins are off, and the
  # realm can't link to it by its address, as it has an OAuth id the realm gives no one.
  # Fact: Immich makes a user of the realm's only once it has an admin.
  users = pkgs.writeShellApplication {
    name = "${cfg.name}-users";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.curl
      pkgs.jq
      postgresql
    ];
    text = ''
      until curl -gsf -o /dev/null ${lib.escapeShellArg "${local}/api/server/ping"}; do
        sleep 1
      done
      if [[ $(${psql} -c 'select exists (select from "user" where "isAdmin")') != t ]]; then
        jq -n --arg email ${lib.escapeShellArg mail.address} --arg password "$(head -c 32 /dev/urandom | base64)" \
          '{email: $email, password: $password, name: "${cfg.name}"}' |
          curl -gsS --fail-with-body -o /dev/null -H 'Content-Type: application/json' --data-binary @- \
            ${lib.escapeShellArg "${local}/api/auth/admin-sign-up"}
      fi
      ${psql} -c ${lib.escapeShellArg ''update "user" set "oauthId" = 'o11n' where "isAdmin" and email = lower('${mail.address}')''}
      ${psql} -f ${quotas}
    '';
  };

  # Policy: what's declared is the app's settings, which Immich then reads from its config file alone, its admin
  # pages showing them as they are; the realm is the only way in, and its login page sends to it.
  settings = {
    server.externalDomain = app.url;
    newVersionCheck.enabled = false;
    passwordLogin.enabled = false;
    oauth = {
      enabled = true;
      issuerUrl = "${keycloak.url}/realms/${client.realm}";
      inherit (client.representation) clientId;
      clientSecret._secret = secret;
      autoRegister = true;
      autoLaunch = true;
      buttonText = "Log in with ${realm.displayName}";
      defaultStorageQuota = 0;
      accountManagementUrl = "${keycloak.url}/realms/${client.realm}/account";
      allowInsecureRequests = !keycloak.ssl;
    };
    # Policy: originals are filed by the day they were taken, so that a file stays where it's filed.
    storageTemplate = {
      enabled = true;
      hashVerificationEnabled = true;
      template = "{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}";
    };
    # Policy: the database is dumped into the app's home as any other, rather than into Immich's own backups.
    backup.database.enabled = false;
    machineLearning.urls = [ "http://[${cfg.bindAddress}]:${toString cfg.learningPort}" ];
  }
  // lib.optionalAttrs sending {
    # Dependency: nixos/services/mailserver.nix serves submission as mail.<endpoint>, on 587 with STARTTLS.
    notifications.smtp = {
      enabled = true;
      from = mail.address;
      replyTo = mail.address;
      transport = {
        host = "mail.${org.mailserver.endpoint}";
        port = 587;
        secure = false;
        username = mail.address;
        password._secret = mailSecret;
      };
    };
  };
in
{
  imports = [
    ../postgresql.nix
  ];

  config = {
    assertions = [
      {
        assertion = keycloak.kind == "keycloak";
        message = "${app.handle} logs in with ${client.keycloak}, which isn't a keycloak: name one under [app.${app.name}] immich.keycloak.";
      }
    ]
    ++ map (user: {
      assertion = builtins.match "[a-z0-9][a-z0-9._-]*" user != null && user != "admin";
      message = "immich ${cfg.name}'s user ${user} has a library named after them, which Immich files as their storage label: name a Keycloak username of lowercase letters, digits, '.', '_' and '-', other than admin, the app's own.";
    }) libraries;

    o11n.postgresql = {
      databases.${cfg.database} = { inherit (cfg) user; };
      # Fact: the container reaches it through a bind of /run/postgresql, which postgresql makes anew each time it
      # starts.
      containers = [ cfg.name ];
    };

    # Fact: Immich needs VectorChord preloaded, and its extensions made by a superuser, as postgresql-setup does each
    # time it starts, and its vector indexes rebuilt as VectorChord changes, as nixpkgs' immich has it.
    services.postgresql = {
      extensions = ps: [
        ps.pgvector
        ps.vectorchord
      ];
      settings.shared_preload_libraries = [ "vchord.so" ];
    };
    systemd.services.postgresql-setup.serviceConfig.ExecStartPost =
      let
        extensions = [
          "unaccent"
          "uuid-ossp"
          "cube"
          "earthdistance"
          "pg_trgm"
          "vector"
          "vchord"
        ];
        sql = pkgs.writeText "${cfg.name}-extensions.sql" ''
          select coalesce(installed_version, ''') as vchord_before from pg_available_extensions where name = 'vchord' \gset
          ${lib.concatMapStrings (ext: ''
            create extension if not exists "${ext}";
            alter extension "${ext}" update;
          '') extensions}
          select coalesce(installed_version, ''') as vchord_after from pg_available_extensions where name = 'vchord' \gset
          select (:'vchord_before' != ''' and :'vchord_before' != :'vchord_after') as vchord_changed \gset
          \if :vchord_changed
            reindex index face_index;
            reindex index clip_index;
          \endif
        '';
      in
      [ "${postgresql}/bin/psql -p ${pgPort} -d ${cfg.database} -v ON_ERROR_STOP=1 -f ${sql}" ];

    sops.secrets = {
      ${client.secret.name} = {
        inherit (client.secret) sopsFile;
        owner = app.name;
        group = app.name;
      };
    }
    // lib.listToAttrs (
      map (
        share:
        lib.nameValuePair (passwordOf share.key.handle) {
          inherit (share.key.secret) sopsFile;
          key = share.key.secret.name;
        }
      ) shares
    );

    sops.templates = lib.listToAttrs (
      map (
        share:
        lib.nameValuePair (credentialsOf share.user) {
          content = ''
            username=${share.login}
            password=${config.sops.placeholder.${passwordOf share.key.handle}}
          '';
        }
      ) shares
    );

    system.fsPackages = lib.optional (shares != [ ]) pkgs.cifs-utils;

    # Policy: a box is mounted as the app's user at its user's library, and the container starts only once each is,
    # so that Immich never files a user's originals into the directory beneath.
    # Fact: a mount unit, unlike fileSystems, which a NixOS test's VM replaces with its own.
    systemd.mounts = map (share: {
      what = "//${share.host}/${share.share}";
      where = libraryOf share.user;
      type = "cifs";
      options = lib.concatStringsSep "," [
        "credentials=${config.sops.templates.${credentialsOf share.user}.path}"
        "uid=${toString cfg.uid}"
        "gid=${toString cfg.gid}"
        "dir_mode=0750"
        "file_mode=0640"
        "vers=3.1.1"
        "seal"
      ];
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
    }) shares;

    # Fact: nspawn refuses to start a container whose bind's host path is missing.
    # Policy: an archive of the app's state leaves out the thumbnails and the videos encoded for the web, which Immich
    # makes anew of the originals.
    systemd.tmpfiles.rules = [
      "f+ '${app.principal.home}/.resticignore' 0644 ${cfg.user} ${cfg.user} - immich/thumbs/\\nimmich/encoded-video/\\n"
      "d '${cfg.home}' 0700 ${cfg.user} ${cfg.user} - -"
      "d '${cfg.home}/library' 0700 ${cfg.user} ${cfg.user} - -"
      "d '${cfg.cache}' 0700 ${cfg.user} ${cfg.user} - -"
    ];

    systemd.services."container@${cfg.name}" = {
      # Fact: the container binds each secret's file as it starts, and a switch to another of its values restarts
      # nothing, as NixOS 26.11's activation no longer restarts what restartUnits names.
      restartTriggers = map (file: builtins.hashFile "sha256" file) (
        lib.unique ([ client.secret.sopsFile ] ++ lib.optional sending app.secrets.sopsFile)
      );
      unitConfig.RequiresMountsFor = map (share: libraryOf share.user) shares;
      serviceConfig = {
        TimeoutStopSec = 10;
        KillMode = "mixed";
      };
    };

    # Fact: as immich's docs have nginx: uploads of any size, which take long, and its socket.io.
    services.nginx.virtualHosts.${cfg.endpoint} = {
      forceSSL = cfg.ssl;
      enableACME = cfg.ssl;
      extraConfig = ''
        client_max_body_size 50000M;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;
        send_timeout 600s;
      '';
      locations."/" = {
        proxyPass = local;
        proxyWebsockets = true;
        recommendedProxySettings = true;
      };
    };

    containers.${cfg.name} = {
      autoStart = true;
      ephemeral = true;

      bindMounts = {
        ${media} = {
          hostPath = cfg.home;
          isReadOnly = false;
        };
        "/var/cache/immich" = {
          hostPath = cfg.cache;
          isReadOnly = false;
        };
        "/run/postgresql" = {
          isReadOnly = false;
        };
        ${secret} = {
          hostPath = config.sops.secrets.${client.secret.name}.path;
          isReadOnly = true;
        };
      }
      // lib.optionalAttrs sending {
        # Dependency: nixos/org/mail.nix declares the password of a principal that sends.
        ${mailSecret} = {
          hostPath = config.sops.secrets."${app.name}/mail".path;
          isReadOnly = true;
        };
      }
      // lib.listToAttrs (
        map (
          share:
          lib.nameValuePair "${media}/library/${share.user}" {
            hostPath = libraryOf share.user;
            isReadOnly = false;
          }
        ) shares
      );

      config = {
        system = {
          inherit (hostConfig.system) stateVersion;
        };

        # Fact: libpq logs in as the name of the user it runs as, which the host's postgresql authenticates by its uid.
        users = {
          users.${cfg.user} = {
            inherit (cfg) uid;
            group = cfg.user;
            isSystemUser = true;
          };
          groups.${cfg.user}.gid = cfg.gid;
        };

        environment.systemPackages = [ postgresql ];

        services.immich = {
          enable = true;
          inherit (cfg) user port;
          group = cfg.user;
          host = cfg.bindAddress;
          mediaLocation = media;
          database = {
            enable = false;
            name = cfg.database;
            inherit (cfg) user;
            port = config.services.postgresql.settings.port;
            package = postgresql;
          };
          inherit settings;
          # Policy: the server and its machine learning each listen on the app's own address, as each immich on a host
          # shares its network.
          machine-learning.environment = {
            IMMICH_HOST = lib.mkForce cfg.bindAddress;
            IMMICH_PORT = lib.mkForce (toString cfg.learningPort);
          };
        };

        systemd.services.immich-users = {
          description = "keep ${cfg.name}'s admin, and its users' libraries and quotas, as declared";
          after = [ "immich-server.service" ];
          requires = [ "immich-server.service" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = cfg.user;
            Group = cfg.user;
            ExecStart = lib.getExe users;
            TimeoutStartSec = 300;
          };
        };
      };
    };
  };
}
