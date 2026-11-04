# nixos/huggingface.nix
{
  config,
  pkgs,
  ...
}:

let
  # Dependency: nixos/services/vllm.nix reads the cache there.
  cfg = {
    inherit (config.users.users.huggingface) home;
    repo = "/srv/models/huggingface";
  };
in
{

  config = {
    environment.systemPackages =
      let
        huggingface-cli = pkgs.writeShellScriptBin "huggingface-cli" ''
          export HF_HOME=${cfg.home}
          export HF_HUB_CACHE=${cfg.repo}
          exec ${pkgs.python3Packages.huggingface-hub}/bin/huggingface-cli "$@"
        '';
        hf = pkgs.writeShellScriptBin "hf" ''
          export HF_HOME=${cfg.home}
          export HF_HUB_CACHE=${cfg.repo}
          exec ${pkgs.python3Packages.huggingface-hub}/bin/hf "$@"
        '';

      in
      [
        hf
        huggingface-cli
      ];

    systemd.tmpfiles.rules = [
      "d '${cfg.repo}' 0750 huggingface huggingface - -"
      "Z '${cfg.repo}' 0750 huggingface huggingface - -"
    ];
  };
}
