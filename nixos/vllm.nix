# nixos/vllm.nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.o11n.vllm;
  hostConfig = config;
  enabledServers = lib.filterAttrs (_: serverCfg: serverCfg.enable) cfg.servers;

  vllmOpts =
    { name, config, ... }:
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
        nixpkgs = lib.mkOption {
          type = lib.types.path;
          default = pkgs.path;
          description = "An optional nixpkgs pin for the container";
        };
        pkgs = lib.mkOption {
          type = lib.types.pkgs;
          readOnly = true;
          default = import config.nixpkgs {
            inherit (pkgs.stdenv.hostPlatform) system;
            inherit (hostConfig.nixpkgs) config overlays;
          };
          defaultText = lib.literalMD "`nixpkgs`, imported with the host's `nixpkgs.config` and `nixpkgs.overlays`";
          description = "The container's package set.";
        };
        package = lib.mkOption {
          type = lib.types.package;
          default = config.pkgs.vllm;
          defaultText = lib.literalExpression "pkgs.vllm";
          description = "The vllm package to use, from the container's package set by default.";
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
          description = "A Hugging Face model ID, read from the Hugging Face cache at `revision`, or a path to the model weights in the Nix store.";
          example = "lmsys/vicuna-7b-v1.5";
        };
        revision = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "The commit of the model in the Hugging Face cache. Required for a model ID: a branch or tag moves when the cache is updated.";
        };
        chatTemplate = lib.mkOption {
          type = lib.types.nullOr lib.types.path;
          default = null;
          description = "Chat template file in the Nix store, passed as --chat-template; if null, vLLM picks one from the model's files.";
        };
        servedModelNames = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Names passed as --served-model-name; responses carry the first. If empty, the model is served under its own name.";
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

  servicePath = serverPkgs: [
    serverPkgs.which
    serverPkgs.gcc
    serverPkgs.cudaPackages.cudatoolkit
  ];

  hostUser = config.users.users.${cfg.user};
  hasHome = hostUser.home != "/var/empty";

  # Each server's home inside the container: its own directory in the user's home on the host.
  serverHome = server: "${hostUser.home}/${servers.${server}.container}";

  isLocal = lib.hasPrefix "/";
  inStore = lib.hasPrefix "${builtins.storeDir}/";
  isCommit = revision: revision != null && builtins.match "[0-9a-f]{40}" revision != null;

  # The groups cfg.user is in on the host: its own, its extra ones and those listing it as a member.
  hostGroups = lib.unique (
    [ hostUser.group ]
    ++ hostUser.extraGroups
    ++ lib.attrNames (lib.filterAttrs (_: group: lib.elem cfg.user group.members) config.users.groups)
  );

  servers = lib.mapAttrs (server: serverCfg: {
    container = "vllm-${serverCfg.name}";

    argv = [
      (lib.getExe' serverCfg.package "vllm")
      "serve"
      serverCfg.model
      "--host=${serverCfg.host}"
      "--port=${toString serverCfg.port}"
    ]
    ++ lib.optional (serverCfg.revision != null) "--revision=${serverCfg.revision}"
    ++ lib.optional (serverCfg.chatTemplate != null) "--chat-template=${serverCfg.chatTemplate}"
    ++ lib.optionals (serverCfg.servedModelNames != [ ]) (
      [ "--served-model-name" ] ++ serverCfg.servedModelNames
    )
    ++ serverCfg.extraArgs;

    environment = {
      HF_HOME = config.o11n.huggingface.home;
      HF_HUB_CACHE = config.o11n.huggingface.repo;
      HF_HUB_OFFLINE = "1";
      CUDA_VISIBLE_DEVICES = lib.concatMapStringsSep "," toString serverCfg.allowedGPUs;
      CUDA_HOME = "${serverCfg.pkgs.cudaPackages.cudatoolkit}";
      VLLM_USE_FLASHINFER_SAMPLER = "0";
    }
    // serverCfg.environment;

    # Everything the server runs from the store: its path changes when any of it does,
    # and `nix-store -qR` on it gives the whole runtime closure.
    runtime = pkgs.writeTextFile {
      name = "vllm-${server}-runtime";
      text = lib.concatMapStrings (p: "${p}\n") ([ serverCfg.package ] ++ servicePath serverCfg.pkgs);
    };

    devices = [
      "/dev/nvidiactl"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
      "/dev/nvidia-modeset"
    ]
    ++ map (i: "/dev/nvidia${toString i}") serverCfg.allowedGPUs;

    # What the server reads from the host outside the store: the driver's libraries
    # and the Hugging Face cache.
    readOnlyPaths = [
      "/run/opengl-driver"
      config.o11n.huggingface.repo
    ];
  }) enabledServers;

  reportConfig = pkgs.writeText "vllm-report.json" (
    builtins.toJSON {
      hostname = config.networking.hostName;
      hub_cache = config.o11n.huggingface.repo;
      servers = lib.mapAttrs (server: serverCfg: {
        unit = "container@${servers.${server}.container}.service";
        service = "vllm.service";
        package = {
          name = lib.getName serverCfg.package;
          version = lib.getVersion serverCfg.package;
          path = "${serverCfg.package}";
        };
        runtime = "${servers.${server}.runtime}";
        inherit (servers.${server}) argv environment;
        inherit (serverCfg)
          host
          port
          model
          revision
          ;
        chat_template = if serverCfg.chatTemplate == null then null else "${serverCfg.chatTemplate}";
        served_model_names = serverCfg.servedModelNames;
        extra_args = serverCfg.extraArgs;
        gpus = serverCfg.allowedGPUs;
      }) enabledServers;
    }
  );

  vllmReport =
    let
      script = pkgs.writers.writePython3Bin "vllm-report" {
        flakeIgnore = [
          "E203"
          "E501"
        ];
      } (builtins.readFile ./vllm-report.py);
    in
    pkgs.writeShellScriptBin "vllm-report" ''
      exec ${lib.getExe script} \
        --config ${reportConfig} \
        --nvidia-smi ${lib.getExe' config.hardware.nvidia.package.bin "nvidia-smi"} \
        --systemctl ${lib.getExe' config.systemd.package "systemctl"} \
        "$@"
    '';
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
    report = {
      enable = lib.mkEnableOption "an HTTP endpoint reporting what each vLLM server runs: package, runtime closure, argv, env, GPUs, model files and chat template, hashed";
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "The host address to bind the report endpoint to.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 12008;
        description = "The port to bind the report endpoint to.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.o11n.huggingface.enable;
        message = "o11n.vllm requires o11n.huggingface to be enabled";
      }
    ]
    # What a server reads must not change under it: no host paths, no moving revisions.
    ++ lib.concatLists (
      lib.mapAttrsToList (server: serverCfg: [
        {
          assertion = isLocal serverCfg.model -> inStore serverCfg.model;
          message = "o11n.vllm.servers.${server}.model must be a Hugging Face model ID or a path in the Nix store, not a path on the host.";
        }
        {
          assertion = !isLocal serverCfg.model -> isCommit serverCfg.revision;
          message = "o11n.vllm.servers.${server}.revision must be a commit hash: a branch or tag moves when the Hugging Face cache is updated.";
        }
        {
          assertion = serverCfg.chatTemplate == null || inStore "${serverCfg.chatTemplate}";
          message = "o11n.vllm.servers.${server}.chatTemplate must be in the Nix store, not a file on the host.";
        }
      ]) enabledServers
    );

    systemd.tmpfiles.rules = lib.optionals hasHome (
      lib.mapAttrsToList (
        server: _: "d '${serverHome server}' 0750 ${cfg.user} ${hostUser.group} - -"
      ) enabledServers
    );

    environment.systemPackages = [ vllmReport ];

    systemd.services =
      lib.mapAttrs' (
        server: _:
        lib.nameValuePair "container@${servers.${server}.container}" {
          serviceConfig = {
            TimeoutStopSec = 10;
            KillMode = "mixed";
          };
        }
      ) enabledServers
      // lib.optionalAttrs cfg.report.enable {
        vllm-report = {
          description = "Report of the vLLM servers";
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            User = cfg.user;
            Group = cfg.user;
            CacheDirectory = "vllm-report";
            ExecStart = lib.escapeShellArgs [
              (lib.getExe vllmReport)
              "--cache=/var/cache/vllm-report"
              "--listen=${cfg.report.host}"
              "--port=${toString cfg.report.port}"
            ];
          };
        };
      };

    containers = lib.mapAttrs' (
      server: serverCfg:
      lib.nameValuePair servers.${server}.container {
        autoStart = true;
        ephemeral = true;
        # The NixOS modules come from the same nixpkgs as the package set.
        nixpkgs = serverCfg.pkgs.path;

        allowedDevices = map (node: {
          inherit node;
          modifier = "rw";
        }) servers.${server}.devices;

        bindMounts =
          lib.genAttrs servers.${server}.devices (_: {
            isReadOnly = false;
          })
          // lib.genAttrs servers.${server}.readOnlyPaths (_: {
            isReadOnly = true;
          })
          # A home of the server's own, for the caches vLLM, Triton, FlashInfer and CUDA keep there.
          // lib.optionalAttrs hasHome {
            ${hostUser.home} = {
              hostPath = serverHome server;
              isReadOnly = false;
            };
          };

        config = {
          system.stateVersion = config.system.stateVersion;
          nixpkgs.pkgs = serverCfg.pkgs;

          # For diagnostics: the host driver's nvidia-smi, as only that matches the loaded
          # kernel module, and nix-shell with the container's nixpkgs.
          environment.systemPackages = [ config.hardware.nvidia.package.bin ];
          nix.nixPath = [ "nixpkgs=${toString serverCfg.nixpkgs}" ];

          users = {
            users.${cfg.user} = {
              isSystemUser = true;
              inherit (hostUser) uid group home;
              extraGroups = lib.remove hostUser.group hostGroups;
            };
            groups = lib.genAttrs hostGroups (group: {
              inherit (config.users.groups.${group}) gid;
            });
          };

          systemd.services.vllm = {
            description = "vLLM-${server} Inference Server";
            after = [ "network.target" ];
            wantedBy = [ "multi-user.target" ];

            path = servicePath serverCfg.pkgs;

            inherit (servers.${server}) environment;

            serviceConfig = {
              User = cfg.user;
              Group = hostUser.group;
              BindReadOnlyPaths = [ "/bin" ];
              ExecStart = lib.escapeShellArgs servers.${server}.argv;
            };
          };
        };
      }
    ) enabledServers;
  };
}
