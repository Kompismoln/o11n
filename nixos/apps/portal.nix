{
  app,
  lib,
  org,
  pkgs,
  ...
}:
let
  defaultLanguage = lib.head app.languages;

  strings = {
    sv = {
      services = "Tjänster";
      posts = "Inlägg";
      all_posts = "Alla inlägg";
      login = "Logga in";
      logout = "Logga ut";
      account = "Konto";
      signed_in_as = "Inloggad som";
      contact = "Kontakt";
      feed = "Flöde";
      not_found = "Sidan finns inte.";
      home = "Till startsidan";
      language = "Svenska";
    };
    en = {
      services = "Services";
      posts = "Posts";
      all_posts = "All posts";
      login = "Log in";
      logout = "Log out";
      account = "Account";
      signed_in_as = "Signed in as";
      contact = "Contact";
      feed = "Feed";
      not_found = "There is no such page.";
      home = "Back home";
      language = "English";
    };
  };

  issuer = lib.mapNullable (
    client: "${org.app.${client.keycloak}.url}/realms/${client.realm}"
  ) app.client;

  data = {
    inherit (org) name contact;
    logo =
      if app.logo == null then null else "/logo.${lib.last (lib.splitString "." (baseNameOf app.logo))}";
    inherit (app) accent logoHeight;
    services = map (name: {
      inherit name;
      inherit (org.app.${name}) url kind;
    }) app.services;
    auth = lib.mapNullable (client: {
      inherit issuer;
      inherit (client.representation) clientId;
      account = "${issuer}/account";
    }) app.client;
  };

  config = (pkgs.formats.toml { }).generate "config.toml" {
    base_url = app.url;
    title = org.name;
    default_language = defaultLanguage;
    compile_sass = false;
    build_search_index = false;
    generate_feeds = true;
    feed_filenames = [ "atom.xml" ];
    translations = strings.${defaultLanguage};
    extra = lib.filterAttrsRecursive (_: value: value != null) data;
    languages = lib.genAttrs (lib.tail app.languages) (language: {
      generate_feeds = true;
      feed_filenames = [ "atom.xml" ];
      translations = strings.${language};
    });
  };

  site =
    pkgs.runCommand "${app.name}-site"
      {
        nativeBuildInputs = [ pkgs.zola ];
        # Accommodating for Zola, which makes its HTTP client as it starts, and fails without CA certificates.
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      }
      ''
        mkdir src
        cd src
        cp -r ${./portal/templates} templates
        cp -r ${./portal/static} static
        cp -r ${app.content} content
        chmod -R u+w .
        ${lib.optionalString (app.logo != null) "cp ${app.logo} static${data.logo}"}
        cp ${config} config.toml
        zola build --output-dir $out
      '';
in
{
  assertions = [
    {
      assertion = app.keycloak == null || app.realm != "";
      message = "app.${app.name} logs in with ${app.keycloak}, in no realm: set realm under [app.${app.name}].";
    }
  ];

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;
    root = site;
    locations."/".tryFiles = "$uri $uri/ =404";
    extraConfig = ''
      error_page 404 /404.html;
    '';
  };
}
