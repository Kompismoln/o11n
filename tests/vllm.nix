# tests/vllm.nix
{
  pkgs,
  o11nLib,
}:
let
  inherit (pkgs) lib;
  inherit (import ./lib.nix { inherit pkgs; }) evalNixosModule;

  # A stand-in for vLLM, so the test doesn't evaluate CUDA.
  vllm = pkgs.writeShellScriptBin "vllm" "";

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
            allowedGPUs = [ 1 ];
          };
          local = {
            package = vllm;
            # Never evaluated: the tests below don't look into this container's config.
            nixpkgs = "/srv/nixpkgs";
            port = 8001;
            model = "/srv/models/local";
            chatTemplate = "/srv/templates/local.jinja";
          };
        };
      };
    };

    system.stateVersion = lib.trivial.release;
  };

  cfg = evalNixosModule [
    ../nixos/huggingface.nix
    ../nixos/vllm.nix
    baseConfig
  ];

  chat = cfg.containers.vllm-chat;
in
lib.runTests {

  test_vllm_runs_in_containers = {
    expr = lib.filter (lib.hasInfix "vllm") (lib.attrNames cfg.systemd.services);
    expected = [
      "container@vllm-chat"
      "container@vllm-local"
    ];
  };

  test_vllm_container_nixpkgs = {
    expr = {
      chat = chat.nixpkgs;
      local = cfg.containers.vllm-local.nixpkgs;
    };
    expected = {
      chat = pkgs.path;
      local = "/srv/nixpkgs";
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
    expr = lib.mapAttrs (_: mount: mount.isReadOnly) cfg.containers.vllm-local.bindMounts;
    expected = {
      "/dev/nvidiactl" = false;
      "/dev/nvidia-uvm" = false;
      "/dev/nvidia-uvm-tools" = false;
      "/dev/nvidia-modeset" = false;
      "/dev/nvidia0" = false;
      "/run/opengl-driver" = true;
      "/srv/models/huggingface" = true;
      "/srv/models/local" = true;
      "/srv/templates/local.jinja" = true;
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
      ExecStart = "${vllm}/bin/vllm serve Qwen/Qwen3-8B '--host=127.0.0.1' '--port=8000'";
    };
  };

}
