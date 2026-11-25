{
  lib,
  config,
  context,
  ...
}:
let
  relative =
    path:
    builtins.unsafeDiscardStringContext (lib.removePrefix "${toString context.path}/" (toString path));

  stateful = entity: entity.principal != null && entity.principal.state != null;

  # Dependency: nixos/apps/<kind>.nix keeps an app of these kinds' database, named its `database`, in its hosts'
  # postgresql (nixos/postgresql.nix).
  postgresqlKinds = [
    "django"
    "drive"
    "keycloak"
    "mobilizon"
    "photos"
  ];

  # Policy: a grant that names an entity names one of the org's, or o11n can't tell its recipients.
  grants =
    entity:
    map (
      grant:
      lib.throwIf
        (
          grant != "*"
          && !lib.hasInfix ":" grant
          && !lib.hasSuffix "-*" grant
          && !(config.entities ? ${grant})
          && !lib.elem grant config.root-identities
        )
        "${entity.handle} grants ${grant}, which is no entity of the org's: drop it from [${entity.class}.${entity.name}] grants."
        grant
    ) entity.grants;

  exported =
    entity:
    {
      grants = grants entity;
      inherit (entity)
        class
        name
        id
        actors
        settings
        keys
        ;
      publicKeys = lib.mapAttrs (_: relative) entity.publicKeys;
      secrets = {
        sopsFile = relative entity.secrets.sopsFile;
        identityFile = relative entity.secrets.identityFile;
        inherit (entity.secrets) decryptionKey;
      };
    }
    // lib.optionalAttrs (stateful entity) {
      state = {
        inherit (entity.principal) home;
        archives = lib.mapAttrs (_: archive: {
          inherit (archive) schedule;
          forget = archive.prune.flags;
        }) entity.principal.state.archives;
        hosts = map (host: host.name) (
          lib.filter (host: lib.any (principal: principal.handle == entity.handle) host.principals) (
            lib.attrValues config.host
          )
        );
      };
    }
    //
      lib.optionalAttrs
        (entity.principal != null && (entity.principal.mail.inbox || entity.principal.mail.send))
        {
          mail = {
            inherit (entity.principal.mail)
              address
              inbox
              send
              sendAs
              server
              ;
          };
        }
    // lib.optionalAttrs (entity.class == "service") {
      inherit (entity) namespace;
    }
    // lib.optionalAttrs (entity.class == "app") {
      inherit (entity) url;
    }
    // lib.optionalAttrs (entity.class == "app" && lib.elem entity.kind postgresqlKinds) {
      database = {
        name = entity.database;
        hosts = entity.run-on-hosts;
      };
    }
    // lib.optionalAttrs (entity.class == "app" && entity.kind == "drive") {
      drive = {
        roots = lib.attrNames entity.roots;
        external = lib.concatLists (
          lib.mapAttrsToList (
            user: storages: map (name: "${user}/${name}") (lib.attrNames storages)
          ) entity.storages
        );
        changes = lib.unique (
          lib.concatMap (
            mounts:
            map (mount: "${mount.user}${mount.mountPoint}") (
              lib.filter (mount: mount.server.changes != null) mounts
            )
          ) (lib.attrValues entity.mounts)
        );
        hosts = entity.run-on-hosts;
      };
    }
    // lib.optionalAttrs (entity.class == "app" && entity.kind == "mail") {
      mailserver = {
        inherit (entity) endpoint dkimSelector;
        domains = lib.listToAttrs (
          map (
            domain:
            lib.nameValuePair domain.name {
              inherit (domain) mailbox;
              sent = lib.elem domain.name sentDomains;
            }
          ) entity.domains
        );
        # Dependency: nixos/apps/mail.nix reads the reports in the app's own inbox.
        reports =
          if entity.principal != null && entity.principal.mail.inbox then
            entity.principal.mail.address
          else
            null;
      };
    }
    // lib.optionalAttrs (entity.class == "app" && entity.kind == "keycloak") {
      keycloak = {
        realms = lib.attrNames entity.realms;
        # Dependency: crates/o11n/src/keycloak.rs sends one it invites to a portal of the realm once they've set their
        # password.
        portals =
          map
            (portal: {
              inherit (portal) realm url;
              inherit (portal.client.representation) clientId;
            })
            (lib.filter (app: app.kind == "portal" && app.keycloak == entity.name) (lib.attrValues config.app));
      };
    }
    // lib.optionalAttrs (entity.class == "host") {
      inherit (entity)
        endpoint
        roles
        vpns
        system
        luksKeyFile
        nixos
        fqdns
        buildHosts
        ;
      services = map (service: service.name) entity.services;
      served = lib.listToAttrs (
        map (
          service:
          lib.nameValuePair service.name
            context.org.vpn.${service.vpn}.members."${service.name}-${entity.name}".fqdn
        ) (lib.filter (service: service.vpn != null && service.principal != null) entity.services)
      );
      allotments = map (allotment: {
        inherit (allotment) id path replicas;
      }) (lib.filter (allotment: allotment.replicas != [ ]) entity.allotments);
      # Dependency: crates/o11n/src/wireguard.rs writes a host's interface on a vpn from it, as wg-quick reads one.
      wireguard = lib.listToAttrs (
        map (
          vpn:
          let
            network = entity.network.${vpn.name};
            tunnel = vpn.tunnels.${entity.name};
          in
          lib.nameValuePair vpn.name {
            inherit (vpn) key;
            inherit (network) dns;
            inherit (tunnel) listenPort;
            addresses = [
              "${network.address}/${toString network.prefixLength}"
              "${network.address4}/${toString network.prefixLength4}"
            ];
            peers = map (peer: peer // { publicKey = relative peer.publicKey; }) tunnel.peers;
          }
        ) (lib.filter (vpn: vpn.enable) (map (name: context.org.vpn.${name}) entity.vpns))
      );
    }
    // lib.optionalAttrs (entity.class == "host" && entity.openwrt != null) {
      openwrt = {
        inherit (entity.openwrt) files;
      };
    }
    // lib.optionalAttrs (entity.class == "host" && entity.router != null) {
      router = {
        inherit (entity.router) address4;
        lan = lib.mapAttrs (_: network: { inherit (network) address4 suffix mac; }) entity.router.lan;
        records = if entity.router.glesys == null then [ ] else entity.router.glesys.records;
        records6 = if entity.router.glesys == null then { } else entity.router.glesys.records6;
      };
    };

  root = name: {
    class = "root";
    inherit name;
    grants = [ ];
    actors = [ ];
    settings = { };
    inherit (context.classes.root) keys;
    publicKeys.age-key = "public-keys/root-${name}-age-key.pub";
    secrets.identityFile = "keys/root-${name}";
  };

  # Policy: a domain is sent from when a principal that sends has its address on it; one it has a sendAs on is its own.
  sentDomains = lib.concatMap (
    entity:
    lib.optional (entity.principal != null && entity.principal.mail.send) (
      lib.last (lib.splitString "@" entity.principal.mail.address)
    )
  ) (lib.attrValues config.entities);
in
{
  options.export = lib.mkOption {
    description = "the org as plain data, for the tools that act on it";
    internal = true;
    readOnly = true;
    type = lib.types.raw;
    default = builtins.seq config.ops (
      builtins.seq config.mailserver {
        inherit (config)
          name
          endpoint
          namespaces
          build-hosts
          root-identities
          ;
        inherit (context) classes;
        entities =
          lib.genAttrs' (lib.unique (
            map (lib.removePrefix "root-") config.root-identities ++ lib.attrNames config.root
          )) (name: lib.nameValuePair "root-${name}" (root name))
          // lib.mapAttrs (_: exported) config.entities;
      }
    );
  };
}
