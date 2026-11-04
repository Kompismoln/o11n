# nixos/apps/mobilizon.nix
{
  app,
  host,
  inputs,
  lib,
  pkgs,
  ...
}:
{
  imports = [
    ../mobilizon.nix
    ../nginx.nix
  ];

  o11n.mobilizon.apps.${app.name} = {
    enable = true;
    inherit (app) endpoint name;
    inherit (app.principal) bindAddress uid gid;
    home = "${app.principal.home}/mobilizon";
    package = inputs.${app.mobilizon.input}.packages.${host.system}.default;
    inherit (app) database;
    user = app.name;
  };

  services.mobilizon.settings."Mobilizon.Web.Email.Mailer" =
    lib.mkIf (app.mobilizon.mailServer != null)
      {
        adapter = (pkgs.formats.elixirConf { }).lib.mkAtom "Swoosh.Adapters.SMTP";
        relay = app.mobilizon.mailServer;
      };
}
