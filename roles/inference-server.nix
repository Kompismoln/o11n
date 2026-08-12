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

        vllm.enable = true;
        vllm.servers.qwen3-8b = {
          model = "Qwen/Qwen3-8B-AWQ";
          host = "::";
          port = 12009;
          extraArgs = [
            "--enforce-eager"
            "--gpu-memory-utilization=0.95"
            "--max-model-len=8192"
            "--max-num-seqs=1"
            "--enable-prefix-caching"
            "--tool-call-parser=hermes"
            "--enable-auto-tool-choice"
          ];
        };
      };
    };
}
