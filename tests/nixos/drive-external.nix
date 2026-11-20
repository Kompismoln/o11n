{
  lib,
  evalNixosModule,
}:
let
  inherit (import ./drive/lib.nix { inherit lib evalNixosModule; }) evaluated failed;
in
{
  # Policy: a drive keeps each of its external storages, which logs in with its key's sftp-key.
  test_nextcloud_keeps_its_external_storages =
    let
      cfg = evaluated.mounts;
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
            sopsFile = ../inventories/allotments/enc/app-cloud.yaml;
            key = "cloud/sftp-key";
            owner = "cloud";
          };
          store-files = {
            hostPath = "/run/secrets/cloud/store-files/sftp-key";
            isReadOnly = true;
            sopsFile = ../inventories/allotments/enc/store-files.yaml;
            key = "files/sftp-key";
            owner = "cloud";
          };
        };
        after = [ "nextcloud-setup.service" ];
        declares = true;
        failed = [ ];
      };
    };

  # Policy: a drive checks each storage for changes as a folder is opened, and scans a mount of an allotment with
  # replicas as it follows what they change there, by ssh with the mount's key, verifying its host's ssh-key.
  test_nextcloud_follows_changes =
    let
      inner = evaluated.mounts.containers.cloud.config;
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
}
