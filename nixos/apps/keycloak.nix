# nixos/apps/keycloak.nix
{ app, ... }:
{
  imports = [
    ../keycloak.nix
  ];

  o11n.keycloak = {
    inherit (app) endpoint;
    inherit (app.principal) bindAddress;
    user = app.name;
  };
}
