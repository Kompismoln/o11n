# nixos/apps/collabora.nix
{ app, ... }:
{
  imports = [
    ../collabora.nix
  ];

  o11n.collabora = {
    enable = true;
    inherit (app) endpoint;
    inherit (app.principal) bindAddress;
    inherit (app.collabora) allowedHosts;
  };
}
