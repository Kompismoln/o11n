{
  app,
  lib,
  pkgs,
  ...
}@args:
let
  inherit (import ./portal/site.nix args) site;

  # Fact: a port on the app's own address, which only its host reaches.
  formsPort = 8080;

  forms = pkgs.writers.writePython3 "${app.name}-forms" { flakeIgnore = [ "E501" ]; } (
    builtins.readFile ./portal/forms.py
  );

  hasForms = app.invites != null || app.inquiries != null;

  # Policy: a visitor sends a form a few times, and then once a minute, with a form's worth of text.
  form = {
    proxyPass = "http://[${app.principal.bindAddress}]:${toString formsPort}";
    extraConfig = ''
      limit_except POST { deny all; }
      limit_req zone=${app.name}-forms burst=3 nodelay;
      limit_req_status 429;
      client_max_body_size 16k;
    '';
  };

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
      assertion = !app.skyHeader || app.accentHeader;
      message = "app.${app.name}'s header is a sky, which is drawn on the accent header: set accentHeader = true under [app.${app.name}].";
    }
    {
      assertion = app.invites == null || app.principal.mail.send;
      message = "app.${app.name} mails requests for an invite to ${app.invites}, as itself, which sends no mail: set principal.mail.send under [app.${app.name}].";
    }
    {
      assertion = app.inquiries == null || app.principal.mail.send;
      message = "app.${app.name} mails inquiries to ${app.inquiries}, as itself, which sends no mail: set principal.mail.send under [app.${app.name}].";
    }
  ];

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;
    root = site;
    locations."/".tryFiles = "$uri $uri/ =404";
    locations."= /invite" = lib.mkIf (app.invites != null) form;
    locations."= /inquiry" = lib.mkIf (app.inquiries != null) form;
    extraConfig = ''
      error_page 404 /404.html;
    '';
  };

  services.nginx.appendHttpConfig = lib.mkIf hasForms ''
    limit_req_zone $binary_remote_addr zone=${app.name}-forms:1m rate=1r/m;
  '';

  systemd.services."${app.name}-forms" = lib.mkIf hasForms {
    description = "${app.name}: mails what visitors send with the site's forms";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    path = [ pkgs.msmtp ];
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        forms
        app.handle
        (toString app.invites)
        invite
        (toString app.inquiries)
        app.principal.bindAddress
        (toString formsPort)
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
