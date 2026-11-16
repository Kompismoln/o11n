{
  app,
  config,
  context,
  lib,
  ...
}:
let
  inherit (context) org;

  box = {
    options = {
      host = lib.mkOption {
        description = "the SMB server";
        type = lib.types.str;
      };
      share = lib.mkOption {
        description = "the share on the server, and the path in it, as mount.cifs takes them";
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
in
{
  options = {
    keycloak = lib.mkOption {
      description = "the keycloak app immich's users log in with";
      type = context.types.app.ref;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of immich's client";
      type = lib.types.str;
    };
    storages = lib.mkOption {
      description = "the storage of each Immich user's library, by user, the Keycloak username they log in with: a box, the SMB share that is their library; a Keycloak user without one logs in to a library they can upload nothing to";
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.box = lib.mkOption {
            description = "the SMB share that is the user's library";
            type = lib.types.submodule box;
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          alice.box = { host = "box.example.com"; share = "backup/immich/alice"; login = "u123"; key = "store-box"; };
        }
      '';
    };
    shares = lib.mkOption {
      description = "each box, with its user and the key it logs in with";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = lib.mapAttrsToList (
        user: storage:
        let
          entity =
            org.entities.${storage.box.key}
              or (throw "app.${app.name}.immich.storages.${user}.box.key: ${storage.box.key} is no entity of the org's.");
        in
        {
          inherit user;
          inherit (storage.box) host share login;
          key = {
            handle = storage.box.key;
            secret = {
              name = "${entity.name}/smb-password";
              inherit (entity.secrets) sopsFile;
            };
          };
        }
      ) config.storages;
      defaultText = lib.literalMD "each of `storages`, with its user and its `box.key`'s smb-password";
    };
    client = lib.mkOption {
      description = "immich's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Fact: immich's web app redirects to the page it starts the login from, /auth/login, or /user-settings as it
      # links an account, and its mobile app to app.immich:///oauth-callback; the server proves the code with PKCE,
      # and takes a logout from the realm at /api/oauth/backchannel-logout.
      default = {
        inherit (config) keycloak realm;
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
            "${app.url}/auth/login"
            "${app.url}/user-settings"
            "app.immich:///oauth-callback"
          ];
          # Policy: logging out of the realm logs out of immich, which Keycloak tells as it ends the user's session.
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "backchannel.logout.url" = "${app.url}/api/oauth/backchannel-logout";
            "backchannel.logout.session.required" = "true";
          };
        };
      };
      defaultText = lib.literalMD "a confidential client with the app's `oidc-secret`, with PKCE, which redirects to immich's login and its mobile app, and logs out of immich as the realm does";
    };
  };
}
