# nixos/services/vllm.nix
{
  config,
  host,
  inputs,
  lib,
  org,
  pkgs,
  ...
}:

let
  settings =
    org.service.vllm.hosts.${host.name} or {
      report = {
        enable = false;
        host = "127.0.0.1";
        port = 12008;
      };
      servers = { };
    };

  cfg = {
    user = "vllm";
    inherit (settings) report;
    servers = lib.mapAttrs (
      name: server:
      let
        nixpkgs = if server.nixpkgs == null then pkgs.path else inputs.${server.nixpkgs};
        serverPkgs = import nixpkgs {
          inherit (pkgs.stdenv.hostPlatform) system;
          inherit (hostConfig.nixpkgs) config overlays;
        };
      in
      server
      // {
        inherit name nixpkgs;
        pkgs = serverPkgs;
        package = serverPkgs.vllm;
      }
    ) settings.servers;
  };
  hostConfig = config;

  # Dependency: nixos/huggingface.nix keeps the cache there.
  huggingface = {
    inherit (config.users.users.huggingface) home;
    repo = "/srv/models/huggingface";
  };

  servicePath = serverPkgs: [
    serverPkgs.which
    serverPkgs.gcc
    serverPkgs.cudaPackages.cudatoolkit
  ];

  hostUser = config.users.users.${cfg.user};
  hasHome = hostUser.home != "/var/empty";

  # Policy: each server's home inside the container: its own directory in the user's home on the host,
  # on storage where the host preserves.
  serverHome =
    server: config.o11n.preserve.onStorage "${hostUser.home}/${servers.${server}.container}";

  isLocal = lib.hasPrefix "/";
  inStore = lib.hasPrefix "${builtins.storeDir}/";
  isCommit = revision: revision != null && builtins.match "[0-9a-f]{40}" revision != null;

  # Accommodating for huggingface_hub, which refuses a snapshot that lacks any file of its commit, even one vLLM
  # never reads: offline, vLLM resolves a model ID with it, so it's given the ID's snapshot in the cache instead.
  modelPath =
    serverCfg:
    if isLocal serverCfg.model then
      serverCfg.model
    else
      "${huggingface.repo}/models--${
        builtins.replaceStrings [ "/" ] [ "--" ] serverCfg.model
      }/snapshots/${toString serverCfg.revision}";

  # Fact: the options a server's extraArgs set, as vLLM reads them: `--a_b=c` sets `--a-b`.
  extraOptions =
    serverCfg:
    map (
      arg: lib.head (lib.splitString "=" (builtins.replaceStrings [ "_" ] [ "-" ] arg))
    ) serverCfg.extraArgs;

  # Fact: the groups cfg.user is in on the host: its own, its extra ones and those listing it as a member.
  hostGroups = lib.unique (
    [ hostUser.group ]
    ++ hostUser.extraGroups
    ++ lib.attrNames (lib.filterAttrs (_: group: lib.elem cfg.user group.members) config.users.groups)
  );

  servers = lib.mapAttrs (_: serverCfg: {
    container = "vllm-${serverCfg.name}";

    argv = [
      (lib.getExe' serverCfg.package "vllm")
      "serve"
      (modelPath serverCfg)
      "--host=${serverCfg.host}"
      "--port=${toString serverCfg.port}"
    ]
    ++ lib.optional (serverCfg.revision != null) "--revision=${serverCfg.revision}"
    ++ [ "--chat-template=${serverCfg.chatTemplate}" ]
    ++ lib.optionals (serverCfg.servedModelNames != [ ]) (
      [ "--served-model-name" ] ++ serverCfg.servedModelNames
    )
    ++ serverCfg.extraArgs;

    environment = {
      HF_HOME = huggingface.home;
      HF_HUB_CACHE = huggingface.repo;
      HF_HUB_OFFLINE = "1";
      CUDA_VISIBLE_DEVICES = lib.concatMapStringsSep "," toString serverCfg.allowedGPUs;
      CUDA_HOME = "${serverCfg.pkgs.cudaPackages.cudatoolkit}";
      VLLM_USE_FLASHINFER_SAMPLER = "0";
    }
    // serverCfg.environment;

    # Policy: everything the server runs from the store: its path changes when any of it does,
    # and `nix-store -qR` on it gives the whole runtime closure. Built from the container's
    # package set under one name, so servers running the same packages share it, and the
    # host's nixpkgs or a server's name don't move it.
    runtime = serverCfg.pkgs.writeTextFile {
      name = "vllm-runtime";
      text = lib.concatMapStrings (p: "${p}\n") ([ serverCfg.package ] ++ servicePath serverCfg.pkgs);
    };

    devices = [
      "/dev/nvidiactl"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
      "/dev/nvidia-modeset"
    ]
    ++ map (i: "/dev/nvidia${toString i}") serverCfg.allowedGPUs;

    # Fact: what the server reads from the host outside the store: the driver's libraries
    # and the Hugging Face cache.
    readOnlyPaths = [
      "/run/opengl-driver"
      huggingface.repo
    ];
  }) cfg.servers;

  reportConfig = pkgs.writeText "vllm-report.json" (
    builtins.toJSON {
      hostname = config.networking.hostName;
      hub_cache = huggingface.repo;
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
        chat_template = "${serverCfg.chatTemplate}";
        served_model_names = serverCfg.servedModelNames;
        extra_args = serverCfg.extraArgs;
        gpus = serverCfg.allowedGPUs;
      }) cfg.servers;
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
  imports = [
    ../huggingface.nix
    ../preserve-paths.nix
  ];

  config = {
    # Policy: what a server reads must not change under it: no host paths, no moving revisions.
    assertions = lib.concatLists (
      lib.mapAttrsToList (server: serverCfg: [
        {
          assertion = isLocal serverCfg.model -> inStore serverCfg.model;
          message = "service.vllm.hosts.${host.name}.servers.${server}.model must be a Hugging Face model ID or a path in the Nix store, not a path on the host.";
        }
        {
          assertion = !isLocal serverCfg.model -> isCommit serverCfg.revision;
          message = "service.vllm.hosts.${host.name}.servers.${server}.revision must be a commit hash: a branch or tag moves when the Hugging Face cache is updated.";
        }
        {
          assertion = inStore "${serverCfg.chatTemplate}";
          message = "service.vllm.hosts.${host.name}.servers.${server}.chatTemplate must be in the Nix store, not a file on the host.";
        }
        {
          assertion = !lib.elem "--chat-template" (extraOptions serverCfg);
          message = "service.vllm.hosts.${host.name}.servers.${server}.extraArgs must not set --chat-template: set chatTemplate, which the report covers.";
        }
        {
          assertion = !lib.elem "--trust-request-chat-template" (extraOptions serverCfg);
          message = "service.vllm.hosts.${host.name}.servers.${server}.extraArgs must not set --trust-request-chat-template: it lets a request replace the chat template.";
        }
      ]) cfg.servers
    );

    systemd.tmpfiles.rules = lib.optionals hasHome (
      lib.mapAttrsToList (
        server: _: "d '${serverHome server}' 0750 ${cfg.user} ${hostUser.group} - -"
      ) cfg.servers
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
      ) cfg.servers
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
        # Policy: the NixOS modules come from the same nixpkgs as the package set.
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
          # Policy: a home of the server's own, for the caches vLLM, Triton, FlashInfer and CUDA keep there.
          // lib.optionalAttrs hasHome {
            ${hostUser.home} = {
              hostPath = serverHome server;
              isReadOnly = false;
            };
          };

        config = {
          system.stateVersion = config.system.stateVersion;
          nixpkgs.pkgs = serverCfg.pkgs;

          # Policy: for diagnostics, the host driver's nvidia-smi, as only that matches the loaded
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
    ) cfg.servers;
  };
}
