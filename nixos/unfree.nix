{ config, lib, ... }:
{
  options.o11n.unfree = lib.mkOption {
    description = "names of the unfree packages to allow";
    type = with lib.types; listOf str;
    default = [ ];
  };

  config.nixpkgs.config.allowUnfreePackages = config.o11n.unfree;
}
