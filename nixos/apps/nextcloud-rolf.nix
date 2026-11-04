# nixos/apps/nextcloud-rolf.nix
{
  app,
  host,
  inputs,
  org,
  ...
}:
let
  nextcloud = org.app.${app.nextcloud-rolf.nextcloud};
in
{
  imports = [
    ../nextcloud-rolf.nix
    ../nginx.nix
  ];

  o11n.nextcloud-rolf.apps.${app.name} = {
    enable = true;
    inherit (app) endpoint name;
    packages = inputs.${app.nextcloud-rolf.input}.packages.${host.system};
    user = nextcloud.name;
    home = "${nextcloud.principal.home}/nextcloud/data/rolf/files/+pub";
  };
}
