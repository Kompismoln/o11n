# nixos/apps/nextcloud.nix
{
  app,
  config,
  lib,
  org,
  ...
}:
{
  imports = [
    ../nextcloud.nix
    ../nginx.nix
  ];

  sops.secrets."${app.name}/secret-key" = {
    inherit (app.secrets) sopsFile;
    owner = app.name;
    group = app.name;
  };

  o11n.nextcloud.apps.${app.name} = {
    enable = true;
    inherit (app) endpoint name;
    inherit (app.principal) bindAddress gid uid;
    home = "${app.principal.home}/nextcloud";
    user = app.name;
    inherit (app) database;
    secretKeyPath = config.sops.secrets."${app.name}/secret-key".path;
    collaboraEndpoint = lib.mapNullable (
      collabora: org.app.${collabora}.endpoint
    ) app.nextcloud.collabora;
  };
}
