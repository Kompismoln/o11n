# nixos/org/shell.nix
{ pkgs, ... }:
{
  environment.sessionVariables = {
    SOPS_AGE_KEY_FILE = "/keys/user-$USER";
  };

  nixpkgs.overlays = [
    (import ../../overlays/tools.nix)
  ];

  programs.bash = {
    promptInit = builtins.readFile ./prompt-init.sh;
    shellAliases = {
    };
  };

  programs.neovim = {
    enable = true;
    defaultEditor = true;
    vimAlias = true;
    viAlias = true;
    configure = {
      customRC = ''
        colorscheme vim
      '';
    };
  };

  environment.systemPackages = (import ../../packages/sets.nix pkgs).all;
}
