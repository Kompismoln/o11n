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
  cfg = config.o11n.torrent-server;

  settings =
    service.hosts.${host.name} or {
      upload = null;
      download = null;
      ratio = null;
      peerPort = 51413;
    };

  allotments = lib.filter (allotment: allotment.torrent) host.allotments;
  staged = allotment: "/run/torrent-server/${allotment.entity}";
  mountUnit = allotment: "torrent-server-mount@${allotment.entity}";

  # Policy: Transmission reaches each allotment it downloads into through a bind mount that maps the principal's ids to
  # its own, so that what it writes is the principal's, and it reaches nothing else of the allotment's host that way.
  mount =
    allotment:
    let
      inherit (org.entities.${allotment.entity}) principal;
      at = staged allotment;
    in
    {
      description = "the allotment of ${allotment.entity}, as the torrent-server writes into it";
      after = [ "allotment@${allotment.entity}.service" ];
      bindsTo = [ "allotment@${allotment.entity}.service" ];
      path = [ pkgs.util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStop = "${pkgs.util-linux}/bin/umount ${lib.escapeShellArg at}";
      };
      script = ''
        install -d -m 0700 /run/torrent-server ${lib.escapeShellArg at}
        if ! mountpoint -q ${lib.escapeShellArg at}; then
          mount --bind -o ${lib.escapeShellArg "X-mount.idmap=u:${toString principal.uid}:${toString uid}:1 g:${toString principal.gid}:${toString gid}:1"} ${lib.escapeShellArg allotment.path} ${lib.escapeShellArg at}
        fi
      '';
    };

  control = pkgs.writeShellApplication {
    name = "torrent-server";
    runtimeInputs = [
      pkgs.coreutils
      config.services.transmission.package
    ];
    runtimeEnv = {
      TRANSMISSION_RPC = rpc;
      TORRENT_TO = lib.concatStringsSep " " (lib.mapAttrsToList (to: dir: "${to}=${dir}") cfg.targets);
      TORRENT_AS = lib.concatStringsSep " " (lib.mapAttrsToList (kind: dir: "${kind}=${dir}") cfg.kinds);
      TORRENT_DEFAULT = if cfg.default == null then "" else cfg.default;
    };
    text = builtins.readFile ./torrent-server.sh;
  };

  home = config.o11n.preserve.onStorage "/var/lib/${name}";
  rpc = "127.0.0.1:${toString config.services.transmission.settings.rpc-port}";

  limit = value: {
    value = if value == null then 0 else value;
    enabled = value != null;
  };
  upload = limit settings.upload;
  download = limit settings.download;
  ratio = limit settings.ratio;

  inside = dir: lib.any (allotment: lib.hasPrefix "${allotment.path}/" "${dir}/") allotments;
in
{
  options.o11n.torrent-server = {
    targets = lib.mkOption {
      description = "the directory a download goes to for each allotment `--to` names, in that allotment";
      type = lib.types.attrsOf lib.types.str;
    };
    kinds = lib.mkOption {
      description = "the directory a download goes to for each kind `--as` names, in an allotment it downloads into";
      type = lib.types.attrsOf lib.types.str;
      default = { };
    };
    default = lib.mkOption {
      description = "the directory a download goes to when neither `--to` nor `--as` says, or null for one of them to say";
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
  };

  config = {
    assertions = [
      {
        assertion = allotments != [ ];
        message = "service.torrent-server on ${host.name}: the server downloads into the allotments on ${host.name} that allow it, and none does: set torrent = true on one, as allotment.\"service-media-server@${host.name}\".";
      }
      {
        assertion = builtins.pathExists service.publicKeys.ssh-key;
        message = "service.torrent-server on ${host.name}: o11n torrent logs in with the service's ssh-key, and it has none: o11n secret generate ${service.handle} ssh-key.";
      }
    ]
    ++
      map
        (dir: {
          assertion = inside dir;
          message = "service.torrent-server on ${host.name}: ${dir} is in no allotment the server downloads into.";
        })
        (
          lib.attrValues cfg.targets
          ++ lib.attrValues cfg.kinds
          ++ lib.optional (cfg.default != null) cfg.default
        );

    o11n.torrent-server = {
      targets = lib.listToAttrs (
        map (allotment: lib.nameValuePair allotment.entity (lib.mkDefault allotment.path)) allotments
      );
      default = lib.mkIf (lib.length allotments == 1) (
        lib.mkDefault cfg.targets.${(lib.head allotments).entity}
      );
    };

    systemd.services = lib.mkMerge [
      (lib.listToAttrs (
        map (allotment: lib.nameValuePair (mountUnit allotment) (mount allotment)) allotments
      ))
      (lib.mkIf (allotments != [ ]) {
        transmission = {
          requires = map (allotment: "${mountUnit allotment}.service") allotments ++ [
            "transmission-setup.service"
          ];
          after = map (allotment: "${mountUnit allotment}.service") allotments;
          # Accommodating for NixOS's transmission, which binds the download-dir as it is: each allotment is bound at its
          # own path from its mount, so that what Transmission says of where a torrent is holds outside it too.
          serviceConfig.BindPaths = lib.mkForce (
            [
              "${home}/.config/transmission-daemon"
              "/run"
            ]
            ++ map (allotment: "${staged allotment}:${allotment.path}") allotments
          );
        };
      })
    ];

    services.transmission = lib.mkIf (allotments != [ ]) {
      enable = true;
      package = pkgs.transmission_4;
      user = name;
      group = name;
      inherit home;
      openPeerPorts = true;
      settings = {
        download-dir = if cfg.default != null then cfg.default else (lib.head allotments).path;
        # Policy: what's still downloading is where it'll be, by the name it'll have with .part after it, so that the
        # allotment's size bounds it.
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

    systemd.tmpfiles.rules = [
      "d '${home}' 0700 ${toString uid} ${toString gid} - -"
    ];

    # Policy: the service's ssh-key runs control alone, with nothing forwarded; it's no one's way to a shell.
    users.users.${name} = {
      shell = pkgs.bash;
      openssh.authorizedKeys = {
        keyFiles = lib.mkForce [ ];
        keys = lib.optional (builtins.pathExists service.publicKeys.ssh-key) ''restrict,command="${lib.getExe control}" ${lib.trim (builtins.readFile service.publicKeys.ssh-key)}'';
      };
    };
  };
}
