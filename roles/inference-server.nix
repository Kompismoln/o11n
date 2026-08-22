# roles/inference-server.nix
{
  flake.nixosModules.inference-server =
    {
      lib,
      pkgs,
      ...
    }:
    {
      imports = [
        ../nixos/huggingface.nix
        ../nixos/vllm.nix
      ];

      environment.systemPackages = with pkgs; [ vllm ];

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
