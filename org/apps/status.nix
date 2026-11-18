{
  config,
  context,
  lib,
  ...
}:
{
  options = {
    groups = lib.mkOption {
      description = "the apps the page watches at their url, and a mail app at its ports too, by the group it shows them in";
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
      description = "nothing: a mail app in groups has its ports watched, which mail named the group of";
      internal = true;
      default = null;
      type = lib.types.raw;
      apply =
        mail:
        lib.throwIf (mail != null)
          "app.${config.name}.mail is gone: drop it, and list the mail app in a group of app.${config.name}.groups, as groups.${mail} = [\"<app>\"], which watches its ports."
          mail;
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
