{
  host,
  lib,
  pkgs,
  ...
}:
let
  display = lib.head (host.gpus ++ [ { vendor = null; } ]);
  # Accommodating for aquamarine, which takes AQ_DRM_DEVICES split at colons, which a PCI address has.
  linkOf = index: "/dev/dri/o11n-gpu-${toString index}";
in
{
  programs = {
    hyprland = {
      enable = true;
      withUWSM = true;
    };
    hyprlock.enable = true;
    uwsm = {
      enable = true;
      waylandCompositors.hyprland = {
        prettyName = "Hyprland";
        comment = "Hyprland compositor managed by UWSM";
        binPath = "/run/current-system/sw/bin/Hyprland";
      };
    };
  };

  environment.sessionVariables = {
    NIXOS_OZONE_WL = "1";
  }
  # Policy: Hyprland renders on the card the monitors are attached to, and copies to the others, rather than on the one
  # the kernel numbered first.
  // lib.optionalAttrs (lib.length host.gpus > 1) {
    AQ_DRM_DEVICES = lib.concatStringsSep ":" (lib.imap0 (index: _: linkOf index) host.gpus);
  }
  // lib.optionalAttrs (display.vendor == "nvidia") {
    LIBVA_DRIVER_NAME = "nvidia";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
  };

  services.udev.extraRules = lib.optionalString (lib.length host.gpus > 1) (
    lib.concatStrings (
      lib.imap0 (index: gpu: ''
        KERNEL=="card*", SUBSYSTEM=="drm", KERNELS=="${gpu.bus}", SYMLINK+="${lib.removePrefix "/dev/" (linkOf index)}"
      '') host.gpus
    )
  );

  security.polkit.enable = true;

  xdg.portal = {
    enable = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-gtk
    ];
    config = {
      common = {
        default = [
          "hyprland"
          "gtk"
        ];
      };
      hyprland = {
        default = [
          "hyprland"
          "gtk"
        ];
      };
    };
  };
}
