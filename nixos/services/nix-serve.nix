{
  config,
  host,
  lib,
  org,
  ...
}:
{
  # Policy: the host's peers fetch from it over their vpns, and no one else.
  networking.firewall.interfaces = lib.genAttrs (map (vpn: org.vpn.${vpn}.interface) host.vpns) (_: {
    allowedTCPPorts = [ config.services.nix-serve.port ];
  });

  sops.secrets."nix-serve/nix-sign" = {
    inherit (org.service.nix-serve.secrets) sopsFile;
    restartUnits = [
      "nix-serve.service"
    ];
  };
  services.nix-serve = {
    enable = true;
    bindAddress = "";
    secretKeyFile = config.sops.secrets."nix-serve/nix-sign".path;
  };
}
