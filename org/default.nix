# org/default.nix
{
  lib,
  config,
  context,
  ...
}:
{
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
    };
    loCidr = lib.mkOption {
      description = "CIDR route of loPrefix";
      type = context.types.subnetCidr6;
      default = "${config.loPrefix}::/${toString config.prefixLength}";
    };
    build-hosts = lib.mkOption {
      description = "list of designated build hosts";
      default = [ ];
      type = lib.types.listOf context.types.host.ref;
    };
    namespaces = lib.mkOption {
      description = "namespaces for hosts in the organisation";
      default = [ config.endpoint ];
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
    public-artifacts = lib.mkOption {
      description = "path templates for public artifacts";
      type = with lib.types; attrsOf str;
    };
    secrets = lib.mkOption {
      description = "path templates for secrets";
      type = with lib.types; attrsOf str;
    };
    class = lib.mkOption {
      description = "metadata for classes";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            keys = lib.mkOption {
              type = with lib.types; listOf str;
            };
          };
        }
      );
    };
    ops = lib.mkOption {
      description = "operations per entity groups";
      type = with lib.types; attrsOf (attrsOf (listOf str));
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
