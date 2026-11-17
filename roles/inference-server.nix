# roles/inference-server.nix
{
  flake.nixosModules.inference-server =
    {
      pkgs,
      ...
    }:
    {
      imports = [
        ../nixos/org/sops.nix
        ../nixos/huggingface.nix
        ../nixos/nvidia.nix
        ../nixos/unfree.nix
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

      nixpkgs.overlays = [
        (import ../overlays/xgrammar.nix)
      ];

      nixpkgs.config = {
        allowUnfreePredicate = pkgs._cuda.lib.allowUnfreeCudaPredicate;
        cudaSupport = true;
      };

      o11n = {

        unfree = [
          "nvidia-cutlass-dsl"
          "nvidia-cutlass-dsl-libs-base"
          "cuda-bindings"
        ];
      };
    };
}
