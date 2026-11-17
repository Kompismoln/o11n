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
      invite_title = "Har du ett IT-behov?";
      invite_text = "Skriv kort vad det handlar om, så hör vi av oss.";
      invite_email = "E-postadress";
      invite_note = "Meddelande (frivilligt)";
      invite_send = "Be om en inbjudan";
      invite_sent = "Tack! Vi hör av oss.";
      invite_invalid = "Adressen ser inte ut att stämma. Försök igen.";
      invite_failed = "Det gick inte att skicka. Skriv till oss direkt:";
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
      invite_title = "Want an account?";
      invite_text = "Accounts are by invitation. Leave your address, and a few words about you if you like, and we'll be in touch.";
      invite_email = "Email address";
      invite_note = "Message (optional)";
      invite_send = "Request an invite";
      invite_sent = "Thanks! We'll be in touch.";
      invite_invalid = "That address doesn't look right. Try again.";
      invite_failed = "It couldn't be sent. Write to us directly:";
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
    invites = app.invites != null;
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

  # Fact: a port on the app's own address, which only its host reaches.
  invitesPort = 8080;

  invites = pkgs.writers.writePython3 "${app.name}-invites" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./portal/invites.py
  );

  # Dependency: crates/o11n/src/keycloak.rs invites one to a keycloak's realm.
  invite = lib.optionalString (
    app.keycloak != null
  ) "o11n invite --keycloak ${app.keycloak} --realm ${app.realm}";
in
{
  assertions = [
    {
      assertion = app.keycloak == null || app.realm != "";
      message = "app.${app.name} logs in with ${app.keycloak}, in no realm: set realm under [app.${app.name}].";
    }
    {
      assertion = app.invites == null || app.principal.mail.send;
      message = "app.${app.name} mails requests for an invite to ${app.invites}, as itself, which sends no mail: set principal.mail.send under [app.${app.name}].";
    }
  ];

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;
    root = site;
    locations."/".tryFiles = "$uri $uri/ =404";
    # Policy: a visitor asks for an invite a few times, and then once a minute, with a form's worth of text.
    locations."= /invite" = lib.mkIf (app.invites != null) {
      proxyPass = "http://[${app.principal.bindAddress}]:${toString invitesPort}";
      extraConfig = ''
        limit_except POST { deny all; }
        limit_req zone=${app.name}-invites burst=3 nodelay;
        limit_req_status 429;
        client_max_body_size 16k;
      '';
    };
    extraConfig = ''
      error_page 404 /404.html;
    '';
  };

  services.nginx.appendHttpConfig = lib.mkIf (app.invites != null) ''
    limit_req_zone $binary_remote_addr zone=${app.name}-invites:1m rate=1r/m;
  '';

  systemd.services."${app.name}-invites" = lib.mkIf (app.invites != null) {
    description = "${app.name}: mails visitors' requests for an invite to ${app.invites}";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.msmtp ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        invites
        app.handle
        app.invites
        invite
        app.principal.bindAddress
        (toString invitesPort)
      ];
      User = app.name;
      Group = app.name;
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
        "AF_UNIX"
      ];
    };
  };
}
