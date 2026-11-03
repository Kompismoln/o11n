# nixos/org/archive.nix
{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  service = org.service.archive or null;
  store = org.store.archives or null;

  repos = "${store.principal.home}/repos";
  # Dependency: nixos/org/state-archive.nix reaches the archive at this port.
  port = 8000;

  ofHostRoles = kind: lib.concatMap (role: org.role.${role}.${kind}) host.roles;

  # Policy: an entity archives once it has an archive-passwd, whose public key is its htpasswd entry, so that the
  # archive holds no secret of the entities it serves.
  archiving = lib.filter (
    entity: builtins.pathExists (entity.publicKeys.archive-passwd or "/nonexistent")
  ) (lib.attrValues org.entities);

  htpasswd = pkgs.writeText "archive-htpasswd" (
    lib.concatMapStrings (
      entity: "${entity.handle}:${builtins.readFile entity.publicKeys.archive-passwd}"
    ) archiving
  );

  inherit (service) vpn;
  inherit (host.network.${vpn}.principals.service-archive) address fqdn;
  inherit (org.vpn.${vpn}) namespace;
  cert = org.certs.${namespace};
in
{
  assertions = [
    {
      assertion = service != null && lib.elem "archive" (ofHostRoles "services");
      message = "The archive role runs as the archive service: declare [service.archive] and add \"archive\" to the services of a role of ${host.name}'s.";
    }
    {
      assertion = service == null || service.principal != null;
      message = "The archive service runs as its principal: give [service.archive] an id.";
    }
    {
      assertion = store != null && lib.elem "archives" (ofHostRoles "stores");
      message = "The archive role keeps the repos in the archives store: declare [store.archives] and add \"archives\" to the stores of a role of ${host.name}'s.";
    }
    {
      assertion = store == null || (store.principal != null && store.principal.home != "/var/empty");
      message = "The archive role keeps the repos in the archives store's home: give [store.archives] an id, and leave principal.hasHome as it is.";
    }
    {
      assertion = store == null || store.principal == null || !store.principal.hasSFTP;
      message = "The archives store's ssh-key would reach every repo past the archive's own access: set principal.hasSFTP = false under [store.archives].";
    }
    {
      assertion = service == null || service.vpn != null;
      message = "The archive serves on one vpn: set vpn under [service.archive].";
    }
    {
      assertion = service == null || service.vpn == null || lib.elem service.vpn host.vpns;
      message = "The archive serves on ${toString (service.vpn or null)}, which ${host.name} isn't on: add it to ${host.name}'s vpns.";
    }
    {
      assertion = service == null || service.vpn == null || org.certs ? ${namespace};
      message = "The archive serves on ${fqdn} with ${namespace}'s tls-cert, which no service holds: declare [service.domain-${namespace}].";
    }
  ];

  # Duplication: as nixos/org/tls-certs.nix declares a namespace's tls-cert.
  sops.secrets."${cert.name}/tls-cert" = {
    inherit (cert.secrets) sopsFile;
    owner = "root";
    group = "tls-cert";
    mode = "0440";
    restartUnits = [ "archive.service" ];
  };

  users.groups.tls-cert = { };

  networking.firewall.interfaces.${org.vpn.${vpn}.interface}.allowedTCPPorts = [ port ];

  systemd.tmpfiles.rules = [
    "d '${repos}' 0770 ${store.name} ${store.name} - -"
  ];

  # Accommodating for the vpn, whose interface may come up after the socket: FreeBind binds the address anyway.
  systemd.sockets.archive = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "[${address}]:${toString port}" ];
    socketConfig.FreeBind = true;
  };

  # Policy: each entity has its own repo, at /<id>/, which rest-server creates as the entity first initializes it.
  systemd.services.archive = {
    description = "restic's rest-server, for the archive role";
    requires = [ "archive.socket" ];
    after = [ "archive.socket" ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe' pkgs.restic-rest-server "rest-server")
        "--path"
        repos
        "--htpasswd-file"
        htpasswd
        "--private-repos"
        "--group-accessible-repos"
        "--tls"
        "--tls-cert"
        cert.publicKeys.tls-cert
        "--tls-key"
        config.sops.secrets."${cert.name}/tls-cert".path
      ];
      User = service.name;
      Group = store.name;
      SupplementaryGroups = [ "tls-cert" ];
      UMask = "0007";
      ReadWritePaths = [ repos ];
      CapabilityBoundingSet = "";
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectProc = "invisible";
      ProtectSystem = "strict";
      RestrictAddressFamilies = "none";
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      SystemCallFilter = "@system-service";
    };
  };
}
