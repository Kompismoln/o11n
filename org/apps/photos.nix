{
  config,
  context,
  lib,
  ...
}:
{
  imports = [ ./roots.nix ];

  options = {
    keycloak = lib.mkOption {
      description = "the keycloak app Immich's users log in with";
      type = context.types.app.ref;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of Immich's client";
      type = lib.types.str;
    };
    drops = lib.mkOption {
      description = "the drop folders of drives that the app takes into its users' libraries, each with its user and its directory in the app's home";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = lib.filter (drop: drop.photos == config.name) (
        lib.concatMap (app: if app.kind == "drive" then app.drops else [ ]) (lib.attrValues context.org.app)
      );
      defaultText = lib.literalMD "each drive's `drops` of this app";
    };
    client = lib.mkOption {
      description = "Immich's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Fact: Immich's web app redirects to the page it starts the login from, /auth/login, or /user-settings as it
      # links an account, and its mobile app to app.immich:///oauth-callback; the server proves the code with PKCE,
      # and takes a logout from the realm at /api/oauth/backchannel-logout.
      default = {
        inherit (config) keycloak realm;
        app = config.handle;
        secret = {
          name = "${config.name}/oidc-secret";
          inherit (config.secrets) sopsFile;
        };
        representation = {
          clientId = config.name;
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
            "${config.url}/auth/login"
            "${config.url}/user-settings"
            "app.immich:///oauth-callback"
          ];
          # Policy: logging out of the realm logs out of Immich, which Keycloak tells as it ends the user's session.
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "backchannel.logout.url" = "${config.url}/api/oauth/backchannel-logout";
            "backchannel.logout.session.required" = "true";
          };
        };
      };
      defaultText = lib.literalMD "a confidential client with the app's `oidc-secret`, with PKCE, which redirects to immich's login and its mobile app, and logs out of immich as the realm does";
    };
  };
}
