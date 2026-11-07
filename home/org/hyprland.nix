{
  home,
  lib,
  org,
  pkgs,
  ...
}:

let
  host = org.host.${home.hostname};
in

{
  imports = [
    ./foot.nix
  ];

  programs.hyprlock = lib.mkIf host.desktop.autolock {
    enable = true;
    settings = {
      general = {
        ignore_empty_input = true;
        hide_cursor = true;
      };

      input-field = [
        {
          position = "0, 0";
        }
      ];
    };
  };

  services.hypridle = lib.mkIf host.desktop.autolock {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || hyprlock";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "hyprctl dispatch dpms on";
      };

      listener = [
        {
          timeout = 300;
          on-timeout = "loginctl lock-session";
        }
        {
          timeout = 330; # 5.5 minutes
          on-timeout = "hyprctl dispatch dpms off";
          on-resume = "hyprctl dispatch dpms on";
        }
      ];
    };
  };

  xdg.mimeApps.enable = true;

  xdg.mimeApps.defaultApplications = {
    "text/*" = "nvim.desktop";
    "image/*" = "feh.desktop";
    "video/*" = "mpv.desktop";
    "audio/*" = "mpv.desktop";
    "application/pdf" = "mupdf.desktop";
  };

  home.packages = with pkgs; [
    feh
    mpv
    mupdf
    pinta
    wl-clipboard
  ];

  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang";
    settings = {
      monitorv2 = host.monitors;

      exec-once = [
        "${lib.getExe pkgs.swaybg} -i ${org.theme.wallpaper}"
        "${lib.getExe pkgs.waybar}"
      ];

      input = {
        kb_layout = host.desktop.kb-layout;
        kb_options = "grp:caps_switch";
        repeat_rate = 35;
        repeat_delay = 175;
        follow_mouse = true;
        touchpad = {
          natural_scroll = true;
          tap-and-drag = true;
        };
      };

      misc = {
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        disable_autoreload = true;
      };

      animations = {
        enabled = true;
        animation = [
          "global, 1, 5, default"
          "workspaces, 1, 1, default"
        ];
      };

      device = host.devices;

      "$mainMod" = "SUPER";

      windowrule = [
        "float on, size 550 350, center on, match:class negative:unbound-size, match:float 0"
      ];

      bind =
        let
          hyprctl = "${pkgs.hyprland}/bin/hyprctl";
          activeMonitor = "${hyprctl} monitors | ${lib.getExe pkgs.gawk} '/Monitor/{mon=$2} /focused: yes/{print mon}'";
          workspaces = builtins.genList (x: x) 10;
          timestamp = "$(date +%Y%m%d_%H%M%S).png";
          screenshotPath = "${host.desktop.screenshotPath}/${timestamp}";
        in
        with pkgs;
        [
          "$mainMod, return, togglefloating,"

          "$mainMod, i, exec, ${lib.getExe foot}"
          "$mainMod, b, exec, ${lib.getExe qutebrowser}"
          "$mainMod, r, exec, ${lib.getExe fuzzel}"

          "$mainMod, q, exit,"
          "$mainMod, f, fullscreen, 0, toggle"

          "$mainMod, h, movetoworkspacesilent, -1"
          "$mainMod, l, movetoworkspacesilent, +1"

          "$mainMod, o, workspace, emptynm"
          "$mainMod, j, workspace, e+1"
          "$mainMod, k, workspace, e-1"
          "$mainMod, c, killactive,"

          "$mainMod, n, cyclenext"
          "$mainMod, p, cyclenext, prev"

          "$mainMod, v, swapnext"
          "$mainMod, x, swapnext, prev"

          ''$mainMod, PRINT, exec, ${lib.getExe grim} -g "$(${lib.getExe slurp})" - | ${lib.getExe swappy} -f - -o ${screenshotPath}''
          '', PRINT, exec, ${lib.getExe grim} -o "$(${activeMonitor})" - | ${lib.getExe swappy} -f - -o ${screenshotPath}''
        ]
        ++ map (i: "$mainMod, ${toString i}, workspace, ${toString i}") workspaces
        ++ map (i: "$mainMod SHIFT, ${toString i}, movetoworkspacesilent, ${toString i}") workspaces;

      bindm = [
        "$mainMod, mouse:272, movewindow"
        "$mainMod, mouse:273, resizewindow"
      ];
    };
  };
  programs.waybar = {
    enable = true;
    settings = {
      mainBar = {
        layer = "top";
        position = "top";
        height = 30;
        spacing = 4;
        output = map (m: m.output) host.monitors;
        modules-right = [
          "pulseaudio#source"
          "pulseaudio#sink"
          "network"
          "battery"
        ];
        modules-left = [
          "hyprland/workspaces"
          "hyprland/submap"
        ];
        modules-center = [ "clock" ];
        network = lib.mkIf (host.network ? wifi) {
          "interface" = host.network.wifi.interface;
          "format" = "{ifname}";
          "format-wifi" = "{essid} ({signalStrength}%) {icon}";
          "format-icons" = [
            "󰤯"
            "󰤟"
            "󰤢"
            "󰤥"
            "󰤨"
          ];
          "format-ethernet" = "{ipaddr}/{cidr} 󰊗";
          "format-disconnected" = "Disconnected";
          "tooltip-format" = "{ifname} via {gwaddr} 󰊗";
          "tooltip-format-wifi" = "{essid} ({signalStrength}%) ";
          "tooltip-format-ethernet" = "{ifname} ";
          "tooltip-format-disconnected" = "Disconnected";

          "on-click" = "${lib.getExe pkgs.foot} -a unbound-size -e nmtui";
          "max-length" = 50;
        };
        "pulseaudio#source" = {
          "format-source" = "{volume}% ";
          "format-source-muted" = "{volume}% ";
          "format" = "{format_source}";
          "max-volume" = 100;
          "on-click" = "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle";
          "on-click-middle" = "pavucontrol";
          "on-scroll-up" = "wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 1%+";
          "on-scroll-down" = "wpctl set-volume @DEFAULT_AUDIO_SOURCE@ 1%-";
        };
        "pulseaudio#sink" = lib.mkIf (host.desktop.audio-bus-id or null != null) {
          "format" = "{volume}% {icon}";
          "format-bluetooth" = "{volume}% {icon}";
          "format-muted" = "";
          "format-icons" = {
            "alsa_output.${host.desktop.audio-bus-id}.analog-stereo" = "";
            "alsa_output.${host.desktop.audio-bus-id}.analog-stereo-muted" = "";
            "headphone" = "";
            "hands-free" = "";
            "headset" = "";
            "phone" = "";
            "phone-muted" = "";
            "portable" = "";
            "car" = "";
            "default" = [
              ""
              ""
            ];
          };
          "scroll-step" = 1;
          "on-click" = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
          "on-click-middle" = "pavucontrol";
          "ignored-sinks" = [ "Easy Effects Sink" ];
        };
        clock = {
          tooltip-format = "<tt><small>{calendar}</small></tt>";
          format = "{:%A, %H:%M, %Y-%m-%d}";
          calendar = {
            mode = "year";
            mode-mon-col = 3;
            weeks-pos = "left";
          };
        };
        battery = {
          states = {
            good = 95;
            warning = 30;
            critical = 15;
          };
          format = "{capacity}% {icon}";
          format-charging = "{capacity}% 󱐋";
          format-plugged = "{capacity}% ";
          format-alt = "{time} {icon}";
          format-icons = [
            "󰂎"
            "󰁺"
            "󰁻"
            "󰁼"
            "󰁽"
            "󰁾"
            "󰁿"
            "󰂀"
            "󰂁"
            "󰂂"
            "󰁹"
          ];
        };
      };
    };
  };
}
