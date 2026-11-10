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
    "keycloak"
    "mobilizon"
    "nextcloud"
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
    // lib.optionalAttrs (entity.class == "app" && entity.nextcloud != null) {
      nextcloud = {
        homes = lib.attrNames entity.nextcloud.homes;
        external = lib.concatLists (
          lib.mapAttrsToList (
            user: folders: map (folder: "${user}/${folder}") (lib.attrNames folders)
          ) entity.nextcloud.external
        );
        changes = lib.unique (
          lib.concatMap (
            mounts:
            map (mount: "${mount.user}${mount.mountPoint}") (
              lib.filter (mount: mount.server.changes != null) mounts
            )
          ) (lib.attrValues entity.nextcloud.mounts)
        );
        hosts = entity.run-on-hosts;
      };
    }
    // lib.optionalAttrs (entity.class == "app" && entity.keycloak != null) {
      keycloak.realms = lib.attrNames entity.keycloak.realms;
    }
    // lib.optionalAttrs (entity.class == "host") {
      inherit (entity)
        endpoint
        roles
        vpns
        system
        luksKeyFile
        nixos
        ;
      services = map (service: service.name) entity.services;
      allotments = map (allotment: {
        inherit (allotment) id path replicas;
      }) (lib.filter (allotment: allotment.replicas != [ ]) entity.allotments);
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
    default = builtins.seq config.ops {
      inherit (config)
        name
        endpoint
        namespaces
        build-hosts
        root-identities
        ;
      mailserver = lib.mapNullable (mailserver: {
        inherit (mailserver) endpoint dkimSelector;
        domains = lib.mapAttrs (name: domain: {
          inherit (domain) mailbox;
          sent = lib.elem name sentDomains;
        }) config.domain;
      }) config.mailserver;
      inherit (context) classes;
      entities =
        lib.genAttrs' (lib.unique (
          map (lib.removePrefix "root-") config.root-identities ++ lib.attrNames config.root
        )) (name: lib.nameValuePair "root-${name}" (root name))
        // lib.mapAttrs (_: exported) config.entities;
    };
  };
}
