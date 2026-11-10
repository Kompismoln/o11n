{
  pkgs,
  lib,
  evalNixosModule,
}:
let

  nvidia = pkgs.runCommand "nvidia-x11" {
    outputs = [
      "out"
      "bin"
    ];
  } "mkdir $out $bin";

  commit = "0123456789abcdef0123456789abcdef01234567";
  localModel = pkgs.runCommand "local-model" { } "mkdir $out";
  template = builtins.toFile "local.jinja" "";

  # Fact: a nixpkgs pin with an empty vLLM, in place of the host's.
  stub = builtins.toFile "nixpkgs-stub.nix" ''
    args:
    (import ${toString pkgs.path} args).extend (final: _: {
      vllm = final.writeShellScriptBin "vllm" "";
    })
  '';

  # Fact: a nixpkgs pin with a vLLM of its own, which the host doesn't have.
  pin = builtins.toFile "nixpkgs-pin.nix" ''
    args:
    (import ${toString pkgs.path} args).extend (final: _: {
      vllm = final.writeShellScriptBin "vllm" "# from the pin";
    })
  '';

  server =
    attrs:
    {
      nixpkgs = "stub";
      revision = null;
      servedModelNames = [ ];
      harmony = false;
      host = "127.0.0.1";
      extraArgs = [ ];
      environment = { };
      allowedGPUs = [ 0 ];
    }
    // attrs;

  evalWith =
    report: servers:
    evalNixosModule [
      ../../nixos/services/vllm.nix
      {
        _module.args = {
          host = {
            name = "testhost";
            vpns = [ "wg0" ];
            network.wg0 = {
              address = "fd00::9";
              address4 = "10.0.0.9";
            };
          };
          inputs = { inherit pin stub; };
          org = {
            vpn.wg0.interface = "wg0";
            service.vllm.hosts.testhost = { inherit report servers; };
          };
        };

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

        hardware.nvidia.package = nvidia;
        nixpkgs.config.allowUnfree = true;

        system.stateVersion = lib.trivial.release;
      }
    ];

  eval = evalWith {
    enable = false;
    host = "127.0.0.1";
    port = 12008;
  };

  cfg = eval {
    chat = server {
      port = 8000;
      model = "Qwen/Qwen3-8B";
      revision = commit;
      chatTemplate = template;
      allowedGPUs = [ 1 ];
    };
    local = server {
      nixpkgs = "pin";
      port = 8001;
      model = "${localModel}";
      chatTemplate = template;
    };
  };

  # Fact: a server whose chat goes through Harmony.
  harmonyCfg = eval {
    talk = server {
      port = 8006;
      model = "openai/gpt-oss-20b";
      revision = commit;
      chatTemplate = template;
      harmony = true;
    };
  };

  # Fact: servers reading what can change under them.
  unpinnedCfg = eval {
    branch = server {
      port = 8002;
      model = "Qwen/Qwen3-8B";
      revision = "main";
      chatTemplate = template;
    };
    default = server {
      port = 8003;
      model = "Qwen/Qwen3-8B";
      chatTemplate = template;
    };
    host = server {
      port = 8004;
      model = "/srv/models/local";
      chatTemplate = "/srv/templates/local.jinja";
    };
    overriding = server {
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

  # Fact: a server and a report for the host's vpns.
  servedCfg =
    evalWith
      {
        enable = true;
        host = "::";
        port = 12008;
      }
      {
        chat = server {
          host = "::";
          port = 8000;
          model = "Qwen/Qwen3-8B";
          revision = commit;
          chatTemplate = template;
        };
      };

  pinned = import pin { inherit (pkgs.stdenv.hostPlatform) system; };
  inherit (import stub { inherit (pkgs.stdenv.hostPlatform) system; }) vllm;
  chat = cfg.containers.vllm-chat;
  local = cfg.containers.vllm-local;
  talk = harmonyCfg.containers.vllm-talk;
in
{

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
        assertion:
        !assertion.assertion && lib.hasPrefix "service.vllm.hosts.testhost.servers." assertion.message
      ) unpinnedCfg.assertions
    );
    expected = [
      "service.vllm.hosts.testhost.servers.branch.revision must be a commit hash: a branch or tag moves when the Hugging Face cache is updated."
      "service.vllm.hosts.testhost.servers.default.revision must be a commit hash: a branch or tag moves when the Hugging Face cache is updated."
      "service.vllm.hosts.testhost.servers.host.model must be a Hugging Face model ID or a path in the Nix store, not a path on the host."
      "service.vllm.hosts.testhost.servers.host.chatTemplate must be in the Nix store, not a file on the host."
      "service.vllm.hosts.testhost.servers.overriding.extraArgs must not set --chat-template: set chatTemplate, which the report covers."
      "service.vllm.hosts.testhost.servers.overriding.extraArgs must not set --trust-request-chat-template: it lets a request replace the chat template."
    ];
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

  # Policy: a server and report for the vpns listen on loopback, which the vpn proxies pass on to, and the container
  # reaches nothing else.
  test_vllm_on_vpns = {
    expr = {
      inherit (servedCfg.o11n) vpnProxies;
      sockets = lib.mapAttrs (_: socket: socket.listenStreams) {
        inherit (servedCfg.systemd.sockets) vllm-chat-vpn vllm-report-vpn;
      };
      ports = servedCfg.networking.firewall.interfaces.wg0.allowedTCPPorts;
      server = lib.hasInfix "'--host=127.0.0.1'" servedCfg.containers.vllm-chat.config.systemd.services.vllm.serviceConfig.ExecStart;
      container = {
        inherit (servedCfg.systemd.services."container@vllm-chat".serviceConfig)
          IPAddressAllow
          IPAddressDeny
          ;
      };
    };
    expected = {
      vpnProxies = {
        vllm-chat = {
          port = 8000;
          to = "127.0.0.1:8000";
        };
        vllm-report = {
          port = 12008;
          to = "127.0.0.1:12008";
        };
      };
      sockets = {
        vllm-chat-vpn = [
          "[fd00::9]:8000"
          "10.0.0.9:8000"
        ];
        vllm-report-vpn = [
          "[fd00::9]:12008"
          "10.0.0.9:12008"
        ];
      };
      ports = [
        8000
        12008
      ];
      server = true;
      container = {
        IPAddressAllow = "localhost";
        IPAddressDeny = "any";
      };
    };
  };

  # Policy: a Harmony server reads tiktoken's encodings from the store, as it can't download them, and another has none.
  test_vllm_tiktoken_encodings = {
    expr = {
      harmony = lib.hasSuffix "-tiktoken-encodings" talk.config.systemd.services.vllm.environment.TIKTOKEN_ENCODINGS_BASE;
      other = chat.config.systemd.services.vllm.environment ? TIKTOKEN_ENCODINGS_BASE;
    };
    expected = {
      harmony = true;
      other = false;
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
