{
  config,
  context,
  lib,
  ...
}:
{
  options = {
    dkimSelector = lib.mkOption {
      description = "the selector of the server's dkim keys";
      type = lib.types.str;
    };
    admin = lib.mkOption {
      description = "the address that hears of what goes wrong, a unit that fails on a host whose principal sends through the server, a principal's address or alias with an inbox on it, which is postmaster of each of its domains with a mailbox no principal is postmaster of";
      type = lib.types.str;
      default = "admin@${context.org.endpoint}";
      defaultText = lib.literalExpression ''"admin@''${org.endpoint}"'';
    };
    glesys = lib.mkOption {
      description = "the GleSYS account whose DNS holds the records the server's mail is read by, in each of `zones`, or null";
      default = null;
      type = lib.types.nullOr (
        lib.types.submodule {
          options = {
            account = lib.mkOption {
              description = "the account, as GleSYS names it";
              type = lib.types.str;
              example = "CL12345";
            };
            key = lib.mkOption {
              description = "the app's secret that is the account's API key, which may list, add and update its DNS records";
              type = lib.types.str;
              default = "glesys-key";
            };
            dmarc = lib.mkOption {
              description = "the policy each zone's DMARC record asks a receiver to take with mail that fails it";
              type = lib.types.enum [
                "none"
                "quarantine"
                "reject"
              ];
              default = "none";
            };
            zones = lib.mkOption {
              description = "the server's domains whose zones are the account's, which it keeps the records of";
              type = lib.types.listOf lib.types.str;
              example = [ "example.com" ];
            };
          };
        }
      );
    };
    host = lib.mkOption {
      description = "the host the server runs on, its one of run-on-hosts, which runs no other mail app";
      internal = true;
      readOnly = true;
      type = lib.types.str;
      # Policy: read from the org's spec, as each mail app's host would otherwise read every other's.
      default =
        let
          others = lib.attrNames (
            lib.filterAttrs (
              name: other:
              name != config.name
              && other.kind or null == "mail"
              && lib.any (host: lib.elem host config.run-on-hosts) (other.run-on-hosts or [ ])
            ) (context.spec.app or { })
          );
        in
        if lib.length config.run-on-hosts != 1 then
          throw "app.${config.name} is the mail server at ${config.endpoint}, on ${lib.concatStringsSep " and " config.run-on-hosts}, which is one host alone: set one in its run-on-hosts."
        else if others != [ ] then
          throw "${lib.head config.run-on-hosts} runs app.${config.name} and app.${lib.head others}, each a mail server on its ports: run each on a host of its own."
        else
          lib.head config.run-on-hosts;
      defaultText = lib.literalMD "the one host of `run-on-hosts`";
    };
    domains = lib.mkOption {
      description = "the org's domains whose mail the server is, those whose `mail` is the app";
      internal = true;
      readOnly = true;
      type = lib.types.listOf lib.types.raw;
      default = lib.filter (domain: domain.mail == config.name) (lib.attrValues context.org.domain);
      defaultText = lib.literalMD "each of the org's `domain` whose `mail` is the app";
    };
  };
}
