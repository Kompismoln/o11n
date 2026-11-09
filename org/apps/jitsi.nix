{
  app,
  config,
  context,
  lib,
  ...
}:
let
  url = "https://${app.endpoint}";
in
{
  options = {
    keycloak = lib.mkOption {
      description = "the keycloak app jitsi authenticates with";
      type = context.types.app.ref;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of jitsi's client";
      type = lib.types.str;
    };
    client = lib.mkOption {
      description = "jitsi's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Fact: as the jitsi handbook's https://jitsi.github.io/handbook/docs/devops-guide/authentication has it: a
      # public client, which proves its code with PKCE.
      default = {
        inherit (config) keycloak realm;
        app = app.handle;
        representation = {
          clientId = app.name;
          enabled = true;
          protocol = "openid-connect";
          publicClient = true;
          standardFlowEnabled = true;
          implicitFlowEnabled = false;
          directAccessGrantsEnabled = false;
          serviceAccountsEnabled = false;
          # Policy: its tokens carry no roles, as it reads none, rather than every role, as Keycloak's full scope,
          # which it deprecates, gives.
          fullScopeAllowed = false;
          redirectUris = [ "${url}/static/sso.html" ];
          webOrigins = [ url ];
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "post.logout.redirect.uris" = "${url}/static/logout.html";
          };
        };
      };
      defaultText = lib.literalMD "a public client with PKCE, which redirects to jitsi's `/static/sso.html`";
    };
  };
}
