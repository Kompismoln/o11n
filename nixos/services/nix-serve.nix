{
  config,
  org,
  ...
}:
let
  inherit (config.services.nix-serve) port;
in
{
  imports = [ ../org/vpn-proxy.nix ];

  # Policy: the host's peers fetch from it over their vpns, and no one else.
  o11n.vpnProxies.nix-serve = {
    inherit port;
    to = "127.0.0.1:${toString port}";
  };

  sops.secrets."nix-serve/nix-sign" = {
    inherit (org.service.nix-serve.secrets) sopsFile;
    restartUnits = [
      "nix-serve.service"
    ];
  };
  services.nix-serve = {
    enable = true;
    bindAddress = "127.0.0.1";
    secretKeyFile = config.sops.secrets."nix-serve/nix-sign".path;
  };
}
