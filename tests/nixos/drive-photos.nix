{
  lib,
  evalNixosModule,
}:
let
  inherit (import ./drive/lib.nix { inherit lib evalNixosModule; }) app evaluated failed;
in
{
  # Policy: a drop folder is a directory of its photos app's, which the host mounts as Nextcloud's user's, written as
  # the photos app, and Nextcloud has as a bind at its folder, once the photos app is on the host.
  test_drive_drops =
    let
      cfg = evaluated.dropping;
      container = cfg.containers.cloud;
      where = "/var/lib/cloud/nextcloud/drops/alice/Bilder";
    in
    {
      expr = {
        mounts = map (mount: {
          inherit (mount) what where options;
        }) (lib.filter (mount: mount.type == "fuse.bindfs") cfg.systemd.mounts);
        bind = { inherit (container.bindMounts."/srv/binds/alice/Bilder") hostPath isReadOnly; };
        requires = lib.elem where cfg.systemd.services."container@cloud".unitConfig.RequiresMountsFor;
        local = lib.hasInfix "/srv/binds/alice/Bilder" container.config.systemd.services.nextcloud-external.script;
        failed = failed cfg;
      };
      expected = {
        mounts = [
          {
            what = "/var/lib/photos/drop/alice/cloud/Bilder";
            inherit where;
            options = "force-user=cloud,force-group=cloud,create-for-user=photos,create-for-group=photos,nofail";
          }
        ];
        bind = {
          hostPath = where;
          isReadOnly = false;
        };
        requires = true;
        local = true;
        failed = [
          "Nextcloud cloud mounts alice's /Bilder from /var/lib/photos/drop/alice/cloud/Bilder, a drop folder of photos, which isn't on web: run photos on web."
        ];
      };
    };

  # Policy: a library is mounted read-only from its root's share, as Nextcloud's user's, and bound read-only into the
  # container, at its folder.
  test_drive_libraries =
    let
      cfg = evaluated.viewing;
      container = cfg.containers.cloud;
      where = "/var/lib/cloud/nextcloud/libraries/alice/Bilder";
      mount = lib.findFirst (mount: mount.where == where) { } cfg.systemd.mounts;
    in
    {
      expr = {
        inherit (mount) what type;
        options = lib.splitString "," mount.options;
        password = cfg.sops.secrets."cloud/store-box/smb-password".key;
        bind = { inherit (container.bindMounts."/srv/binds/alice/Bilder") hostPath isReadOnly; };
        requires = lib.elem where cfg.systemd.services."container@cloud".unitConfig.RequiresMountsFor;
        local = lib.hasInfix "/srv/binds/alice/Bilder" container.config.systemd.services.nextcloud-external.script;
      };
      expected = {
        what = "//box.example.com/carol/photos";
        type = "cifs";
        options = [
          "ro"
          "credentials=/run/secrets/rendered/cloud/libraries/store-box-smb-credentials"
          "uid=${toString app.principal.uid}"
          "gid=${toString app.principal.gid}"
          "dir_mode=0550"
          "file_mode=0440"
          "vers=3.1.1"
          "seal"
          "nohandlecache"
        ];
        password = "box/smb-password";
        bind = {
          hostPath = where;
          isReadOnly = true;
        };
        requires = true;
        local = true;
      };
    };
}
