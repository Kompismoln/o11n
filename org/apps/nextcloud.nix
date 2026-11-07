{
  app,
  config,
  context,
  lib,
  ...
}:
let
  inherit (context) org;

  external = {
    options = {
      allotment = lib.mkOption {
        description = "the allotment, as <handle>@<host>, the mount reaches over SFTP, whose `sftp` has to have the app, or null for `sftp`";
        type = lib.types.nullOr (lib.types.enum (lib.attrNames (context.spec.allotment or { })));
        default = null;
      };
      sftp = lib.mkOption {
        description = "the SFTP server the mount reaches without an `allotment`, logging in with the app's `sftp-key`, or null";
        type = lib.types.nullOr (
          lib.types.submodule {
            options = {
              host = lib.mkOption {
                description = "the server, as nextcloud takes it: a name, or an IPv6 address in brackets";
                type = lib.types.str;
              };
              login = lib.mkOption {
                description = "the user it logs in as";
                type = lib.types.str;
              };
              root = lib.mkOption {
                description = "the directory on the server the mount is of";
                type = lib.types.str;
                default = "/";
              };
            };
          }
        );
        default = null;
      };
      sharing = lib.mkOption {
        description = "whether the user can share from the mount, nextcloud's enable_sharing";
        type = lib.types.bool;
        default = false;
      };
    };
  };

  # Policy: an allotment is reached from each host the app runs on as the allotment's logins have it.
  servers =
    user: folder: mount:
    let
      fail = message: throw "app.${app.name}.nextcloud.external.${user}.${folder}: ${message}";
      allotment = org.allotment.${mount.allotment};
    in
    if (mount.allotment == null) == (mount.sftp == null) then
      fail "it reaches an allotment or an sftp server: set one of them."
    else if mount.sftp != null then
      lib.genAttrs app.run-on-hosts (_: mount.sftp)
    else if !(allotment.logins ? ${app.handle}) then
      fail "${mount.allotment} lets ${app.handle} in by sftp only from its sftp: add it there."
    else
      lib.mapAttrs (_: login: {
        host = "[${login.address}]";
        inherit (login) login root;
      }) allotment.logins.${app.handle};
in
{
  options = {
    external = lib.mkOption {
      description = "nextcloud's external storages over SFTP, by the user each is for, the one it applies to, then by the folder it's at in their files";
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule external));
      default = { };
      example = lib.literalExpression ''{ alice.web.allotment = "user-alice@web"; }'';
    };
    mounts = lib.mkOption {
      description = "for each host the app runs on, its external storages: each at its folder, for its user, with the server it reaches there and whether it can be shared from";
      internal = true;
      readOnly = true;
      type = lib.types.lazyAttrsOf lib.types.raw;
      default = lib.genAttrs app.run-on-hosts (
        on:
        lib.concatLists (
          lib.mapAttrsToList (
            user:
            lib.mapAttrsToList (
              folder: mount: {
                mountPoint = "/${folder}";
                inherit user;
                inherit (mount) sharing;
                server = (servers user folder mount).${on};
              }
            )
          ) config.external
        )
      );
      defaultText = lib.literalMD "for each of the app's `run-on-hosts`, each of `external` with its server there";
    };
    collabora = lib.mkOption {
      description = "the collabora app whose endpoint nextcloud's office uses, or null";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
    keycloak = lib.mkOption {
      description = "the keycloak app nextcloud's users log in with, or null for nextcloud's own logins alone";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of nextcloud's client";
      type = lib.types.str;
      default = "";
    };
    client = lib.mkOption {
      description = "nextcloud's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it, or null";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Dependency: nixos/apps/nextcloud.nix logs in with user_oidc, whose code route is /apps/user_oidc/code, and
      # which proves its code with PKCE where the realm offers it.
      default = lib.mapNullable (keycloak: {
        inherit keycloak;
        inherit (config) realm;
        app = app.handle;
        secret = {
          name = "${app.name}/oidc-secret";
          inherit (app.secrets) sopsFile;
        };
        representation = {
          clientId = app.name;
          enabled = true;
          protocol = "openid-connect";
          publicClient = false;
          standardFlowEnabled = true;
          implicitFlowEnabled = false;
          directAccessGrantsEnabled = false;
          serviceAccountsEnabled = false;
          redirectUris = [
            "${app.url}/apps/user_oidc/code"
            "${app.url}/index.php/apps/user_oidc/code"
          ];
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "post.logout.redirect.uris" = "${app.url}/*";
          };
        };
      }) config.keycloak;
      defaultText = lib.literalMD "a confidential client with the app's `oidc-secret`, or null without a `keycloak`";
    };
  };
}
