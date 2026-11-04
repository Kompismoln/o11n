# nixos/apps/keycloak.nix
{
  app,
  config,
  pkgs,
  ...
}:
let
  port = 8080;
  inherit (app.principal) bindAddress;
in
{
  imports = [
    ../postgresql.nix
  ];

  o11n.postgresql.databases.${config.services.keycloak.database.name}.user =
    config.services.keycloak.database.username;

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = true;
    enableACME = true;
    extraConfig = ''
      proxy_buffer_size 32k;
      proxy_buffers 4 32k;
      proxy_busy_buffers_size 32k;
    '';
    locations."/" = {
      recommendedProxySettings = true;
      proxyPass = "http://[${bindAddress}]:${toString port}";
    };
  };

  services.keycloak = {
    enable = true;
    settings = {
      hostname = app.endpoint;
      http-port = port;
      http-host = bindAddress;
      http-enabled = true;
      proxy-headers = "xforwarded";
    };
    database.host = "/run/postgresql";
    plugins = [
      pkgs.keycloak.plugins.junixsocket-common
      pkgs.keycloak.plugins.junixsocket-native-common
    ];
    initialAdminPassword = "_";
  };

}
