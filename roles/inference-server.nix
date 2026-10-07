# roles/inference-server.nix
{
  flake.nixosModules.inference-server =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        ../nixos/org/sops.nix
        ../nixos/huggingface.nix
        ../nixos/vllm.nix
      ];

      nix = {
        settings = {
          substituters = [
            "https://cache.nixos-cuda.org"
          ];
          trusted-public-keys = [
            "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
          ];
        };
      };

      boot = {
        kernelModules = [ "nvidia" ];
        blacklistedKernelModules = [ "nouveau" ];
        extraModprobeConfig = ''
          blacklist nouveau
          options nouveau modeset=0
        '';
      };

      nixpkgs.overlays = [
        (import ../overlays/xgrammar.nix)
      ];

      nixpkgs.config = {
        allowUnfreePredicate =
          pkg:
          (pkgs._cuda.lib.allowUnfreeCudaPredicate pkg)
          || (builtins.elem (lib.getName pkg) [
            "nvidia-kernel-modules"
            "nvidia-x11"
            "nvidia-settings"
            "nvidia-cutlass-dsl"
            "nvidia-cutlass-dsl-libs-base"
            "cuda-bindings"
          ]);
        cudaSupport = true;
      };

      hardware = {
        nvidia.open = true;
        nvidia.modesetting.enable = true;
        # Pinned, so a nixpkgs update doesn't change the driver the vLLM containers run on.
        # A new version only takes effect after a reboot.
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

      o11n = {
        huggingface = {
          enable = true;
          repo = "/srv/models/huggingface";
        };

      };
    };
}
