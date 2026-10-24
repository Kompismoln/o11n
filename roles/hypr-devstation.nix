# roles/hypr-devstation.nix
{
  flake.homeModules.hypr-devstation = {
    imports = [
      ../home/org/browsers.nix
      ../home/org/fonts.nix
      ../home/org/design.nix
      ../home/org/home.nix
      ../home/org/hyprland.nix
      ../home/org/ide.nix
      ../home/org/nix-conf.nix
      ../home/org/qutebrowser.nix
      ../home/org/shell.nix
      ../home/org/social.nix
      ../home/org/xdg.nix
    ];
  };

  flake.nixosModules.hypr-devstation =
    { org, pkgs, ... }:
    {
      imports = [
        ../nixos/org/home-manager.nix
        ../nixos/org/hyprland.nix
        ../nixos/org/networkmanager.nix
        ../nixos/org/shell.nix
        ../nixos/org/sound.nix
      ];

      config = {
        services = {
          transmission = {
            enable = true;
            package = pkgs.transmission_4-qt;
          };
          redis.servers."test".enable = true;
          postgresql = {
            enable = true;
            package = pkgs."postgresql_${org.postgres}";
            extensions =
              ps: with ps; [
                postgis
                pg_repack
              ];
          };
          mysql = {
            enable = true;
            package = pkgs.mariadb;
          };
        };

      };
    };
}
