# nixos/services/nix-push.nix
{ pkgs, ... }:
{
  nix.settings.trusted-users = [ "nix-push" ];

  services.openssh.extraConfig = ''
    Match User nix-push
      ForceCommand ${pkgs.nix}/bin/nix-store --serve --write
  '';
}
