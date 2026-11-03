# nixos/huggingface.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.huggingface;
in
{
  options.o11n.huggingface = {
    home = lib.mkOption {
      type = lib.types.str;
      default = config.users.users.huggingface.home;
      description = ''
        The path to use for the HF_HOME environment variable.
      '';
    };
    repo = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.home}/hub";
      example = "/srv/models/huggingface";
      description = ''
        The path to use for the HF_HUB_CACHE environment variable.
      '';
    };
  };

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
