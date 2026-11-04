# nixos/printing.nix
{
  config,
  lib,
  pkgs,
  ...
}:
{
  config = {
    services.avahi = {
      enable = true;
      openFirewall = true;
    };

    services.printing = {
      enable = true;
      drivers = with pkgs; [
        cups-filters
        cups-browsed
      ];
    };

    environment.systemPackages = with pkgs; [
      system-config-printer
    ];

    users.groups.lpadmin.members = lib.attrNames (
      lib.filterAttrs (_: userCfg: userCfg.isNormalUser) config.users.users
    );
  };
}
