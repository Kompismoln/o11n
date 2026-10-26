{
  lib,
  evalNixosModule,
}:
let
  app = {
    enable = true;
    name = "cloud";
    endpoint = "cloud.example.com";
    home = "/var/lib/cloud/nextcloud";
    bindAddress = "fd12:3456:7890:ffff::bb7:7";
    uid = 3007;
    gid = 3007;
    secretKeyPath = "/run/secrets/cloud/secret-key";
    collaboraEndpoint = "office.example.com";
  };

  eval =
    uid:
    evalNixosModule [
      ../../nixos/nextcloud.nix
      {
        _module.args = {
          org = {
            postgres = "17";
            app = { };
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
        o11n.nextcloud.apps.cloud = app;
        system.stateVersion = lib.trivial.release;
      }
    ];

  failed =
    cfg:
    lib.filter (lib.hasPrefix "Nextcloud ") (
      map (assertion: assertion.message) (lib.filter (assertion: !assertion.assertion) cfg.assertions)
    );

  cfg = eval app.uid;
  container = cfg.containers.cloud;
in
{
  # The container reaches the host's postgresql through its socket, with no password.
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
}
