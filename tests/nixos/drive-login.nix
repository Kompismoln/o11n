{
  lib,
  evalNixosModule,
}:
let
  inherit (import ./drive/lib.nix { inherit lib evalNixosModule; }) evaluated;

  cfg = evaluated.app;
  container = cfg.containers.cloud;
in
{
  # Policy: a drive with a keycloak has its users log in with the realm, as the Keycloak user of their name.
  test_nextcloud_logs_in_with_keycloak =
    let
      cfg = evaluated.logsIn;
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
          "config:app:set user_oidc store_login_token --type=string --value=1 --lazy"
          ''select(.value.backend == "Database" and .value.enabled)''
          ''user:disable "$user"''
        ];
        settings = {
          inherit (inner.services.nextcloud.settings) user_oidc lost_password_link token_auth_enforced;
        };
        after = inner.systemd.services.nextcloud-oidc.after;
        restarts =
          lib.elem (builtins.hashFile "sha256" ../inventories/allotments/enc/app-cloud.yaml)
            cfg.systemd.services."container@cloud".restartTriggers;
      };
      expected = {
        apps = [
          "richdocuments"
          "user_oidc"
        ];
        secret = {
          hostPath = "/run/secrets/cloud/oidc-secret";
          isReadOnly = true;
          sopsFile = ../inventories/allotments/enc/app-cloud.yaml;
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
            auto_provision = true;
            soft_auto_provision = false;
          };
          lost_password_link = "disabled";
          token_auth_enforced = true;
        };
        after = [ "nextcloud-setup.service" ];
        restarts = true;
      };
    };

  # Policy: a drive's apps are its files', its settings' and Nextcloud's own, from no app store.
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
      oidc = evaluated.logsIn.containers.cloud.config;
      external = evaluated.mounts.containers.cloud.config;
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
      all = evaluated.all.containers.cloud.config;
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
}
