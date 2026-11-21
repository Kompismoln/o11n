{
  app,
  lib,
  pkgs,
  ...
}@args:
let
  inherit (import ./portal/site.nix args) site;

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
