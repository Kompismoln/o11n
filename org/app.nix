{
  config,
  context,
  lib,
  ...
}:
let
  kinds = {
    collabora = ./apps/collabora.nix;
    django = ./apps/django.nix;
    jitsi = ./apps/jitsi.nix;
    keycloak = ./apps/keycloak.nix;
    mobilizon = ./apps/mobilizon.nix;
    nextcloud = ./apps/nextcloud.nix;
    nextcloud-rolf = ./apps/nextcloud-rolf.nix;
    wordpress = { };
  };
  set = lib.filter (kind: config.${kind} != null) (lib.attrNames kinds);
in
{
  imports = [
    ./entity.nix
  ];

  config = {
    class = "app";
    # Dependency: nixos/apps/<kind>.nix reads these keys.
    keys =
      lib.optionalAttrs (lib.elem config.kind [
        "django"
        "nextcloud"
      ]) { secret-key = "passphrase"; }
      // lib.optionalAttrs (config.kind == "keycloak") { admin-client-secret = "passphrase"; }
      // lib.optionalAttrs (config.nextcloud != null && config.nextcloud.keycloak != null) {
        oidc-secret = "passphrase";
      };
  };

  options =
    lib.mapAttrs (
      kind: module:
      lib.mkOption {
        description = "the app's settings as a ${kind}, which make it one";
        type = lib.types.nullOr (
          lib.types.submoduleWith {
            modules = [ module ];
            specialArgs = {
              inherit context;
              app = config;
            };
          }
        );
        default = null;
      }
    ) kinds
    // {
      endpoint = lib.mkOption {
        description = "canonical name on internet";
        type = lib.types.str;
      };
      url = lib.mkOption {
        description = "public url including scheme";
        default = "${config.scheme}://${config.endpoint}";
        defaultText = lib.literalExpression ''"''${scheme}://''${endpoint}"'';
        type = lib.types.str;
      };
      location = lib.mkOption {
        description = "canonical path";
        default = "/";
        type = lib.types.str;
      };
      configurationFile = lib.mkOption {
        description = "the org's own configuration of the app, beside its kind's, or null";
        type = lib.types.nullOr (
          lib.types.coercedTo lib.types.str (s: context.path + "/${s}") lib.types.path
        );
        default =
          let
            relative = "apps/${config.name}.nix";
          in
          if builtins.pathExists (context.path + "/${relative}") then relative else null;
        defaultText = lib.literalMD "the org's `apps/<name>.nix`, if it exists";
      };
      kind = lib.mkOption {
        description = "the kind of the app, whose configuration in o11n's nixos/apps/ it gets: the one of its kinds' tables that is set, or null";
        type = lib.types.nullOr (lib.types.enum (lib.attrNames kinds));
        readOnly = true;
        default =
          lib.throwIf (lib.length set > 1)
            "app.${config.name} has more than one kind: ${lib.concatStringsSep ", " set}"
            (lib.findFirst (_: true) null set);
        defaultText = lib.literalMD "the one of its kinds' tables that is set, or null";
      };
      altpoints = lib.mkOption {
        description = "alternative access points that should be redirected to endpoint";
        default = [ ];
        type = with lib.types; listOf str;
      };
      run-on-hosts = lib.mkOption {
        description = "hosts that this app should run on";
        type = with lib.types; listOf str;
      };
      database = lib.mkOption {
        description = "app's database";
        default = config.name;
        type = lib.types.str;
      };
      ssl = lib.mkOption {
        description = "let's encrypt and force https";
        default = true;
        type = lib.types.bool;
      };
      scheme = lib.mkOption {
        description = "http or https";
        default = if config.ssl then "https" else "http";
        type = lib.types.str;
      };
    };
}
