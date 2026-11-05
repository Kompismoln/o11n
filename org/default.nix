{
  lib,
  config,
  context,
  ...
}:
{
  imports = [ ./export.nix ];

  options = {
    endpoint = lib.mkOption {
      description = "canonical name on internet";
      type = lib.types.str;
    };
    name = lib.mkOption {
      description = "name for organisation";
      type = lib.types.str;
    };
    storePath = lib.mkOption {
      description = "nix store path to org as a package";
      type = lib.types.path;
      default = context.path;
    };
    contact = lib.mkOption {
      description = "contact";
      default = "info@${config.endpoint}";
      defaultText = lib.literalExpression ''"info@''${endpoint}"'';
      type = lib.types.str;
    };
    timezone = lib.mkOption {
      description = "timezone";
      example = "Europe/Stockholm";
      type = lib.types.str;
    };
    locale = lib.mkOption {
      description = "default locale";
      type = lib.types.str;
      example = "en_US.UTF-8";
    };
    postgres = lib.mkOption {
      description = "postgresql major version of every server and client";
      type = lib.types.strMatching "[0-9]+";
      example = "17";
    };
    prefix = lib.mkOption {
      description = "ipv6 private prefix";
      type = context.types.globalPrefix6;
      example = "fda1:b2c3:d4e5";
    };
    prefixLength = lib.mkOption {
      description = "ipv6 private prefix length";
      type = lib.types.int;
      default = 64;
    };
    prefix4 = lib.mkOption {
      description = "ipv4 private prefix";
      type = context.types.globalPrefix4;
      example = "10.0";
    };
    prefixLength4 = lib.mkOption {
      description = "ipv4 private prefix length";
      type = lib.types.int;
      default = 24;
    };
    loPrefix = lib.mkOption {
      description = "ULA reserved for host-local service addresses on lo";
      type = context.types.subnetPrefix6;
      default = "${config.prefix}:ffff";
      defaultText = lib.literalExpression ''"''${prefix}:ffff"'';
    };
    loCidr = lib.mkOption {
      description = "CIDR route of loPrefix";
      type = context.types.subnetCidr6;
      default = "${config.loPrefix}::/${toString config.prefixLength}";
      defaultText = lib.literalExpression ''"''${loPrefix}::/''${toString prefixLength}"'';
    };
    build-hosts = lib.mkOption {
      description = "list of designated build hosts";
      default = [ ];
      type = lib.types.listOf context.types.host.ref;
    };
    namespaces = lib.mkOption {
      description = "namespaces for hosts in the organisation";
      default = [ config.endpoint ];
      defaultText = lib.literalExpression "[ endpoint ]";
      type = with lib.types; listOf str;
    };
    vpn = lib.mkOption {
      description = "attrset of vpn configurations";
      default = { };
      type = lib.types.attrsOf context.types.vpn.module;
    };
    mailserver = lib.mkOption {
      description = "main mailserver";
      default = null;
      type = lib.types.nullOr context.types.mailserver.module;
    };
    flake = lib.mkOption {
      description = "flake that the hosts' nix registry calls o11n";
      default = { };
      type = with lib.types; attrsOf str;
    };
    repository = lib.mkOption {
      description = "the organisation's own flake, where the remote builder fetches its revisions";
      default = { };
      type = with lib.types; attrsOf str;
    };
    role = lib.mkOption {
      description = "role declaration";
      default = { };
      type = lib.types.attrsOf context.types.role.module;
    };
    domain = lib.mkOption {
      description = "domains managed by organisation";
      default = { };
      type = lib.types.attrsOf context.types.domain.module;
    };
    certs = lib.mkOption {
      description = "the service that holds each namespace's tls-cert, by namespace";
      type = lib.types.attrsOf lib.types.raw;
      readOnly = true;
      default = lib.mapAttrs' (_: service: lib.nameValuePair service.namespace service) (
        lib.filterAttrs (_: service: service.namespace != null) config.service
      );
      defaultText = lib.literalMD "each service whose `namespace` isn't null, by it";
    };
    ops = lib.mkOption {
      description = "nothing: o11n status checks each entity by what it has, which `[ops]` named by hand";
      internal = true;
      default = { };
      type = lib.types.raw;
      apply =
        ops:
        lib.throwIf (ops != { })
          "[ops] is gone: drop it from org.toml. o11n status checks what verify and check did, for each entity that has the key, and o11n reencrypt does what rebuild did."
          ops;
    };
    root-identities = lib.mkOption {
      description = "list of root identities";
      default = [
        "root-0"
        "root-1"
      ];
      type = with lib.types; listOf str;
    };
    root = lib.mkOption {
      description = "attrs of root identities";
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
    entities = lib.mkOption {
      description = "every host, user, service, app and store, by its handle";
      type = lib.types.lazyAttrsOf lib.types.raw;
      readOnly = true;
      default = lib.listToAttrs (
        map (entity: lib.nameValuePair entity.handle entity) (
          lib.concatMap lib.attrValues [
            config.host
            config.user
            config.service
            config.app
            config.store
          ]
        )
      );
      defaultText = lib.literalMD "each of `host`, `user`, `service`, `app` and `store` by its `handle`";
    };
    host = lib.mkOption {
      description = "record of all hosts";
      type = lib.types.attrsOf context.types.host.module;
    };
    user = lib.mkOption {
      description = "record of all users";
      type = lib.types.attrsOf context.types.user.module;
    };
    service = lib.mkOption {
      description = "record of all services";
      type = lib.types.attrsOf context.types.service.module;
    };
    app = lib.mkOption {
      description = "record of all apps";
      type = lib.types.attrsOf context.types.app.module;
    };
    store = lib.mkOption {
      description = "record of all stores";
      type = lib.types.attrsOf context.types.store.module;
    };
    theme = lib.mkOption {
      description = "colors, wallpaper and fonts";
      default = null;
      type = lib.types.nullOr context.types.theme.module;
    };
  };
}
