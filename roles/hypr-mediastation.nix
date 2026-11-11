{
  flake.homeModules.hypr-mediastation =
    { lib, pkgs, ... }:
    let
      player = "uwsm app -- ${lib.getExe pkgs.jellyfin-desktop} --tv --fullscreen";
    in
    {
      imports = [
        ../home/org/home.nix
        ../home/org/hyprland.nix
        ../home/org/nix-conf.nix
        ../home/org/qutebrowser.nix
        ../home/org/shell.nix
        ../home/org/xdg.nix
      ];

      home.packages = [ pkgs.jellyfin-desktop ];

      wayland.windowManager.hyprland.settings = {
        exec-once = [ player ];
        bind = [ "$mainMod, m, exec, ${player}" ];
      };
    };

  flake.nixosModules.hypr-mediastation =
    {
      config,
      host,
      lib,
      pkgs,
      ...
    }:
    let
      viewers = lib.attrNames (
        lib.filterAttrs (_: home: lib.elem "hypr-mediastation" home.roles) host.home
      );
      session = "${lib.getExe config.programs.uwsm.package} start -- hyprland-uwsm.desktop";
    in
    {
      imports = [
        ../nixos/org/home-manager.nix
        ../nixos/org/hyprland.nix
        ../nixos/org/shell.nix
        ../nixos/org/sound.nix
      ];

      config = {
        assertions = [
          {
            assertion = lib.length viewers == 1;
            message = "host.${host.name}: a hypr-mediastation logs its home's user in as it boots, and ${toString (lib.length viewers)} homes have the role: give it to one.";
          }
        ];

        # Policy: the station boots into its home's session, logged in, and to a login prompt once that ends.
        services.greetd = lib.mkIf (lib.length viewers == 1) {
          enable = true;
          settings = {
            initial_session = {
              user = lib.head viewers;
              command = session;
            };
            default_session.command = "${pkgs.greetd}/bin/agreety --cmd '${session}'";
          };
        };

        # Policy: a station sits with its lid however it fits, which suspends nothing.
        services.logind.settings.Login = {
          HandleLidSwitch = "ignore";
          HandleLidSwitchExternalPower = "ignore";
          HandleLidSwitchDocked = "ignore";
        };

        # Policy: sound goes to the analog output, the jack the speakers are on, over the TV's HDMI.
        services.pipewire.wireplumber.extraConfig."50-mediastation" = {
          "monitor.alsa.rules" = [
            {
              matches = [ { "node.name" = "~alsa_output.*analog.*"; } ];
              actions.update-props = {
                "priority.driver" = 2000;
                "priority.session" = 2000;
              };
            }
          ];
        };
      };
    };
}
