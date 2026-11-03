# home/office.nix
{
  pkgs,
  ...
}:
{

  config = {
    programs.firefox = {
      enable = true;
      configPath = ".mozilla/firefox";
    };

    programs.chromium = {
      enable = true;
    };

    home.packages = with pkgs; [
      libreoffice
      gnome-system-monitor
      mate-system-monitor
      xreader
      xournalpp
      zoom-us
      hunspell
      hunspellDicts.sv_SE
      hunspellDicts.en_US
    ];
  };
}
