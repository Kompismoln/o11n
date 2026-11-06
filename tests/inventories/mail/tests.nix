{
  lib,
  outputs,
}:
let
  inherit (outputs.nixosConfigurations) mx web;

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
}
