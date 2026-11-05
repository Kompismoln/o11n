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
