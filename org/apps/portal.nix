{
  config,
  context,
  lib,
  ...
}:
{
  options = {
    content = lib.mkOption {
      description = "the directory in the org of the site's markdown, as Zola's content directory, in the default language and each other's `<name>.<language>.md`";
      type = context.types.orgFile;
      default = "site";
    };
    languages = lib.mkOption {
      description = "the site's languages, the default first";
      type = lib.types.nonEmptyListOf (
        lib.types.enum [
          "sv"
          "en"
        ]
      );
      default = [
        "sv"
        "en"
      ];
    };
    logo = lib.mkOption {
      description = "the logo the site shows, by the path of a file in the org, or null";
      type = lib.types.nullOr context.types.orgFile;
      default = null;
      example = "assets/logo.svg";
    };
    accent = lib.mkOption {
      description = "the site's accent color, as CSS takes it";
      type = lib.types.str;
      default = "#2563eb";
    };
    services = lib.mkOption {
      description = "the apps the site lists, in its order, each described in the content's front matter, under extra.services.<app>";
      type = lib.types.listOf context.types.app.ref;
      default = [ ];
    };
    keycloak = lib.mkOption {
      description = "the keycloak app the site's visitors log in with, or null for no login";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
    realm = lib.mkOption {
      description = "the keycloak realm of the site's client";
      type = lib.types.str;
      default = "";
    };
    client = lib.mkOption {
      description = "the site's client, which the keycloak app keeps in the realm, as Keycloak's admin API represents it, or null";
      internal = true;
      readOnly = true;
      type = lib.types.raw;
      # Dependency: nixos/apps/portal/static/auth.js logs in from any of the site's pages and returns to it, and
      # exchanges its code in the browser, from the site's origin.
      default = lib.mapNullable (keycloak: {
        inherit keycloak;
        inherit (config) realm;
        app = config.handle;
        representation = {
          clientId = config.name;
          enabled = true;
          protocol = "openid-connect";
          publicClient = true;
          standardFlowEnabled = true;
          implicitFlowEnabled = false;
          directAccessGrantsEnabled = false;
          serviceAccountsEnabled = false;
          fullScopeAllowed = false;
          redirectUris = [ "${config.url}/*" ];
          webOrigins = [ config.url ];
          attributes = {
            "pkce.code.challenge.method" = "S256";
            "post.logout.redirect.uris" = "${config.url}/*";
          };
        };
      }) config.keycloak;
      defaultText = lib.literalMD "a public client with PKCE, which returns to any of the site's pages, or null without a `keycloak`";
    };
  };
}
