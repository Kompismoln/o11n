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
          # Policy: the databases are for what is developed on the host, which reaches them on loopback.
          mysql = {
            enable = true;
            package = pkgs.mariadb;
            settings.mysqld.bind-address = "127.0.0.1";
          };
        };

      };
    };
}
