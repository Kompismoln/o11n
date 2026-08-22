# roles/cinnamon-office.nix
{
  flake.homeModules.cinnamon-office = {
    imports = [
      ../home/org/home.nix
      ../home/org/nix-conf.nix
      ../home/org/social.nix
      ../home/org/xdg.nix
      ../home/office.nix
    ];

    config = {
      o11n-hm = {
        office.enable = true;
      };
    };
  };

  flake.nixosModules.cinnamon-office =
    { lib, ... }:
    {
      imports = [
        ../nixos/org/home-manager.nix
        ../nixos/org/networkmanager.nix
        ../nixos/org/sound.nix
        ../nixos/cinnamon.nix
        ../nixos/printing.nix
      ];

      config = {
        nixpkgs.config.allowUnfreePredicate =
          pkg:
          builtins.elem (lib.getName pkg) [
            "zoom"
          ];

        programs.evince = {
          enable = true;
        };

        o11n = {
          cinnamon.enable = true;
          printing.enable = true;
        };
      };
    };
}
