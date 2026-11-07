{
  config,
  context,
  lib,
  name,
  ...
}:
let
  inherit (context) org;

  parts = builtins.match "([a-z0-9-]+)@([a-z0-9-]+)" name;

  over =
    replica: if config.vpn != null then config.vpn else org.host.${replica}.shares.${config.host};

  # Policy: a client reaches the allotment from each host it's on: an app from each it runs on, a host from itself.
  clientHosts =
    handle:
    let
      client = org.entities.${handle};
    in
    if client.class == "app" then
      client.run-on-hosts
    else if client.class == "host" then
      [ client.name ]
    else
      throw "allotment.\"${name}\".sftp: ${handle} is no app or host, which would reach it from the hosts it's on.";

  login =
    handle: on:
    let
      vpn = over on;
      fail = message: throw "allotment.\"${name}\".sftp: ${handle} on ${on}: ${message}";
    in
    if on == config.host then
      fail "${on} has the allotment, which a client reaches over a vpn: grant it from another host."
    else if vpn == null then
      fail "${on} shares no vpn with ${config.host}: put both on one."
    else if
      !(lib.all (host: lib.elem vpn org.host.${host}.vpns) [
        on
        config.host
      ])
    then
      fail "${on} would reach ${config.host} over ${vpn}, which both aren't on: put both on it, or set the allotment's vpn to one they are."
    else if !(lib.elem config.host org.vpn.${vpn}.reaches.${on}) then
      fail "${on} would reach ${config.host} over ${vpn}, a mesh on which neither has an endpoint to be dialed at: give one of them an endpoint, or set the allotment's vpn to another."
    else
      {
        inherit (org.host.${config.host}.network.${vpn}) address address4;
        from = [
          "${org.host.${on}.network.${vpn}.address}/128"
          "${org.host.${on}.network.${vpn}.address4}/32"
        ];
        login = org.entities.${config.entity}.name;
        chroot = dirOf config.path;
        root = "/${baseNameOf config.path}";
        key = org.entities.${handle}.publicKeys.sftp-key;
      };
in
{
  options = {
    entity = lib.mkOption {
      description = "the handle of the principal the allotment is for, as its name has it before the @";
      type = lib.types.str;
      readOnly = true;
      default =
        let
          handle = builtins.elemAt parts 0;
        in
        lib.throwIf (parts == null)
          "allotment.\"${name}\": an allotment's name is <handle>@<host>, as user-alice@web."
          (
            lib.throwIfNot ((org.entities.${handle}.principal or null) != null)
              "allotment.\"${name}\": ${handle} is no entity with a principal, whose uid would own the allotment."
              handle
          );
      defaultText = lib.literalMD "the `<handle>` of its name";
    };
    host = lib.mkOption {
      description = "the host the allotment is on, as its name has it after the @";
      type = lib.types.str;
      readOnly = true;
      default =
        let
          host = builtins.elemAt parts 1;
        in
        lib.throwIf (parts == null)
          "allotment.\"${name}\": an allotment's name is <handle>@<host>, as user-alice@web."
          (
            lib.throwIfNot (org.host.${host}.nixos or false
            ) "allotment.\"${name}\": ${host} is no host with NixOS." host
          );
      defaultText = lib.literalMD "the `<host>` of its name";
    };
    size = lib.mkOption {
      description = "the most the allotment holds, as a ZFS size, of what's in it and not of its snapshots";
      type = lib.types.strMatching "[1-9][0-9]*[KMGTP]";
      example = "40G";
    };
    vpn = lib.mkOption {
      description = "the vpn the allotment syncs over, which its host and each replica are on, or null for the first vpn each replica shares with the host";
      type = lib.types.nullOr context.types.vpn.ref;
      default = null;
    };
    networks = lib.mkOption {
      description = "for each replica, the host's network it syncs with the host on";
      type = lib.types.lazyAttrsOf lib.types.raw;
      readOnly = true;
      default = lib.genAttrs config.replicas (replica: org.host.${config.host}.network.${over replica});
      defaultText = lib.literalMD "for each replica, the host's network on `vpn`, or on the first vpn the replica shares with it";
    };
    replicas = lib.mkOption {
      description = "the hosts that keep a replica of the allotment for its principal, which has to be on each, synced with it over `vpn`, on which they reach each other";
      type = lib.types.listOf context.types.host.ref;
      default = [ ];
      apply = map (
        replica:
        lib.throwIf (replica == config.host)
          "allotment.\"${name}\": ${replica} has the allotment, and keeps no replica of it."
          (
            lib.throwIfNot (lib.any (entity: entity.handle == config.entity) org.host.${replica}.principals)
              "allotment.\"${name}\": ${config.entity} isn't on ${replica}, which would keep its replica: put it there, or drop ${replica} from replicas."
              (
                lib.throwIf (config.vpn == null && org.host.${replica}.reach.${config.host} == null)
                  "allotment.\"${name}\": ${replica} shares no vpn with ${config.host}, which it would sync with: put both on one."
                  (
                    lib.throwIfNot
                      (lib.all (host: lib.elem (over replica) org.host.${host}.vpns) [
                        replica
                        config.host
                      ])
                      "allotment.\"${name}\": ${replica} would sync with ${config.host} over ${over replica}, which both aren't on: put both on it, or set the allotment's vpn to one they are."
                      (
                        lib.throwIfNot (lib.elem config.host org.vpn.${over replica}.reaches.${replica})
                          "allotment.\"${name}\": ${replica} would sync with ${config.host} over ${over replica}, a mesh on which neither has an endpoint to be dialed at: give one of them an endpoint, or set the allotment's vpn to another."
                          replica
                      )
                  )
              )
          )
      );
    };
    id = lib.mkOption {
      description = "the allotment's name, its @ a dot, as units and keys can have it";
      type = lib.types.str;
      readOnly = true;
      default = "${config.entity}.${config.host}";
      defaultText = lib.literalExpression ''"''${entity}.''${host}"'';
    };
    key = lib.mkOption {
      description = "the key each host that syncs the allotment, the one that has it and each replica, has of its own";
      type = lib.types.str;
      readOnly = true;
      default = "syncthing-${config.id}";
      defaultText = lib.literalExpression ''"syncthing-''${id}"'';
    };
    port = lib.mkOption {
      description = "the port the allotment's host listens on for its replicas";
      type = lib.types.port;
      readOnly = true;
      default = 22000 + org.entities.${config.entity}.principal.uid;
      defaultText = lib.literalMD "22000 plus the principal's `uid`";
    };
    sftp = lib.mkOption {
      description = "the apps and hosts, by handle, that reach the allotment over SFTP, as its principal, from each host they're on, over `vpn`, or without one over the first vpn that host shares with the allotment's";
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "app-cloud" ];
    };
    logins = lib.mkOption {
      description = "for each of `sftp`, by each host it's on, how it logs in: the allotment's host's addresses on the vpn, and its own as CIDRs, the principal's name, the directory sftp is jailed to and the allotment's root in it, and the public key of its `sftp-key`";
      type = lib.types.lazyAttrsOf (lib.types.lazyAttrsOf lib.types.raw);
      readOnly = true;
      default = lib.genAttrs config.sftp (handle: lib.genAttrs (clientHosts handle) (login handle));
      defaultText = lib.literalMD "for each of `sftp`, by each host it's on, how it reaches the allotment";
    };
    path = lib.mkOption {
      description = "where the allotment is on its host";
      type = lib.types.str;
      readOnly = true;
      default = "/srv/allotments/${config.entity}";
      defaultText = lib.literalExpression ''"/srv/allotments/''${entity}"'';
    };
  };
}
