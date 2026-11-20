{
  lib,
  o11nLib,
  outputs,
}:
let
  inherit (outputs.nixosConfigurations) mx web;

  # Accommodating for the inventory, which has to evaluate: what would fail is evaluated from an altered copy of its spec.
  failing =
    word: change: name:
    let
      inherit
        ((o11nLib.mkNixosConfigurations (
          o11nLib.evalContext {
            inherit (outputs.context) path flake;
            spec = lib.recursiveUpdate outputs.context.spec change;
          }
        )).${name}
        )
        config
        ;
    in
    map (assertion: assertion.message) (
      lib.filter (
        assertion: !assertion.assertion && lib.hasInfix word assertion.message
      ) config.assertions
    );
  invites = failing "invite";
  managers = failing "manager";

  maps = mx.config.services.postfix.submissionOptions.smtpd_sender_login_maps;
  phpOptions = web.config.services.phpfpm.pools.blog.phpOptions;
  mobilizon = web.config.containers.calendar.config.services.mobilizon.settings.":mobilizon";
in
{
  # Policy: a principal that sends as others too sends as what the mail server lets it, envelope and From alike.
  test_send_as = {
    expr = {
      loginMaps = lib.hasPrefix "hash:/etc/postfix/vaccounts,pcre:${builtins.storeDir}/" maps;
      senderLogins = lib.splitString "\n" (builtins.readFile (lib.last (lib.splitString ",pcre:" maps)));
      smtpAuth = mx.config.services.postfix.settings.main.smtpd_sasl_auth_enable;
      setFromHeader = lib.mapAttrs (
        _: account: account.set_from_header
      ) web.config.programs.msmtp.accounts;
      wordpress = lib.any (lib.hasInfix "-a app-blog -t --read-envelope-from\"") (
        lib.splitString "\n" phpOptions
      );
      mobilizon = {
        inherit (mobilizon.":instance") email_from email_reply_to;
        inherit (mobilizon."Mobilizon.Web.Email.Mailer") username;
      };
    };
    expected = {
      loginMaps = true;
      senderLogins = [
        "/@example\\.org$/ blog@example.com"
        "/@example\\.net$/ calendar@example.com"
        ""
      ];
      smtpAuth = false;
      setFromHeader = {
        app-auth = "on";
        app-blog = "auto";
        app-calendar = "auto";
        app-www = "on";
        user-alice = "on";
      };
      wordpress = true;
      mobilizon = {
        email_from = "noreply@example.net";
        email_reply_to = "noreply@example.net";
        username = "calendar@example.com";
      };
    };
  };

  # Policy: a principal that manages another's mailboxes is another principal with an inbox on its domain, and isn't
  # also its reader.
  test_managers = {
    expr = {
      declared = managers { } "mx";
      both = managers { user.admin.principal.mail.managers = [ "user-alice" ]; } "mx";
      sendOnly = managers { user.admin.principal.mail.managers = [ "app-photos" ]; } "mx";
    };
    expected = {
      declared = [ ];
      both = [
        "user-admin has user-alice as a reader and a manager, who reads as it manages: drop it from principal.mail.readers."
      ];
      sendOnly = [
        "user-admin's manager app-photos is to be another principal with an inbox at an address on example.com, the domain the mail server takes from its login for Shared.admin: change principal.mail.managers."
      ];
    };
  };

  # Policy: a portal mails requests for an invite to an address the mail server of its domain has a mailbox at.
  test_invites_received = {
    expr = {
      elsewhere = invites { } "mx";
      alias = invites {
        app.www.invites = "Join@example.com";
        user.admin.principal.mail.aliases = [ "join@example.com" ];
      } "mx";
      postmaster = invites { app.www.invites = "postmaster@example.com"; } "mx";
      sendOnly = invites { app.www.invites = "photos@example.com"; } "mx";
      unowned = invites { app.www.invites = "join@example.com"; } "mx";
    };
    expected = {
      elsewhere = [ ];
      alias = [ ];
      postmaster = [ ];
      sendOnly = [
        "app.www mails requests for an invite to photos@example.com, on example.com, where no principal's inbox has it: add it to a principal's principal.mail.aliases, or change invites under [app.www]."
      ];
      unowned = [
        "app.www mails requests for an invite to join@example.com, on example.com, where no principal's inbox has it: add it to a principal's principal.mail.aliases, or change invites under [app.www]."
      ];
    };
  };
}
