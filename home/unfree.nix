{ config, lib, ... }:
{
  options.o11n.unfree = lib.mkOption {
    description = "names of the unfree packages to allow";
    type = with lib.types; listOf str;
    default = [ ];
  };

  # Fact: a home on a host gets the host's pkgs, with nixpkgs.* disabled; the host's o11n.unfree applies there.
  config = lib.mkIf (!config.submoduleSupport.enable) {
    nixpkgs.config.allowUnfreePackages = config.o11n.unfree;
  };
}
