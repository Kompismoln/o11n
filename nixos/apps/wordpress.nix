# nixos/apps/wordpress.nix
{ app, ... }:
{
  imports = [
    ../nginx.nix
    ../redis.nix
    ../wordpress.nix
  ];

  o11n = {
    redis.servers.${app.name} = {
      enable = true;
      user = app.name;
      home = "${app.principal.home}/redis";
      bind = app.principal.bindAddress;
      settings."protected-mode" = "no";
    };
    wordpress.apps.${app.name} = {
      enable = true;
      inherit (app) endpoint name;
      inherit (app.principal) bindAddress;
      home = "${app.principal.home}/wordpress";
    };
  };
}
