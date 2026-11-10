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

  # Fact: as org/apps/nextcloud.nix derives it, run on web, for an external zhost of alice's allotment there, and an
  # external files of bob's on an sftp server, logging in with store-files' sftp-key.
  mounts = lib.recursiveUpdate app {
    nextcloud.mounts.web = [
      {
        mountPoint = "/zhost";
        user = "alice";
        sharing = true;
        server = {
          host = "10.0.0.1";
          login = "alice";
          root = "/user-alice";
          changes = {
            login = "allotment-changes";
            id = "user-alice.zhost";
            hostKey = ../inventories/allotments/public-keys/host-zhost-ssh-key.pub;
          };
        };
        key = {
          handle = "app-cloud";
          secret = {
            name = "cloud/sftp-key";
            inherit (app.secrets) sopsFile;
          };
          publicKey = ../inventories/allotments/public-keys/app-cloud-sftp-key.pub;
        };
      }
      {
        mountPoint = "/files";
        user = "bob";
        sharing = false;
        server = {
          host = "files.example.com";
          login = "archive";
          root = "/";
          changes = null;
        };
        key = {
          handle = "store-files";
          secret = {
            name = "files/sftp-key";
            sopsFile = "/enc/store-files.yaml";
          };
          publicKey = ../inventories/allotments/public-keys/store-files-sftp-key.pub;
        };
      }
    ];
  };

  # Fact: as org/apps/nextcloud.nix derives it for a home of carol's on box.example.com, with store-box's
  # smb-password.
  homes = lib.recursiveUpdate app {
    nextcloud.shares = [
      {
        user = "carol";
        host = "box.example.com";
        share = "carol";
        login = "carol";
        key = {
          handle = "store-box";
          secret = {
            name = "box/smb-password";
            sopsFile = "/enc/store-box.yaml";
          };
        };
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
        options.sops.templates = lib.mkOption {
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
        options.sops.placeholder = lib.mkOption {
          type = lib.types.lazyAttrsOf lib.types.str;
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
          sops.placeholder."cloud/store-box/smb-password" = "<smb-password>";
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

  # Policy: a nextcloud keeps each of its external storages, which logs in with its key's sftp-key.
  test_nextcloud_keeps_its_external_storages =
    let
      cfg = evalApp mounts app.principal.uid;
      inner = cfg.containers.cloud.config;
      unit = inner.systemd.services.nextcloud-external;
    in
    {
      expr = {
        apps = lib.attrNames inner.services.nextcloud.extraApps;
        secrets = lib.mapAttrs (handle: _: {
          inherit (cfg.containers.cloud.bindMounts."/run/secrets/sftp-keys/${handle}") hostPath isReadOnly;
          inherit (cfg.sops.secrets."cloud/${handle}/sftp-key") sopsFile key owner;
        }) (lib.genAttrs [ "app-cloud" "store-files" ] lib.id);
        inherit (unit) after;
        declares = lib.all (part: lib.hasInfix part unit.script) [
          "files_external:import -"
          "--rawfile key /run/secrets/sftp-keys/app-cloud"
          "--rawfile key /run/secrets/sftp-keys/store-files"
          ''"host":"10.0.0.1"''
          ''"root":"/user-alice"''
          ''"user":"alice"''
          ''"applicable_users":["alice"]''
          ''"mount_point":"/zhost"''
          ''"options":{"enable_sharing":true}''
          ''"host":"files.example.com"''
          ''"applicable_users":["bob"]''
          ''"public_key":"${lib.trim (builtins.readFile ../inventories/allotments/public-keys/store-files-sftp-key.pub)}"''
        ];
        failed = failed cfg;
      };
      expected = {
        apps = [ "calendar" ];
        secrets = {
          app-cloud = {
            hostPath = "/run/secrets/cloud/app-cloud/sftp-key";
            isReadOnly = true;
            sopsFile = "/enc/app-cloud.yaml";
            key = "cloud/sftp-key";
            owner = "cloud";
          };
          store-files = {
            hostPath = "/run/secrets/cloud/store-files/sftp-key";
            isReadOnly = true;
            sopsFile = "/enc/store-files.yaml";
            key = "files/sftp-key";
            owner = "cloud";
          };
        };
        after = [ "nextcloud-setup.service" ];
        declares = true;
        failed = [ ];
      };
    };

  # Policy: a home is the share, which the host mounts as the app's user, with its key's smb-password, and the container
  # starts only once it's mounted.
  test_nextcloud_mounts_a_home =
    let
      cfg = evalApp homes app.principal.uid;
      data = "/var/lib/cloud/nextcloud/data/carol";
    in
    {
      expr = {
        mount = {
          inherit (cfg.fileSystems.${data}) device fsType;
          options = lib.filter (
            option:
            lib.any (prefix: lib.hasPrefix prefix option) [
              "credentials="
              "uid="
              "gid="
              "seal"
              "nofail"
            ]
          ) cfg.fileSystems.${data}.options;
        };
        credentials = cfg.sops.templates."cloud/carol-smb-credentials".content;
        secret = {
          inherit (cfg.sops.secrets."cloud/store-box/smb-password") sopsFile key;
        };
        requires = lib.elem data cfg.systemd.services."container@cloud".unitConfig.RequiresMountsFor;
        status = map (package: package.name) (
          lib.filter (
            package: lib.hasPrefix "nextcloud-status-" (package.name or "")
          ) cfg.environment.systemPackages
        );
      };
      expected = {
        mount = {
          device = "//box.example.com/carol";
          fsType = "cifs";
          options = [
            "credentials=/run/secrets/rendered/cloud/carol-smb-credentials"
            "uid=3007"
            "gid=3007"
            "seal"
            "nofail"
          ];
        };
        credentials = ''
          username=carol
          password=<smb-password>
        '';
        secret = {
          sopsFile = "/enc/store-box.yaml";
          key = "box/smb-password";
        };
        requires = true;
        status = [ "nextcloud-status-cloud" ];
      };
    };

  # Policy: a nextcloud checks each storage for changes as a folder is opened, and scans a mount of an allotment with
  # replicas as it follows what they change there, by ssh with the mount's key, verifying its host's ssh-key.
  test_nextcloud_follows_changes =
    let
      inner = (evalApp mounts app.principal.uid).containers.cloud.config;
      unit = inner.systemd.services.nextcloud-changes-alice-zhost;
    in
    {
      expr = {
        inherit (inner.services.nextcloud.settings) filesystem_check_changes;
        inherit (unit) after;
        inherit (unit.serviceConfig) User;
        follows = lib.all (part: lib.hasInfix part unit.script) [
          "files:scan --verbose --no-interaction --path=alice/files/zhost"
          "-i /run/secrets/sftp-keys/app-cloud"
          "-o StrictHostKeyChecking=yes"
          "-o ConnectTimeout=10"
          "allotment-changes@10.0.0.1 user-alice.zhost"
        ];
        others = lib.filter (lib.hasPrefix "nextcloud-changes-") (lib.attrNames inner.systemd.services);
      };
      expected = {
        filesystem_check_changes = 1;
        after = [ "nextcloud-external.service" ];
        User = "nextcloud";
        follows = true;
        others = [ "nextcloud-changes-alice-zhost" ];
      };
    };

  test_nextcloud_without_external_storages_mounts_none = {
    expr = {
      unit = container.config.systemd.services ? nextcloud-external;
      follows = lib.filter (lib.hasPrefix "nextcloud-changes-") (
        lib.attrNames container.config.systemd.services
      );
      homes = lib.filter (lib.hasPrefix "/var/lib/cloud") (lib.attrNames cfg.fileSystems);
      status = lib.any (
        package: lib.hasPrefix "nextcloud-status-" (package.name or "")
      ) cfg.environment.systemPackages;
      secrets = lib.filter (lib.hasPrefix "/run/secrets/sftp-keys/") (lib.attrNames container.bindMounts);
    };
    expected = {
      unit = false;
      follows = [ ];
      homes = [ ];
      status = false;
      secrets = [ ];
    };
  };
}
