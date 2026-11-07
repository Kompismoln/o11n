{
  lib,
  evalNixosModule,
}:
let
  app = {
    name = "cloud";
    endpoint = "cloud.example.com";
    database = "cloud";
    ssl = true;
    scheme = "https";
    principal = {
      home = "/var/lib/cloud";
      bindAddress = "fd12:3456:7890:ffff::bb7:7";
      uid = 3007;
      gid = 3007;
    };
    secrets.sopsFile = "/enc/app-cloud.yaml";
    nextcloud = {
      collabora = "office";
      client = null;
    };
  };

  # Fact: as org/apps/nextcloud.nix derives it for nextcloud.keycloak = "auth" and nextcloud.realm = "example".
  logsIn = lib.recursiveUpdate app {
    nextcloud.client = {
      keycloak = "auth";
      realm = "example";
      app = "app-cloud";
      secret = {
        name = "cloud/oidc-secret";
        inherit (app.secrets) sopsFile;
      };
      representation.clientId = "cloud";
    };
  };

  # Fact: as org/apps/nextcloud.nix derives it for nextcloud.allotments = [ "user-alice@zhost" ], run on web.
  mounts = lib.recursiveUpdate app {
    publicKeys.sftp-key = ../inventories/allotments/public-keys/app-cloud-sftp-key.pub;
    nextcloud.mounts.web = [
      {
        name = "user-alice@zhost";
        entity = "user-alice";
        host = "zhost";
        user = "alice";
        address = "fd12:3456:7890:0000::0001";
        from = "fd12:3456:7890:0000::0002";
        chroot = "/srv/allotments";
        root = "/user-alice";
        mountPoint = "/zhost";
      }
    ];
  };

  evalApp =
    app: uid:
    evalNixosModule [
      ../../nixos/apps/nextcloud.nix
      {
        # Accommodating for sops-nix and preservation, which this evaluation doesn't import: what the app
        # declares there is only declared, at the paths sops-nix would give it.
        options.sops.secrets = lib.mkOption {
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
        options.o11n.preserve.directories = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [ ];
        };
        config = {
          _module.args = {
            inherit app;
            org = {
              postgres = "17";
              app = {
                office.endpoint = "office.example.com";
                auth = {
                  url = "https://auth.example.com";
                  keycloak.realms.example.displayName = "Example";
                };
              };
            };
            host.name = "web";
          };
          users.users.cloud = {
            isSystemUser = true;
            group = "cloud";
            home = "/var/lib/cloud";
            inherit uid;
          };
          users.groups.cloud = { };
          system.stateVersion = lib.trivial.release;
        };
      }
    ];

  eval = evalApp app;

  failed =
    cfg:
    lib.filter (lib.hasPrefix "Nextcloud ") (
      map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) cfg.assertions)
    );

  cfg = eval app.principal.uid;
  container = cfg.containers.cloud;
in
{
  # Policy: the container reaches the host's postgresql through its socket, with no password.
  test_nextcloud_peer = {
    expr = {
      socket = container.bindMounts."/run/postgresql" or null;
      password = container.bindMounts ? "/run/secrets/db-password";
      inherit (container.config.services.nextcloud.config) dbhost dbuser dbpassFile;
      failed = failed cfg;
    };
    expected = {
      socket = {
        hostPath = null;
        isReadOnly = false;
        mountPoint = "/run/postgresql";
      };
      password = false;
      dbhost = "/run/postgresql";
      dbuser = "cloud";
      dbpassFile = null;
      failed = [ ];
    };
  };

  test_nextcloud_peer_needs_the_uid = {
    expr = failed (eval 3008);
    expected = [
      "Nextcloud cloud connects to postgresql as the host's user cloud, whose uid has to be 3007."
    ];
  };

  test_nextcloud_without_keycloak_logs_in_alone = {
    expr = {
      oidc = container.config.systemd.services ? nextcloud-oidc;
      secret = container.bindMounts ? "/run/secrets/oidc-secret";
      apps = lib.attrNames container.config.services.nextcloud.extraApps;
    };
    expected = {
      oidc = false;
      secret = false;
      apps = [ "calendar" ];
    };
  };

  # Policy: a nextcloud with a keycloak has its users log in with the realm, as the Keycloak user of their name.
  test_nextcloud_logs_in_with_keycloak =
    let
      cfg = evalApp logsIn app.principal.uid;
      inner = cfg.containers.cloud.config;
      script = inner.systemd.services.nextcloud-oidc.script;
    in
    {
      expr = {
        apps = lib.attrNames inner.services.nextcloud.extraApps;
        secret = {
          inherit (cfg.containers.cloud.bindMounts."/run/secrets/oidc-secret") hostPath isReadOnly;
          inherit (cfg.sops.secrets."cloud/oidc-secret") sopsFile owner;
        };
        provider = lib.filter (word: word != "" && word != "\\") (
          lib.drop 1 (lib.splitString " " (lib.replaceStrings [ "\n" ] [ " " ] script))
        );
        after = inner.systemd.services.nextcloud-oidc.after;
      };
      expected = {
        apps = [
          "calendar"
          "user_oidc"
        ];
        secret = {
          hostPath = "/run/secrets/cloud/oidc-secret";
          isReadOnly = true;
          sopsFile = "/enc/app-cloud.yaml";
          owner = "cloud";
        };
        provider = [
          "user_oidc:provider"
          "Example"
          "--clientid=cloud"
          "--clientsecret-file=/run/secrets/oidc-secret"
          "--discoveryuri=https://auth.example.com/realms/example/.well-known/openid-configuration"
          "--unique-uid=0"
          "--mapping-uid=preferred_username"
        ];
        after = [ "nextcloud-setup.service" ];
      };
    };

  # Policy: a nextcloud with allotments keeps a mount of each, which logs in with the app's sftp-key.
  test_nextcloud_mounts_allotments =
    let
      cfg = evalApp mounts app.principal.uid;
      inner = cfg.containers.cloud.config;
      unit = inner.systemd.services.nextcloud-allotments;
    in
    {
      expr = {
        apps = lib.attrNames inner.services.nextcloud.extraApps;
        secret = {
          inherit (cfg.containers.cloud.bindMounts."/run/secrets/sftp-key") hostPath isReadOnly;
          inherit (cfg.sops.secrets."cloud/sftp-key") sopsFile owner;
        };
        inherit (unit) after;
        declares = lib.all (part: lib.hasInfix part unit.script) [
          "files_external:import -"
          "--rawfile key /run/secrets/sftp-key"
          ''"host":"[fd12:3456:7890:0000::0001]"''
          ''"root":"/user-alice"''
          ''"user":"alice"''
          ''"applicable_users":["alice"]''
          ''"mount_point":"/zhost"''
        ];
      };
      expected = {
        apps = [ "calendar" ];
        secret = {
          hostPath = "/run/secrets/cloud/sftp-key";
          isReadOnly = true;
          sopsFile = "/enc/app-cloud.yaml";
          owner = "cloud";
        };
        after = [ "nextcloud-setup.service" ];
        declares = true;
      };
    };

  test_nextcloud_without_allotments_mounts_none = {
    expr = {
      unit = container.config.systemd.services ? nextcloud-allotments;
      secret = container.bindMounts ? "/run/secrets/sftp-key";
    };
    expected = {
      unit = false;
      secret = false;
    };
  };
}
