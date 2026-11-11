{
  config,
  host,
  lib,
  org,
  pkgs,
  ...
}:
let
  service = org.service.torrent-server;
  inherit (service) name;
  inherit (service.principal) uid gid;

  settings =
    service.hosts.${host.name} or {
      upload = null;
      download = null;
      ratio = null;
      peerPort = 51413;
    };

  allotment = lib.findFirst (allotment: allotment.entity == service.handle) null host.allotments;
  allotmentUnit = "allotment@${service.handle}.service";

  home = config.o11n.preserve.onStorage "/var/lib/${name}";
  rpc = "127.0.0.1:${toString config.services.transmission.settings.rpc-port}";

  control = pkgs.writeShellApplication {
    name = "torrent-server";
    runtimeInputs = [
      pkgs.coreutils
      config.services.transmission.package
    ];
    runtimeEnv.TRANSMISSION_RPC = rpc;
    text = builtins.readFile ./torrent-server.sh;
  };

  limit = value: {
    value = if value == null then 0 else value;
    enabled = value != null;
  };
  upload = limit settings.upload;
  download = limit settings.download;
  ratio = limit settings.ratio;
in
{
  assertions = [
    {
      assertion = allotment != null;
      message = "service.torrent-server on ${host.name}: the server keeps what it downloads in an allotment of its own, and ${host.name} has none: add allotment.\"${service.handle}@${host.name}\" with its size.";
    }
    {
      assertion = builtins.pathExists service.publicKeys.ssh-key;
      message = "service.torrent-server on ${host.name}: o11n torrent logs in with the service's ssh-key, and it has none: o11n secret generate ${service.handle} ssh-key.";
    }
  ];

  services.transmission = lib.mkIf (allotment != null) {
    enable = true;
    package = pkgs.transmission_4;
    user = name;
    group = name;
    inherit home;
    openPeerPorts = true;
    settings = {
      download-dir = allotment.path;
      # Policy: what's still downloading is in the allotment too, by the name it'll have with .part after it, so that
      # the allotment's size bounds it.
      incomplete-dir-enabled = false;
      rename-partial-files = true;
      peer-port = settings.peerPort;
      rpc-bind-address = "127.0.0.1";
      speed-limit-up = upload.value;
      speed-limit-up-enabled = upload.enabled;
      speed-limit-down = download.value;
      speed-limit-down-enabled = download.enabled;
      ratio-limit = ratio.value;
      ratio-limit-enabled = ratio.enabled;
    };
  };

  # Fact: transmission's unit binds its download-dir into its root directory, which the allotment's unit mounts, and its
  # settings' directory, which transmission-setup makes in a home of transmission's but the default, and nothing wants.
  systemd.services.transmission = lib.mkIf (allotment != null) {
    requires = [
      allotmentUnit
      "transmission-setup.service"
    ];
    after = [ allotmentUnit ];
  };

  systemd.tmpfiles.rules = [
    "d '${home}' 0700 ${toString uid} ${toString gid} - -"
  ];

  # Policy: the service's ssh-key runs control alone, with nothing forwarded; it's no one's way to a shell. Any other
  # key, as an allotment's sftp client's, is let in as the allotment's logins have it.
  users.users.${name} = {
    shell = pkgs.bash;
    openssh.authorizedKeys = {
      keyFiles = lib.mkForce [ ];
      keys = lib.optional (builtins.pathExists service.publicKeys.ssh-key) ''restrict,command="${lib.getExe control}" ${lib.trim (builtins.readFile service.publicKeys.ssh-key)}'';
    };
  };
}
