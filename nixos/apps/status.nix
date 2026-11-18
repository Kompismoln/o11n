{
  app,
  host,
  lib,
  org,
  ...
}:
let
  port = 8080;
  portal = lib.mapNullable (name: org.app.${name}) app.portal;
  mail = "mail.${org.mailserver.endpoint}";

  # Policy: a certificate is a failure a week before it expires, three weeks after ACME would have renewed it.
  certified = [ "[CERTIFICATE_EXPIRATION] > 168h" ];

  watched = group: name: {
    inherit group;
    name = org.app.${name}.endpoint;
    inherit (org.app.${name}) url;
    inherit (app) interval;
    conditions = [ "[STATUS] < 500" ] ++ lib.optionals org.app.${name}.ssl certified;
    # Policy: an app answers for itself, so a redirect is its answer, rather than where it leads, as a login elsewhere.
    client.ignore-redirect = true;
  };

  mailPorts = group: [
    {
      inherit group;
      name = "${mail} submission";
      url = "starttls://${mail}:587";
      inherit (app) interval;
      conditions = [ "[CONNECTED] == true" ] ++ certified;
    }
    {
      inherit group;
      name = "${mail} imaps";
      url = "tls://${mail}:993";
      inherit (app) interval;
      conditions = [ "[CONNECTED] == true" ] ++ certified;
    }
    {
      inherit group;
      name = "${mail} smtp";
      url = "tcp://${mail}:25";
      inherit (app) interval;
      conditions = [ "[CONNECTED] == true" ];
    }
  ];
in
{
  assertions = [
    {
      assertion =
        lib.count (other: other.kind == "status" && lib.elem host.name other.run-on-hosts) (
          lib.attrValues org.app
        ) == 1;
      message = "${host.name} runs more than one status app, as it runs one Gatus: run app.${app.name} on another host.";
    }
    {
      assertion = app.groups != { } || app.mail != null;
      message = "app.${app.name} watches nothing: set groups, or mail, under [app.${app.name}].";
    }
  ];

  services.gatus = {
    enable = true;
    settings = {
      web = {
        # Accommodating for Gatus, which joins its address and port as they are.
        address = "[${app.principal.bindAddress}]";
        inherit port;
      };
      storage = {
        type = "sqlite";
        path = "/var/lib/gatus/data.db";
      };
      ui = {
        title = "${org.name} status";
        header = org.name;
        dashboard-heading = "Status";
        dashboard-subheading = "${org.name}'s services, checked every ${app.interval}";
        default-sort-by = "group";
      }
      // lib.optionalAttrs (portal != null) {
        link = portal.url;
      }
      # Dependency: nixos/apps/portal.nix serves its logo at /logo.<extension>.
      // lib.optionalAttrs (portal != null && portal.logo != null) {
        logo = "${portal.url}/logo.${lib.last (lib.splitString "." (baseNameOf portal.logo))}";
      };
      endpoints =
        lib.concatLists (lib.mapAttrsToList (group: map (watched group)) app.groups)
        ++ lib.optionals (app.mail != null) (mailPorts app.mail);
    }
    // lib.optionalAttrs (app.announcements != [ ]) {
      inherit (app) announcements;
    };
  };

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;
    locations."/".proxyPass = "http://[${app.principal.bindAddress}]:${toString port}";
  };
}
