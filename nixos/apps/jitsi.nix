# nixos/apps/jitsi.nix
{ app, org, ... }:
{
  imports = [
    ../jitsi.nix
  ];

  o11n.jitsi = {
    inherit (app) name endpoint;
    keycloak = {
      inherit (org.app.${app.jitsi.keycloak}) endpoint;
      inherit (app.jitsi) realm;
    };
  };
}
