{
  lib,
  pkgs,
  evalNixosModule,
}:
let
  inherit (import ./drive/lib.nix { inherit lib evalNixosModule; }) evaluated failed;
in
{
  # Policy: a root in a store's share is mounted as the app's user, with the store's smb-password, and the container
  # starts only once it's mounted.
  test_drive_mounts_a_share =
    let
      cfg = evaluated.rooted;
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
          device = "//box.example.com/carol/drive";
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

  # Policy: a root is its user's data, a bind is mounted at its folder from the directory the container binds, and a
  # user without a root has files no one can write in; o11n makes each of them, and only a user with a root has no
  # quota.
  test_nextcloud_binds_each_storage =
    let
      cfg = evaluated.rooted;
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
        examples =
          lib.all (key: lib.hasInfix "config:app:set dav ${key} --type=boolean --value=false" users)
            [
              "enableDefaultContact"
              "create_example_event"
            ];
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
        examples = true;
        local_allowed = true;
      };
    };

  # Policy: a root in an entity's home is a directory there, its owner's, which the host makes and mounts as
  # Nextcloud's user's, written as the owner, and binds into the container as the user's data, once the owner is on
  # the host.
  test_drive_roots_in_a_home =
    let
      cfg = evaluated.homed;
      container = cfg.containers.cloud;
      where = "/var/lib/cloud/nextcloud/data/rolf";
    in
    {
      expr = {
        mounts = map (mount: {
          inherit (mount)
            what
            where
            type
            options
            after
            ;
        }) (lib.filter (mount: mount.type == "fuse.bindfs") cfg.systemd.mounts);
        data = { inherit (container.bindMounts."/var/lib/nextcloud/data/rolf") hostPath isReadOnly; };
        files = container.bindMounts ? "/var/lib/nextcloud/data/rolf/files";
        requires = lib.elem where cfg.systemd.services."container@cloud".unitConfig.RequiresMountsFor;
        quota = lib.hasInfix "user:setting rolf files quota none" container.config.systemd.services.nextcloud-users.script;
        bindfs = lib.elem pkgs.bindfs cfg.system.fsPackages;
        made = lib.elem "d '/var/lib/site/drive' 0750 site site - -" cfg.systemd.tmpfiles.rules;
        failed = failed cfg;
      };
      expected = {
        mounts = [
          {
            what = "/var/lib/site/drive";
            inherit where;
            type = "fuse.bindfs";
            options = "force-user=cloud,force-group=cloud,create-for-user=site,create-for-group=site,nofail";
            after = [ "systemd-tmpfiles-setup.service" ];
          }
        ];
        data = {
          hostPath = where;
          isReadOnly = false;
        };
        files = false;
        requires = true;
        quota = true;
        bindfs = true;
        made = true;
        failed = [
          "Nextcloud cloud mounts rolf's root from /var/lib/site/drive, whose owner, site, isn't on web: run the owner on web, or root rolf elsewhere."
        ];
      };
    };
}
