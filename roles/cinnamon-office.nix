# roles/cinnamon-office.nix
let
  unfree = [ "zoom" ];
in
{
  flake.homeModules.cinnamon-office = {
    imports = [
      ../home/org/home.nix
      ../home/org/nix-conf.nix
      ../home/org/social.nix
      ../home/org/xdg.nix
      ../home/office.nix
      ../home/unfree.nix
    ];

    config = {
      o11n.unfree = unfree;

      o11n-hm = {
        office.enable = true;
      };
    };
  };

  flake.nixosModules.cinnamon-office = {
    imports = [
      ../nixos/org/home-manager.nix
      ../nixos/org/networkmanager.nix
      ../nixos/org/sound.nix
      ../nixos/cinnamon.nix
      ../nixos/printing.nix
      ../nixos/unfree.nix
    ];

    config = {
      programs.evince = {
        enable = true;
      };

      o11n = {
        inherit unfree;
        cinnamon.enable = true;
        printing.enable = true;
      };
    };
  };
}
