{ config, ... }:
{
  imports = [ ./unfree.nix ];

  boot = {
    kernelModules = [ "nvidia" ];
    blacklistedKernelModules = [ "nouveau" ];
    extraModprobeConfig = ''
      blacklist nouveau
      options nouveau modeset=0
    '';
  };

  hardware = {
    nvidia.open = true;
    nvidia.modesetting.enable = true;
    # Policy: pinned, so a nixpkgs update doesn't change the driver the vLLM containers run on; a new version only
    # takes effect after a reboot.
    nvidia.package = config.boot.kernelPackages.nvidiaPackages.mkDriver {
      version = "595.99.02";
      sha256_64bit = "sha256-6HR3lYv3YwcFSTJL1a1slI66btIQ5EAFs+/4SUD24ew=";
      openSha256 = "sha256-T36x/jx8yQ8l3LFp1rZIrTfcSwbGy8YSAvXOUSptpb4=";
      settingsSha256 = "sha256-GYCcnxfKPrTCrsmd25sMyzfC5cqJQJx0c31haooyTYM=";
      persistencedSha256 = "sha256-VyKtF/HdHPQrHHK6opSO69M72LmnGZtauuchj9uuje8=";
    };
    graphics.enable = true;
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  o11n.unfree = [
    "nvidia-kernel-modules"
    "nvidia-x11"
    "nvidia-settings"
  ];
}
