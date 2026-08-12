# nixos/vllm.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.vllm;
  enabledServers = lib.filterAttrs (_: serverCfg: serverCfg.enable) cfg.servers;

  vllmOpts =
    { name, ... }:
    {
      options = {
        enable = lib.mkEnableOption "vLLM inference server" // {
          default = true;
        };
        name = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "The name for this vllm server.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = pkgs.vllm;
          description = "The vllm package to use.";
        };
        host = lib.mkOption {
          type = lib.types.str;
          default = "127.0.0.1";
          description = "The host address to bind the server to.";
        };
        port = lib.mkOption {
          type = lib.types.port;
          description = "The port to bind the server to.";
        };
        model = lib.mkOption {
          type = lib.types.str;
          description = "Path to the model weights or HuggingFace model ID.";
          example = "lmsys/vicuna-7b-v1.5";
        };
        extraArgs = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Extra arguments to pass to the vllm server (e.g. ['--kv-cache-dtype', 'fp8']).";
        };
        environment = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          default = { };
          description = "Extra arguments to pass to the vllm server (e.g. VLLM_ATTENTION_BACKEND=FLASHINFER).";
        };
        allowedGPUs = lib.mkOption {
          type = lib.types.listOf lib.types.int;
          default = [ 0 ];
          description = "List of NVIDIA GPU indices this server is allowed to access.";
        };
      };
    };
in
{
  options.o11n.vllm = {
    enable = lib.mkEnableOption "vLLM inference server environment";
    user = lib.mkOption {
      type = lib.types.str;
      default = "vllm";
    };
    servers = lib.mkOption {
      type = with lib.types; attrsOf (submodule vllmOpts);
      default = { };
      description = "Definition of per-domain vLLM inference servers.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.o11n.huggingface.enable;
        message = "o11n.vllm requires o11n.huggingface to be enabled";
      }
    ];

    systemd.services = lib.mapAttrs' (
      server: serverCfg:
      lib.nameValuePair "vllm-${server}" {
        description = "vLLM-${server} Inference Server";
        after = [ "network.target" ];
        wantedBy = [ "multi-user.target" ];

        path = [
          pkgs.which
          pkgs.gcc
          pkgs.cudaPackages.cudatoolkit
        ];

        environment = {
          HF_HOME = config.o11n.huggingface.home;
          HF_HUB_CACHE = config.o11n.huggingface.repo;
          HF_HUB_OFFLINE = "1";
          CUDA_VISIBLE_DEVICES = lib.concatMapStringsSep "," toString serverCfg.allowedGPUs;
          CUDA_HOME = "${pkgs.cudaPackages.cudatoolkit}";
          VLLM_USE_FLASHINFER_SAMPLER = "0";
        }
        // serverCfg.environment;

        serviceConfig = {
          User = cfg.user;
          Group = cfg.user;
          BindReadOnlyPaths = [ "/bin" ];
          ExecStart =
            let
              inherit (serverCfg)
                host
                model
                extraArgs
                port
                ;
              args = lib.escapeShellArgs extraArgs;
              cmd = lib.getExe' serverCfg.package "vllm";
            in
            "${cmd} serve ${model} --host=${host} --port=${toString port} ${args}";

          DeviceAllow = [
            "/dev/nvidiactl rw"
            "/dev/nvidia-uvm rw"
            "/dev/nvidia-uvm-tools rw"
            "/dev/nvidia-modeset rw"
          ]
          ++ map (i: "/dev/nvidia${toString i} rw") serverCfg.allowedGPUs;
        };
      }
    ) enabledServers;
  };
}
