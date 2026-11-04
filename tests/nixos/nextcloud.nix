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
    principal = {
      home = "/var/lib/cloud";
      bindAddress = "fd12:3456:7890:ffff::bb7:7";
      uid = 3007;
      gid = 3007;
    };
    secrets.sopsFile = "/enc/app-cloud.yaml";
    nextcloud.collabora = "office";
  };

  eval =
    uid:
    evalNixosModule [
      ../../nixos/apps/nextcloud.nix
      {
        # Accommodating for sops-nix and preservation, which this evaluation doesn't import: what the app
        # declares there is only declared.
        options.sops.secrets = lib.mkOption {
          type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
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
              app.office.endpoint = "office.example.com";
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
}
