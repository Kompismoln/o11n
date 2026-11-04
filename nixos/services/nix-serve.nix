{ config, org, ... }:
{
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
