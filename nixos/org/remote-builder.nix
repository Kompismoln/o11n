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
  ];

  sops.secrets."nix-remote/secret-key" = {
    inherit (service.secrets) sopsFile;
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
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
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
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
    };
  };
}
