{
  context,
  lib,
  ...
}:
{
  options = {
    groups = lib.mkOption {
      description = "the apps the page watches at their url, by the group it shows them in";
      type = lib.types.attrsOf (lib.types.listOf context.types.app.ref);
      default = { };
      example = {
        Services = [
          "drive"
          "meet"
        ];
      };
    };
    mail = lib.mkOption {
      description = "the group the page shows the mail server's ports in, mail.<endpoint>'s submission, imaps and smtp, or null for none";
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Mail";
    };
    interval = lib.mkOption {
      description = "how often each check runs, as Gatus takes it";
      type = lib.types.str;
      default = "2m";
    };
    portal = lib.mkOption {
      description = "the portal the page links back to, with its logo, and whose footer links to the page, or null";
      type = lib.types.nullOr context.types.app.ref;
      default = null;
    };
    announcements = lib.mkOption {
      description = "what the page announces, newest first, as Gatus's announcements: an incident, maintenance, or what's back to normal";
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            timestamp = lib.mkOption {
              description = "when, in RFC 3339";
              type = lib.types.str;
              example = "2026-11-18T09:00:00+01:00";
            };
            type = lib.mkOption {
              description = "what kind of announcement it is";
              type = lib.types.enum [
                "outage"
                "warning"
                "information"
                "operational"
                "none"
              ];
            };
            message = lib.mkOption {
              description = "what the page says";
              type = lib.types.str;
            };
          };
        }
      );
      default = [ ];
    };
  };
}
