{
  lib,
  evalNixosModule,
}:
let
  app = {
    name = "auth";
    handle = "app-auth";
    endpoint = "auth.example.com";
    database = "auth";
    ssl = true;
    principal = {
      bindAddress = "fd12:3456:7890:1::1";
      mail = {
        address = "auth@example.com";
        inbox = true;
        send = true;
      };
    };
    secrets.sopsFile = ../inventories/mail/enc/app-auth.yaml;
    keycloak.realms.example.displayName = "Example";
  };

  apps = realm: {
    meet = {
      kind = "jitsi";
      jitsi.client = {
        keycloak = "auth";
        inherit realm;
        app = "app-meet";
        representation.clientId = "meet";
      };
    };
    cloud = {
      kind = "nextcloud";
      nextcloud.client = {
        keycloak = "auth";
        inherit realm;
        app = "app-cloud";
        secret = {
          name = "cloud/oidc-secret";
          sopsFile = ../inventories/mail/enc/app-cloud.yaml;
        };
        representation.clientId = "cloud";
      };
    };
    elsewhere = {
      kind = "nextcloud";
      nextcloud.client = null;
    };
    blog = {
      kind = "wordpress";
      wordpress = { };
    };
    other.kind = null;
  };

  evalWith =
    realm: app:
    evalNixosModule [
      ../../nixos/apps/keycloak.nix
      {
        # Accommodating for sops-nix, which this evaluation doesn't import: what the app declares there is only
        # declared, at the paths sops-nix would give it.
        options.sops = {
          secrets = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  freeformType = lib.types.attrsOf lib.types.anything;
                  options.path = lib.mkOption { default = "/run/secrets/${name}"; };
                }
              )
            );
            default = { };
          };
          templates = lib.mkOption {
            type = lib.types.attrsOf (
              lib.types.submodule (
                { name, ... }:
                {
                  freeformType = lib.types.attrsOf lib.types.anything;
                  options.path = lib.mkOption { default = "/run/secrets/rendered/${name}"; };
                }
              )
            );
            default = { };
          };
          placeholder = lib.mkOption {
            type = lib.types.attrsOf lib.types.str;
            default = { };
          };
        };
        config = {
          _module.args = {
            inherit app;
            org = {
              postgres = "17";
              mailserver.endpoint = "example.com";
              app = apps realm;
            };
            host.name = "web";
          };
          sops.placeholder."auth/admin-client-secret" = "<admin-client-secret>";
          # Duplication: as nixos/org/mail.nix declares it.
          sops.secrets."auth/mail" = { };
          users.users.auth = {
            isSystemUser = true;
            group = "auth";
            home = "/var/lib/auth";
          };
          users.groups.auth = { };
          system.stateVersion = lib.trivial.release;
        };
      }
    ];

  eval = evalWith "example";

  failed =
    cfg:
    map (assertion: assertion.message) (
      lib.filter (
        assertion:
        !assertion.assertion
        && lib.any (prefix: lib.hasPrefix prefix assertion.message) [
          "app-auth"
          "app-meet"
        ]
      ) cfg.assertions
    );

  cfg = eval app;
  vhost = cfg.services.nginx.virtualHosts."auth.example.com";
  realms = cfg.systemd.services.keycloak-realms;
  declared = lib.head (builtins.fromJSON realms.environment.REALMS);
