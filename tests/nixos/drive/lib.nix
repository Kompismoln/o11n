{ lib, evalNixosModule }:
rec {
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
    secrets.sopsFile = ../../inventories/allotments/enc/app-cloud.yaml;
    url = "https://cloud.example.com";
    ids = {
      int = 7;
      hex8 = "00000007";
    };
    kind = "drive";
    client = null;
  };

  # Fact: as org/apps/drive.nix derives it for keycloak = "auth" and realm = "example".
  logsIn = lib.recursiveUpdate app {
    client = {
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

  # Fact: as org/apps/drive.nix derives it, run on web, for an external zhost of alice's allotment there, and an
  # external files of bob's on an sftp server, logging in with store-files' sftp-key.
  mounts = lib.recursiveUpdate app {
    mounts.web = [
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
            hostKey = ../../inventories/allotments/public-keys/host-zhost-ssh-key.pub;
          };
        };
        key = {
          handle = "app-cloud";
          secret = {
            name = "cloud/sftp-key";
            inherit (app.secrets) sopsFile;
          };
          publicKey = ../../inventories/allotments/public-keys/app-cloud-sftp-key.pub;
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
            sopsFile = ../../inventories/allotments/enc/store-files.yaml;
          };
          publicKey = ../../inventories/allotments/public-keys/store-files-sftp-key.pub;
        };
      }
    ];
  };

  # Fact: as org/apps/drive.nix derives it for carol's root in store-box, whose share is carol on box.example.com, at drive,
  # with its smb-password, and a bind of bob's at /srv/pub, who has no root.
  rooted = lib.recursiveUpdate app {
    users = {
      carol = true;
      bob = false;
    };
    binds = [
      {
        mountPoint = "/pub";
        user = "bob";
        sharing = false;
        path = "/srv/pub";
      }
    ];
    shares = [
      {
        user = "carol";
        host = "box.example.com";
        share = "carol/drive";
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

  # Fact: as org/apps/drive.nix derives it for roots.rolf = "app-site", site's home /var/lib/site, at drive.
  homed = lib.recursiveUpdate app {
    users.rolf = true;
    homes = [
      {
        user = "rolf";
        path = "/var/lib/site/drive";
        owner = "site";
      }
    ];
  };

  # Fact: as org/apps/drive.nix derives it for storages.alice.Bilder.photos = "photos", photos' home /var/lib/photos.
  dropping = lib.recursiveUpdate app {
    users.alice = false;
    drops = [
      {
        mountPoint = "/Bilder";
        user = "alice";
        sharing = false;
        photos = "photos";
        drive = "cloud";
        path = "/var/lib/photos/drop/alice/cloud/Bilder";
        owner = "photos";
      }
    ];
  };

  # Fact: as org/apps/drive.nix derives it for storages.alice.Bilder.library = "photos", whose root of alice is
  # carol/photos in store-box.
  viewing = lib.recursiveUpdate app {
    users.alice = false;
    libraries = [
      {
        mountPoint = "/Bilder";
        user = "alice";
        sharing = true;
        photos = "photos";
        host = "box.example.com";
        share = "carol/photos";
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
      ../../../nixos/apps/drive.nix
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
                  realms.example.displayName = "Example";
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

  # Fact: nix shares no two calls of evalApp, each a NixOS evaluation of the host and its container: each app is
  # evaluated here once, for the tests of a file to share.
  evaluated = lib.mapAttrs (_: app: evalApp app app.principal.uid) {
    inherit
      app
      logsIn
      mounts
      rooted
      homed
      dropping
      viewing
      ;
    all = lib.recursiveUpdate mounts logsIn;
  };

  failed =
    cfg:
    lib.filter (lib.hasPrefix "Nextcloud ") (
      map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) cfg.assertions)
    );
}
