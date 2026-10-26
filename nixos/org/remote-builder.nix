# nixos/org/remote-builder.nix
{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  service = org.service.nix-remote;

  pathPrefix = "nix-daemon";

  address = "[${service.principal.bindAddress}]";
  tunnel = "${address}:8080";
  daemon = "${address}:7337";
  evaluator = "${address}:7338";

  # gost's plain HTTP tunnel (PHT): requests and responses only, so it passes proxies that
  # carry neither WebSockets nor HTTP/2, as a Claude session's does. The relay handler in
  # forward mode connects every client to the daemon, whatever destination it asks for.
  pht = "relay+pht://${tunnel}/${daemon}?${
    lib.concatMapStringsSep "&" (name: "${name}Path=/${pathPrefix}/${name}") [
      "authorize"
      "push"
      "pull"
    ]
  }";

  evaluates = org.repository != { };

  # Fact: nix-remote-eval.sh puts the revision where {rev} is.
  orgFlake =
    {
      github = "github:${org.repository.owner or ""}/${org.repository.repo or ""}/{rev}";
      git = "git+${org.repository.url or ""}?rev={rev}&allRefs=1";
    }
    .${org.repository.type or ""} or null;

  # Policy: an org gives nix-remote a key for its private inputs by creating one, which its
  # public half shows.
  hasSshKey = builtins.pathExists service.publicKeys.ssh-key;

  remoteEval = pkgs.writeShellApplication {
    name = "nix-remote-eval";
    runtimeInputs = [
      config.nix.package
      pkgs.git
      pkgs.jq
      pkgs.openssh
      pkgs.util-linux
    ];
    text = builtins.readFile ./nix-remote-eval.sh;
  };

  hardening = {
    CapabilityBoundingSet = "";
    LockPersonality = true;
    NoNewPrivileges = true;
    PrivateDevices = true;
    PrivateTmp = true;
    ProtectClock = true;
    ProtectControlGroups = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectSystem = "strict";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
  };
in
{
  imports = [
    ../nginx.nix
  ];

  assertions = [
    {
      assertion = host.endpoint != null;
      message = "The remote-builder role serves on the host's endpoint, and ${host.name} has none.";
    }
    {
      assertion = evaluates -> orgFlake != null;
      message = ''The remote-builder role evaluates the org from [repository] in org.toml, whose type has to be "github" or "git".'';
    }
  ];

  sops.secrets."nix-remote/secret-key" = {
    inherit (service.secrets) sopsFile;
  };

  sops.secrets."nix-remote/ssh-key" = lib.mkIf (evaluates && hasSshKey) {
    inherit (service.secrets) sopsFile;
    owner = service.name;
  };

  sops.templates."nix-remote/nginx-bearer" = {
    content = ''"Bearer ${config.sops.placeholder."nix-remote/secret-key"}" 1;'';
    owner = config.services.nginx.user;
    reloadUnits = [ "nginx.service" ];
  };

  o11n.nginx.enable = true;

  services.nginx = {
    # The default bucket is too small for a key of "Bearer " and a 40-byte base64 secret.
    mapHashBucketSize = 128;
    appendHttpConfig = ''
      map $http_authorization $nix_remote_authorized {
        default 0;
        include ${config.sops.templates."nix-remote/nginx-bearer".path};
      }
    '';
    virtualHosts.${host.endpoint} = {
      forceSSL = true;
      enableACME = true;
      locations."/${pathPrefix}/" = {
        proxyPass = "http://${tunnel}";
        extraConfig = ''
          if ($nix_remote_authorized = 0) {
            return 401;
          }
          proxy_http_version 1.1;
          proxy_set_header Connection "";
          proxy_buffering off;
          proxy_request_buffering off;
        '';
      };
      locations."/nix-eval/" = lib.mkIf evaluates {
        proxyPass = "http://${evaluator}";
        extraConfig = ''
          if ($nix_remote_authorized = 0) {
            return 401;
          }
          proxy_buffering off;
          # Fact: compression holds the output back until a block of it is in.
          gzip off;
          brotli off;
        '';
      };
    };
  };

  systemd.services.nix-remote-tunnel = {
    description = "PHT tunnel to the nix-daemon relay";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      ExecStart = "${lib.getExe pkgs.gost} -L ${lib.escapeShellArg pht}";
      DynamicUser = true;
      Restart = "on-failure";
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
    }
    // hardening;
  };

  # One nix-daemon --stdio per connection, as the untrusted user nix-remote: it relays the
  # connection to the system daemon, which builds in its sandbox and never trusts the client.
  systemd.sockets.nix-remote = {
    wantedBy = [ "sockets.target" ];
    # switch-to-configuration leaves a changed socket listening nowhere until it is
    # restarted. The tunnel names the same address, so it restarts when that changes.
    partOf = [ "nix-remote-tunnel.service" ];
    listenStreams = [ daemon ];
    socketConfig.Accept = true;
  };

  systemd.services."nix-remote@" = {
    description = "nix-daemon relay for a remote client";
    environment.NIX_REMOTE = "daemon";
    serviceConfig = {
      ExecStart = "${config.nix.package}/bin/nix-daemon --stdio";
      User = service.name;
      Group = service.name;
      StandardInput = "socket";
      StandardOutput = "socket";
      # Anything else on the socket would corrupt the protocol.
      StandardError = "journal";
      RestrictAddressFamilies = [ "AF_UNIX" ];
    }
    // hardening;
  };

  # Policy: one evaluation per connection, as nix-remote, of a stage of the org's own flake;
  # a request names the stage and the revisions, and nothing else.
  systemd.sockets.nix-remote-eval = lib.mkIf evaluates {
    wantedBy = [ "sockets.target" ];
    # Accommodating for switch-to-configuration, as nix-remote's socket does.
    partOf = [ "nix-remote-tunnel.service" ];
    listenStreams = [ evaluator ];
    socketConfig.Accept = true;
  };

  systemd.services."nix-remote-eval@" = lib.mkIf evaluates {
    description = "evaluation of the org's stages for a remote client";
    environment = {
      NIX_REMOTE = "daemon";
      ORG_FLAKE = orgFlake;
      HEARTBEAT = "30";
      HOME = "/var/cache/nix-remote-eval";
    }
    // lib.optionalAttrs hasSshKey {
      GIT_SSH_COMMAND = lib.concatStringsSep " " [
        "ssh -i ${config.sops.secrets."nix-remote/ssh-key".path} -o IdentitiesOnly=yes"
        "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/var/cache/nix-remote-eval/known_hosts"
      ];
    };
    serviceConfig = {
      ExecStart = lib.getExe remoteEval;
      User = service.name;
      Group = service.name;
      StandardInput = "socket";
      StandardOutput = "socket";
      StandardError = "journal";
      CacheDirectory = "nix-remote-eval";
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
        "AF_NETLINK"
      ];
    }
    // hardening;
  };
}
