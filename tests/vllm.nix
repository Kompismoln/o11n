# tests/vllm.nix
{
  pkgs,
  o11nLib,
}:
let
  inherit (pkgs) lib;
  inherit (import ./lib.nix { inherit pkgs; }) evalNixosModule;

  # Stand-ins for vLLM and the host's driver, so the test doesn't evaluate CUDA.
  vllm = pkgs.writeShellScriptBin "vllm" "";
  nvidia = pkgs.runCommand "nvidia-x11" {
    outputs = [
      "out"
      "bin"
    ];
  } "mkdir $out $bin";

  # A model's commit in the Hugging Face cache, and a model and chat template in the store.
  commit = "0123456789abcdef0123456789abcdef01234567";
  localModel = pkgs.runCommand "local-model" { } "mkdir $out";
  template = builtins.toFile "local.jinja" "";

  # A nixpkgs pin with a vLLM of its own, which the host doesn't have.
  pin = builtins.toFile "nixpkgs-pin.nix" ''
    args:
    (import ${toString pkgs.path} args).extend (final: _: {
      vllm = final.writeShellScriptBin "vllm" "# from the pin";
    })
  '';

  baseConfig = {
    users = {
      users = {
        vllm = {
          isSystemUser = true;
          group = "vllm";
          uid = 3002;
          home = "/var/lib/vllm";
        };
        huggingface = {
          isSystemUser = true;
          group = "huggingface";
          uid = 3001;
          home = "/var/lib/huggingface";
        };
      };
      groups = {
        vllm.gid = 3002;
        huggingface = {
          gid = 3001;
          members = [ "vllm" ];
        };
      };
    };

    o11n = {
      huggingface = {
        enable = true;
        repo = "/srv/models/huggingface";
      };
      vllm = {
        enable = true;
        servers = {
          chat = {
            package = vllm;
            port = 8000;
            model = "Qwen/Qwen3-8B";
            revision = commit;
            chatTemplate = template;
            allowedGPUs = [ 1 ];
          };
          local = {
            nixpkgs = pin;
            port = 8001;
            model = "${localModel}";
            chatTemplate = template;
          };
        };
      };
    };

    hardware.nvidia.package = nvidia;

    system.stateVersion = lib.trivial.release;
  };

  cfg = evalNixosModule [
    ../nixos/huggingface.nix
    ../nixos/vllm.nix
    baseConfig
  ];

  # Servers reading what can change under them, next to the ones above that don't.
  unpinnedCfg = evalNixosModule [
    ../nixos/huggingface.nix
    ../nixos/vllm.nix
    baseConfig
    {
      o11n.vllm.servers = {
        branch = {
          package = vllm;
          port = 8002;
          model = "Qwen/Qwen3-8B";
          revision = "main";
          chatTemplate = template;
        };
        default = {
          package = vllm;
          port = 8003;
          model = "Qwen/Qwen3-8B";
          chatTemplate = template;
        };
        host = {
          package = vllm;
          port = 8004;
          model = "/srv/models/local";
          chatTemplate = "/srv/templates/local.jinja";
        };
        overriding = {
          package = vllm;
          port = 8005;
          model = "Qwen/Qwen3-8B";
          revision = commit;
          chatTemplate = template;
          extraArgs = [
            "--chat-template=/srv/templates/local.jinja"
            "--trust_request_chat_template"
          ];
        };
      };
    }
  ];

  noTemplateCfg = evalNixosModule [
    ../nixos/huggingface.nix
    ../nixos/vllm.nix
    baseConfig
    {
      o11n.vllm.servers.bare = {
        package = vllm;
        port = 8006;
        model = "Qwen/Qwen3-8B";
        revision = commit;
      };
    }
  ];

  pinned = import pin { inherit (pkgs.stdenv.hostPlatform) system; };
  chat = cfg.containers.vllm-chat;
  local = cfg.containers.vllm-local;
