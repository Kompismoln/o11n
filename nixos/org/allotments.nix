{
  config,
  host,
  lib,
  org,
  ...
}:
let
  inherit (config.o11n.preserve) storage;

  parents = lib.concatLists (
    lib.mapAttrsToList (
      pool: zpool:
      lib.mapAttrsToList (dataset: _: "${pool}/${dataset}") (
        lib.filterAttrs (
          _: dataset: dataset.type == "zfs_fs" && dataset.mountpoint == storage
        ) zpool.datasets
      )
    ) (config.disko.devices.zpool or { })
  );

  served = lib.filter (allotment: allotment.replicas != [ ]) host.allotments;

  name = allotment: "${allotment.entity}@${allotment.host}";
  deviceFile = on: allotment: org.host.${on}.publicKeys.${allotment.key};
  deviceId =
    on: allotment:
    lib.optionalString (builtins.pathExists (deviceFile on allotment)) (
      lib.trim (builtins.readFile (deviceFile on allotment))
    );
  dial = network: port: "tcp://[${network.address}]:${toString port}";

  # Accommodating for NixOS 26.11, whose activation no longer restarts what restartUnits names: a new key is a new device
  # ID, in either side's configuration, whose unit a switch restarts.
  secret = allotment: owner: { ${allotment.key} = owner; };

  # Policy: the host that has the allotment listens on the vpn its replicas reach it on, and dials none of them.
  serve =
    allotment:
    let
      entity = org.entities.${allotment.entity};
      inherit (entity) principal;
      reached = lib.attrValues allotment.networks;
      interfaces = lib.unique (map (network: network.interface) reached);
      state = config.o11n.preserve.onStorage "/var/lib/allotment-sync/${allotment.id}";
    in
    {
      o11n.allotment-sync.${allotment.id} = {
        folder = allotment.path;
        inherit state;
        user = entity.name;
        group = entity.name;
        secret = config.sops.secrets.${allotment.key}.path;
        listen = lib.unique (map (network: dial network allotment.port) reached);
        self = {
          id = deviceId host.name allotment;
          inherit (host) name;
        };
        peers = map (replica: {
          id = deviceId replica allotment;
          name = replica;
        }) allotment.replicas;
        changes = lib.mkIf (allotment.logins != { }) (changesOf allotment.id);
        after = [ "allotment@${allotment.entity}.service" ];
        # Accommodating for Syncthing, which listens on an address that isn't there yet only once it retries, a minute
        # later.
        wants = map (interface: "systemd-networkd-wait-online@${interface}.service") interfaces;
      };
      sops.secrets = secret allotment {
        owner = entity.name;
        group = entity.name;
      };
      systemd.tmpfiles.rules = [
        "d '${state}' 0700 ${toString principal.uid} ${toString principal.gid} - -"
      ];
      networking.firewall.interfaces =
        lib.genAttrs (lib.unique (map (network: network.interface) reached))
          (_: {
            allowedTCPPorts = [ allotment.port ];
          });
    };

  # Policy: a replica is in the principal's home, under .o11n/, which nothing else there names, and it dials the
  # host that has the allotment; where Cinnamon runs, it's on the principal's Desktop as the org, by its logo.
  replicate =
    allotment:
    let
      entity = org.entities.${allotment.entity};
      inherit (entity.principal) home;
    in
    {
      o11n.allotment-sync.${allotment.id} = {
        desktop = lib.mkIf config.services.xserver.desktopManager.cinnamon.enable {
          name =
            if lib.length (lib.filter (other: other.entity == allotment.entity) host.replicas) > 1 then
              "${org.name} (${allotment.host})"
            else
              org.name;
          icon = org.theme.logo or null;
        };
        folder = "${home}/.o11n/allotments/${allotment.host}";
        state = "${home}/.o11n/syncthing/${allotment.host}";
        user = entity.name;
        group = entity.name;
        secret = config.sops.secrets.${allotment.key}.path;
        self = {
          id = deviceId host.name allotment;
          inherit (host) name;
        };
        peers = [
          {
            id = deviceId allotment.host allotment;
            name = allotment.host;
            addresses = [ (dial allotment.networks.${host.name} allotment.port) ];
          }
        ];
      };
      sops.secrets = secret allotment {
        owner = entity.name;
        group = entity.name;
      };
    };

  # Policy: a client of an allotment's sftp logs in as its principal, with its sftp-key, from its host's addresses on the
  # vpn it reaches it on alone, and gets sftp jailed to the allotments' directory, in its allotment.
  logins = lib.concatMap (
    allotment:
    lib.concatLists (
      lib.mapAttrsToList (
        client: byHost: lib.mapAttrsToList (_: login: login // { inherit allotment client; }) byHost
      ) allotment.logins
    )
  ) host.allotments;

  sftp = login: {
    users.users.${login.login}.openssh.authorizedKeys.keys =
      lib.optional (builtins.pathExists login.key) ''from="${lib.concatStringsSep "," login.from}",restrict ${lib.trim (builtins.readFile login.key)}'';
    services.openssh.extraConfig = ''
      Match User ${login.login} Address ${lib.concatStringsSep "," login.from}
        ChrootDirectory ${login.chroot}
        ForceCommand internal-sftp -d ${login.root}
        AllowTcpForwarding no
        X11Forwarding no
        AllowAgentForwarding no
        PermitTunnel no
    '';
  };

  changesOf = id: "/run/allotment-changes/${id}";

  # Policy: a client of a synced allotment's sftp follows what its replicas change with the same key, from the same
  # addresses.
  followers = lib.groupBy (login: login.client) (lib.filter (login: login.changes != null) logins);

  changes = lib.mapAttrs (
    _: followed:
    let
      first = lib.head followed;
    in
    {
      key = lib.trim (builtins.readFile first.key);
      from = lib.unique (lib.concatMap (login: login.from) followed);
      ids = lib.unique (map (login: login.changes.id) followed);
    }
  ) (lib.filterAttrs (_: followed: builtins.pathExists (lib.head followed).key) followers);

  synced =
    lib.concatMap (
      allotment:
      map (on: {
        inherit on allotment;
      }) ([ host.name ] ++ allotment.replicas)
    ) served
    ++ lib.concatMap (
      allotment:
      map
        (on: {
          inherit on allotment;
        })
        [
          host.name
          allotment.host
        ]
    ) host.replicas;
in
{
  imports = [
    ../allotments.nix
    ../allotment-changes.nix
    ../allotment-sync.nix
    ../preserve-paths.nix
  ];

  config = lib.mkMerge (
    [
      {
        assertions =
          map (allotment: {
            assertion = parents != [ ];
            message = "allotment.\"${name allotment}\": ${host.name} keeps allotments under the ZFS dataset its disk layouts mount at o11n.preserve.storage, ${storage}, and they have none: give ${host.name} a disk layout with one, or put the allotment on another host.";
          }) host.allotments
          ++ map (
            { on, allotment }:
            {
              assertion = builtins.pathExists (deviceFile on allotment);
              message = "allotment.\"${name allotment}\": host-${on} has no ${allotment.key}, whose device ID it syncs by: o11n secret generate host-${on} ${allotment.key}.";
            }
          ) synced
          ++ map (allotment: {
            assertion = org.entities.${allotment.entity}.principal.home != "/var/empty";
            message = "allotment.\"${name allotment}\": ${allotment.entity} has no home on ${host.name} to keep its replica in: give it one, or drop ${host.name} from replicas.";
          }) host.replicas
          ++ map (login: {
            assertion = builtins.pathExists login.key;
            message = "allotment.\"${name login.allotment}\".sftp: ${login.client} has no sftp-key, which it logs in to ${host.name} with: o11n secret generate ${login.client} sftp-key.";
          }) logins;

        # Policy: a principal with an allotment on a host it isn't on has an account there that owns it, and nothing
        # else: no home, no login and no password.
        users = lib.mkMerge (
          map
            (
              allotment:
              let
                entity = org.entities.${allotment.entity};
              in
              {
                users.${entity.name} = {
                  isSystemUser = true;
                  inherit (entity.principal) uid;
                  group = entity.name;
                };
                groups.${entity.name}.gid = entity.principal.gid;
              }
            )
            (
              lib.filter (
                allotment: !lib.any (entity: entity.handle == allotment.entity) host.principals
              ) host.allotments
            )
        );

        o11n.allotments = lib.mkIf (parents != [ ]) (
          lib.listToAttrs (
            map (
              allotment:
              let
                inherit (org.entities.${allotment.entity}) principal;
              in
              lib.nameValuePair allotment.entity {
                dataset = "${lib.head parents}/allotments/${allotment.entity}";
                inherit (allotment) size path;
                inherit (principal) uid gid;
                # Policy: the members of the principal's group read its allotment.
                mode = if principal.members == [ ] then "0700" else "0750";
              }
            ) host.allotments
          )
        );
      }
    ]
    ++ map serve served
    ++ map replicate host.replicas
    ++ map sftp logins
    ++ [ { o11n.allotment-changes = changes; } ]
    ++ [
      # Accommodating for nextcloud's SFTP, phpseclib 2, which verifies no host key but an RSA one, and has no MAC of
      # NixOS's, which are all encrypt-then-MAC.
      (lib.mkIf (logins != [ ]) {
        services.openssh.settings.Macs = lib.mkOptionDefault [ "hmac-sha2-256" ];
        services.openssh.hostKeys = lib.mkAfter [
          {
            path = "/keys/ssh_host_rsa_key";
            type = "rsa";
            bits = 4096;
          }
        ];
      })
    ]
  );
}
