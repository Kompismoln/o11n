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
    url = "https://cloud.example.com";
    ids = {
      int = 7;
      hex8 = "00000007";
    };
    nextcloud = {
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

  # Fact: as org/apps/nextcloud.nix derives it for a box of carol's on box.example.com, with store-box's
  # smb-password, and a bind of bob's at /srv/pub, who has no box.
  homes = lib.recursiveUpdate app {
    nextcloud.users = {
      carol = true;
      bob = false;
    };
    nextcloud.binds = [
      {
        mountPoint = "/pub";
        user = "bob";
        sharing = false;
        path = "/srv/pub";
      }
    ];
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
      apps = [ "richdocuments" ];
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
          lib.drop 1 (
            lib.splitString " " (lib.concatStringsSep " " (lib.take 4 (lib.splitString "\n" script)))
          )
        );
        alone = lib.all (part: lib.hasInfix part script) [
          "config:app:set user_oidc allow_multiple_user_backends --type=string --value=0"
          ''select(.value.backend == "Database" and .value.enabled)''
          ''user:disable "$user"''
        ];
        settings = {
          inherit (inner.services.nextcloud.settings) user_oidc lost_password_link token_auth_enforced;
        };
        after = inner.systemd.services.nextcloud-oidc.after;
      };
      expected = {
        apps = [
          "richdocuments"
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
        alone = true;
        settings = {
          user_oidc = {
            auto_provision = false;
            soft_auto_provision = false;
          };
          lost_password_link = "disabled";
          token_auth_enforced = true;
        };
        after = [ "nextcloud-setup.service" ];
      };
    };

  # Policy: a nextcloud without a keycloak keeps its own login.
  test_nextcloud_without_keycloak_keeps_its_login = {
    expr = lib.filterAttrs (
      name: _:
      lib.elem name [
        "user_oidc"
        "lost_password_link"
        "token_auth_enforced"
      ]
    ) container.config.services.nextcloud.settings;
    expected = { };
  };

  # Policy: a nextcloud is a drive, whose apps are its files', its settings' and Nextcloud's own, from no app store.
  test_nextcloud_keeps_a_drives_apps =
    let
      kept =
        config:
        let
          script = config.systemd.services.nextcloud-apps.script;
          line = lib.findFirst (lib.hasPrefix "kept=") "" (lib.splitString "\n" script);
        in
        builtins.fromJSON (
          lib.removeSuffix "'" (lib.removePrefix "kept='" (builtins.unsafeDiscardStringContext line))
        );
      inner = container.config;
      oidc = (evalApp logsIn app.principal.uid).containers.cloud.config;
      external = (evalApp mounts app.principal.uid).containers.cloud.config;
    in
    {
      expr = {
        inherit (inner.services.nextcloud) appstoreEnable;
        inherit (inner.services.nextcloud.settings)
          defaultapp
          skeletondirectory
          trashbin_retention_obligation
          versions_retention_obligation
          ;
        own = lib.subtractLists (kept oidc) (kept inner);
        oidc = lib.subtractLists (kept inner) (kept oidc);
        external = lib.subtractLists (kept inner) (kept external);
        calendar = lib.elem "calendar" (kept inner);
        nextcloud = cfg.services.nginx.virtualHosts."cloud.example.com".locations."/".proxyPass;
      };
      expected = {
        appstoreEnable = false;
        defaultapp = "files";
        skeletondirectory = "";
        trashbin_retention_obligation = "auto, 30";
        versions_retention_obligation = "auto, 365";
        own = [
          "password_policy"
          "twofactor_totp"
        ];
        oidc = [ "user_oidc" ];
        external = [ "files_external" ];
        calendar = false;
        nextcloud = "http://[fd12:3456:7890:ffff::bb7:7]:4000";
      };
    };

  # Policy: config.php's secret and passwordsalt are the app's secret-key, which each unit that runs occ loads, its
  # instanceid follows from the app's id, and the container binds no home of the host's.
  test_nextcloud_keeps_its_secret_and_instanceid =
    let
      all = (evalApp (lib.recursiveUpdate mounts logsIn) app.principal.uid).containers.cloud.config;
      units = [
        "nextcloud-apps"
        "nextcloud-office"
        "nextcloud-oidc"
        "nextcloud-external"
        "nextcloud-changes-alice-zhost"
      ];
    in
    {
      expr = {
        bind = {
          inherit (container.bindMounts."/run/secrets/secret-key") hostPath isReadOnly;
        };
        inherit (container.config.services.nextcloud) secrets;
        inherit (container.config.services.nextcloud.settings) instanceid;
        credentials = lib.genAttrs units (
          unit:
          let
            inherit (all.systemd.services.${unit}) serviceConfig;
          in
          {
            inherit (serviceConfig) User LoadCredential;
          }
        );
        home = container.bindMounts ? "/var/lib/nextcloud";
      };
      expected = {
        bind = {
          hostPath = "/run/secrets/cloud/secret-key";
          isReadOnly = true;
        };
        secrets = {
          secret = "/run/secrets/secret-key";
          passwordsalt = "/run/secrets/secret-key";
        };
        instanceid = "oc00000007";
        credentials = lib.genAttrs units (_: {
          User = "nextcloud";
          LoadCredential = [
            "passwordsalt:/run/secrets/secret-key"
            "secret:/run/secrets/secret-key"
          ];
        });
        home = false;
      };
    };

  # Policy: a nextcloud's office is its container's coolwsd, at the app's own url, on a loopback port of the app's,
  # which the app's server serves the office's paths from, and which serves the app alone.
  test_nextcloud_opens_its_own_office =
    let
      unit = container.config.systemd.services.nextcloud-office;
      office = container.config.services.collabora-online;
      inherit (cfg.services.nginx.virtualHosts."cloud.example.com") locations;
    in
    {
      expr = {
        inherit (unit) after;
        sets = lib.all (part: lib.hasInfix part unit.script) [
          "config:app:set richdocuments wopi_url --value=https://cloud.example.com"
          "config:app:delete richdocuments public_wopi_url"
          "config:app:delete richdocuments wopi_callback_url"
        ];
        inherit (office) enable port aliasGroups;
        listens = office.settings.net.listen;
        discovery = locations."^~ /hosting/discovery".proxyPass;
        websocket = locations."~ ^/cool/(.*)/ws$".proxyWebsockets;
      };
      expected = {
        after = [ "nextcloud-setup.service" ];
        sets = true;
        enable = true;
        port = 9987;
        aliasGroups = [
          {
            host = "https://cloud.example.com:443";
            aliases = [ ];
          }
        ];
        listens = "loopback";
        discovery = "http://[::1]:9987";
        websocket = true;
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
        apps = [ "richdocuments" ];
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

  # Policy: a box is the share, which the host mounts as the app's user, with its key's smb-password, and the container
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

  # Policy: a box is its user's data, a bind is mounted at its folder from the directory the container binds, and a
  # user without a box has files no one can write in; o11n makes each of them, and only a box has no quota.
  test_nextcloud_binds_each_storage =
    let
      cfg = evalApp homes app.principal.uid;
      container = cfg.containers.cloud;
      inner = container.config;
      bound = path: { inherit (container.bindMounts.${path}) hostPath isReadOnly; };
      users = inner.systemd.services.nextcloud-users.script;
    in
    {
      expr = {
        box = bound "/var/lib/nextcloud/data/carol";
        bind = bound "/srv/binds/bob/pub";
        files = (bound "/var/lib/nextcloud/data/bob/files").isReadOnly;
        local = lib.hasInfix "/srv/binds/bob/pub" inner.systemd.services.nextcloud-external.script;
        made =
          lib.hasInfix "insert into oc_users" users
          && lib.all (user: lib.hasInfix "'\\''${user}'\\''" users) [
            "bob"
            "carol"
          ];
        quota = {
          carol = lib.hasInfix "user:setting carol files quota none" users;
          bob = lib.hasInfix "user:setting bob files" users;
          default = lib.hasInfix "config:app:set files default_quota --value='0 B'" users;
        };
        local_allowed = inner.services.nextcloud.settings.files_external_allow_create_new_local;
      };
      expected = {
        box = {
          hostPath = "/var/lib/cloud/nextcloud/data/carol";
          isReadOnly = false;
        };
        bind = {
          hostPath = "/srv/pub";
          isReadOnly = false;
        };
        files = true;
        local = true;
        made = true;
        quota = {
          carol = true;
          bob = false;
          default = true;
        };
        local_allowed = true;
      };
    };
}