in
lib.runTests {

  test_vllm_runs_in_containers = {
    expr = lib.filter (lib.hasInfix "vllm") (lib.attrNames cfg.systemd.services);
    expected = [
      "container@vllm-chat"
      "container@vllm-local"
    ];
  };

  test_vllm_from_container_nixpkgs = {
    expr = local.config.systemd.services.vllm.serviceConfig.ExecStart;
    expected = "${pinned.vllm}/bin/vllm serve ${localModel} '--host=127.0.0.1' '--port=8001' '--chat-template=${template}'";
  };

  test_vllm_model_inputs_pinned = {
    expr = map (assertion: assertion.message) (
      lib.filter (
        assertion: !assertion.assertion && lib.hasPrefix "o11n.vllm.servers." assertion.message
      ) unpinnedCfg.assertions
    );
    expected = [
      "o11n.vllm.servers.branch.revision must be a commit hash: a branch or tag moves when the Hugging Face cache is updated."
      "o11n.vllm.servers.default.revision must be a commit hash: a branch or tag moves when the Hugging Face cache is updated."
      "o11n.vllm.servers.host.model must be a Hugging Face model ID or a path in the Nix store, not a path on the host."
      "o11n.vllm.servers.host.chatTemplate must be in the Nix store, not a file on the host."
      "o11n.vllm.servers.overriding.extraArgs must not set --chat-template: set chatTemplate, which the report covers."
      "o11n.vllm.servers.overriding.extraArgs must not set --trust-request-chat-template: it lets a request replace the chat template."
    ];
  };

  test_vllm_chat_template_required = {
    expr = (builtins.tryEval noTemplateCfg.o11n.vllm.servers.bare.chatTemplate).success;
    expected = false;
  };

  test_vllm_container_home = {
    expr = {
      mount = chat.bindMounts."/var/lib/vllm";
      rules = lib.filter (lib.hasPrefix "d '/var/lib/vllm/") cfg.systemd.tmpfiles.rules;
    };
    expected = {
      mount = {
        mountPoint = "/var/lib/vllm";
        hostPath = "/var/lib/vllm/vllm-chat";
        isReadOnly = false;
      };
      rules = [
        "d '/var/lib/vllm/vllm-chat' 0750 vllm vllm - -"
        "d '/var/lib/vllm/vllm-local' 0750 vllm vllm - -"
      ];
    };
  };

  test_vllm_container_diagnostics = {
    expr = {
      nvidia = lib.filter (p: lib.getName p == "nvidia-x11") chat.config.environment.systemPackages;
      nixPath = local.config.nix.nixPath;
    };
    expected = {
      nvidia = [ nvidia.bin ];
      nixPath = [ "nixpkgs=${pin}" ];
    };
  };

  test_vllm_container_devices = {
    expr = map (device: device.node) chat.allowedDevices;
    expected = [
      "/dev/nvidiactl"
      "/dev/nvidia-uvm"
      "/dev/nvidia-uvm-tools"
      "/dev/nvidia-modeset"
      "/dev/nvidia1"
    ];
  };

  test_vllm_container_bind_mounts = {
    expr = lib.mapAttrs (_: mount: mount.isReadOnly) local.bindMounts;
    expected = {
      "/dev/nvidiactl" = false;
      "/dev/nvidia-uvm" = false;
      "/dev/nvidia-uvm-tools" = false;
      "/dev/nvidia-modeset" = false;
      "/dev/nvidia0" = false;
      "/run/opengl-driver" = true;
      "/srv/models/huggingface" = true;
      "/var/lib/vllm" = false;
    };
  };

  test_vllm_container_user = {
    expr = {
      inherit (chat.config.users.users.vllm)
        uid
        group
        home
        extraGroups
        ;
      gids = lib.mapAttrs (_: group: group.gid) {
        inherit (chat.config.users.groups) vllm huggingface;
      };
    };
    expected = {
      uid = 3002;
      group = "vllm";
      home = "/var/lib/vllm";
      extraGroups = [ "huggingface" ];
      gids = {
        vllm = 3002;
        huggingface = 3001;
      };
    };
  };

  test_vllm_container_service = {
    expr = {
      inherit (chat.config.systemd.services.vllm.serviceConfig) User ExecStart;
    };
    expected = {
      User = "vllm";
      ExecStart = "${vllm}/bin/vllm serve /srv/models/huggingface/models--Qwen--Qwen3-8B/snapshots/${commit} '--host=127.0.0.1' '--port=8000' '--revision=${commit}' '--chat-template=${template}'";
    };
  };

}