in
{
  test_keycloak_settings_derived = {
    expr = {
      inherit (cfg.services.keycloak.settings)
        hostname
        http-host
        http-port
        http-enabled
        proxy-headers
        ;
    };
    expected = {
      hostname = "auth.example.com";
      http-host = "fd12:3456:7890:1::1";
      http-port = 8080;
      http-enabled = true;
      proxy-headers = "xforwarded";
    };
  };

  test_keycloak_vhost_ssl = {
    expr = {
      inherit (vhost) forceSSL enableACME;
    };
    expected = {
      forceSSL = true;
      enableACME = true;
    };
  };

  test_keycloak_login_proxy_pass = {
    expr = vhost.locations."/".proxyPass;
    expected = "http://[fd12:3456:7890:1::1]:8080";
  };

  # Policy: Keycloak runs as the app, owning its database, whose dump is in the app's home.
  test_keycloak_runs_as_the_app = {
    expr = {
      database = cfg.o11n.postgresql.databases.auth.user;
      inherit (cfg.systemd.services.keycloak.serviceConfig) User Group;
      dump = cfg.o11n.dumps.auth-pgsql.path;
    };
    expected = {
      database = "auth";
      User = "auth";
      Group = "auth";
      dump = "/var/lib/auth/dbdump.sql";
    };
  };

  # Policy: the client o11n acts as is bootstrapped with the app's admin-client-secret, and no admin password is.
  test_keycloak_bootstraps_the_client = {
    expr = {
      bootstrap = cfg.sops.templates."auth-bootstrap.env".content;
      password = cfg.services.keycloak.initialAdminPassword;
      environment = cfg.systemd.services.keycloak.serviceConfig.EnvironmentFile;
    };
    expected = {
      bootstrap = ''
        KC_BOOTSTRAP_ADMIN_CLIENT_ID=o11n
        KC_BOOTSTRAP_ADMIN_CLIENT_SECRET=<admin-client-secret>
      '';
      password = null;
      environment = "/run/secrets/rendered/auth-bootstrap.env";
    };
  };

  test_keycloak_realm_sends_as_the_app = {
    expr = {
      inherit (declared)
        realm
        displayName
        registrationAllowed
        editUsernameAllowed
        smtpServer
        ;
      credentials = realms.serviceConfig.LoadCredential;
      failed = failed cfg;
      secret = cfg.sops.secrets."cloud/oidc-secret".sopsFile;
      restarts = realms.restartTriggers;
    };
    expected = {
      realm = "example";
      displayName = "Example";
      registrationAllowed = false;
      editUsernameAllowed = false;
      smtpServer = {
        host = "mail.example.com";
        port = "587";
        starttls = "true";
        ssl = "false";
        auth = "true";
        user = "auth@example.com";
        from = "auth@example.com";
        fromDisplayName = "Example";
      };
      credentials = [
        "admin-client-secret:/run/secrets/auth/admin-client-secret"
        "mail:/run/secrets/auth/mail"
        "client-cloud:/run/secrets/cloud/oidc-secret"
      ];
      failed = [ ];
      secret = ../inventories/mail/enc/app-cloud.yaml;
      restarts = map (file: builtins.hashFile "sha256" file) [
        ../inventories/mail/enc/app-auth.yaml
        ../inventories/mail/enc/app-cloud.yaml
      ];
    };
  };

  test_keycloak_realm_needs_an_inbox = {
    expr = failed (eval (lib.recursiveUpdate app { principal.mail.inbox = false; }));
    expected = [
      "app-auth's realms send mail, as for a password reset, which Keycloak tests by mailing the app itself: set principal.mail = { inbox = true, send = true } under [app.auth]."
    ];
  };

  test_keycloak_without_realms_keeps_none = {
    expr = (eval (app // { keycloak.realms = { }; })).systemd.services ? keycloak-realms;
    expected = false;
  };

  # Policy: the keycloak an app names keeps the client its kind derives, in the realm it names.
  test_keycloak_keeps_the_clients_of_the_apps_that_name_it = {
    expr = builtins.fromJSON realms.environment.CLIENTS;
    expected = [
      {
        realm = "example";
        representation.clientId = "cloud";
        secret = true;
      }
      {
        realm = "example";
        representation.clientId = "meet";
        secret = false;
      }
    ];
  };

  test_keycloak_client_in_a_realm_it_keeps = {
    expr = failed (evalWith "jitsi-realm" app);
    expected = [
      "app-meet's client is in the realm jitsi-realm, which app-auth doesn't keep: add keycloak.realms.jitsi-realm under [app.auth], or name one it keeps."
    ];
  };
}
