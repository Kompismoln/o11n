{
  lib,
  evalNixosModule,
}:
let
  inherit (import ./drive/lib.nix { inherit lib evalNixosModule; })
    app
    evalApp
    evaluated
    failed
    ;

  cfg = evaluated.app;
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
    expr = failed (evalApp app 3008);
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

  # Policy: a drive without a keycloak keeps its own login.
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

  # Policy: a drive's office is its container's coolwsd, at the app's own url, on a loopback port of the app's,
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
        activates = lib.hasInfix "richdocuments:activate-config --wopi-url=https://cloud.example.com" unit.script;
        inherit (office) enable port aliasGroups;
        listens = office.settings.net.listen;
        discovery = locations."^~ /hosting/discovery".proxyPass;
        websocket = locations."~ ^/cool/(.*)/ws$".proxyWebsockets;
      };
      expected = {
        after = [
          "nextcloud-setup.service"
          "coolwsd.service"
        ];
        activates = true;
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
