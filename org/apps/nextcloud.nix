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
        description = "the SFTP server the mount reaches without an `allotment`, or null";
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
              key = lib.mkOption {
                description = "the entity, by its handle, whose sftp-key the mount logs in with, which has to grant the app's hosts, or null for the app's";
                type = lib.types.nullOr lib.types.str;
                default = null;
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

  home = {
    options = {
      host = lib.mkOption {
        description = "the SMB server";
        type = lib.types.str;
      };
      share = lib.mkOption {
        description = "the share on the server";
        type = lib.types.str;
      };
      login = lib.mkOption {
        description = "the user it logs in as";
        type = lib.types.str;
      };
      key = lib.mkOption {
        description = "the entity, by its handle, whose smb-password it logs in with, which has to grant the app's hosts";
        type = lib.types.str;
      };
    };
  };

  entityOf =
    option: handle:
    org.entities.${handle}
      or (throw "app.${app.name}.nextcloud.${option}: ${handle} is no entity of the org's.");

  servers =
    user: folder: mount:
    let
      fail = message: throw "app.${app.name}.nextcloud.external.${user}.${folder}: ${message}";
      allotment = org.allotment.${mount.allotment};
    in
    if (mount.allotment == null) == (mount.sftp == null) then
      fail "it reaches an allotment or an sftp server: set one of them."
    else if mount.sftp != null then
      lib.genAttrs app.run-on-hosts (_: {
        inherit (mount.sftp) host login root;
      })
    else if !(allotment.logins ? ${app.handle}) then
      fail "${mount.allotment} lets ${app.handle} in by sftp only from its sftp: add it there."
    else
      # Accommodating for nextcloud, which keeps the host keys it knows as host::key lines, split at the first ::.
      lib.mapAttrs (_: login: {
        host = login.address4;
        inherit (login) login root;
      }) allotment.logins.${app.handle};

  key =
    user: folder: mount:
    let
      handle = if mount.sftp.key or null == null then app.handle else mount.sftp.key;
      entity = entityOf "external.${user}.${folder}.sftp.key" handle;
    in
    {
      inherit handle;
      secret = {
        name = "${entity.name}/sftp-key";
        inherit (entity.secrets) sopsFile;
      };
      publicKey = entity.publicKeys.sftp-key;
    };
in
{
  options = {
    external = lib.mkOption {
      description = "nextcloud's external storages over SFTP, by the Nextcloud user each is for, the one it applies to, then by the folder it's at in their files";
      type = lib.types.attrsOf (lib.types.attrsOf (lib.types.submodule external));
      default = { };
      example = lib.literalExpression ''{ alice.web.allotment = "user-alice@web"; }'';
    };
    homes = lib.mkOption {
      description = "the Nextcloud users whose data, their files, versions and trash, is an SMB share, which each of the app's hosts mounts where Nextcloud keeps it, by user";
      type = lib.types.attrsOf (lib.types.submodule home);
      default = { };
      example = lib.literalExpression ''{ alice = { host = "box.example.com"; share = "alice"; login = "alice"; key = "store-box"; }; }'';
    };
    shares = lib.mkOption {
      description = "each of `homes`, with its user and the key it logs in with";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = lib.mapAttrsToList (
        user: home:
        let
          entity = entityOf "homes.${user}.key" home.key;
        in
        {
          inherit user;
          inherit (home) host share login;
          key = {
            handle = home.key;
            secret = {
              name = "${entity.name}/smb-password";
              inherit (entity.secrets) sopsFile;
            };
          };
        }
      ) config.homes;
      defaultText = lib.literalMD "each of `homes`, with its user and its `key`'s smb-password";
    };
    mounts = lib.mkOption {
      description = "for each host the app runs on, its external storages: each at its folder, for its user, with the server it reaches there, the key it logs in with and whether it can be shared from";
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
                key = key user folder mount;
              }
            )
          ) config.external
        )
      );
      defaultText = lib.literalMD "for each of the app's `run-on-hosts`, each of `external` with its server there and its `sftp.key`'s sftp-key, or the app's";
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
          # Policy: its tokens carry no roles, as it reads none, rather than every role, as Keycloak's full scope,
          # which it deprecates, gives.
          fullScopeAllowed = false;
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
