{
  app,
  lib,
  org,
  pkgs,
  ...
}:
let
  cfg = {
    inherit (app) name endpoint;
    keycloak = {
      inherit (org.app.${app.jitsi.keycloak}) endpoint;
      inherit (app.jitsi) realm;
    };
  };
  issuer = "https://${cfg.keycloak.endpoint}/realms/${cfg.keycloak.realm}";
  # Dependency: org/apps/jitsi.nix derives the client, which the keycloak app keeps.
  client = app.jitsi.client.representation;
in
{

  config = {
    nixpkgs.config.allowInsecurePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "jitsi-meet"
      ];

    users.users.prosody.extraGroups = [ "jitsi-meet" ];

    # Accommodating for Jitsi Videobridge, whose libjitsi calls native code through JNA, which systemd's
    # ExecPaths/NoExecPaths would block.
    systemd.services.jitsi-videobridge2.serviceConfig = {
      StateDirectory = "jitsi-videobridge";
      ExecPaths = "/var/lib/jitsi-videobridge";
    };
    services.jitsi-videobridge.extraProperties."jna.tmpdir" = "/var/lib/jitsi-videobridge";

    services.jitsi-videobridge = {
      enable = true;
      openFirewall = true;
    };

    services.jitsi-meet = {
      enable = true;
      hostName = cfg.endpoint;

      # Fact: verbatim from the jitsi handbook, https://jitsi.github.io/handbook/docs/devops-guide/authentication.
      config = {
        hosts.anonymousdomain = "guest.${cfg.endpoint}";

        tokenAuthUrl =
          "${issuer}/protocol/openid-connect/auth"
          + "?client_id=${client.clientId}"
          + "&response_type=code&scope=openid"
          + "&state={state}"
          + "&redirect_uri=${lib.head client.redirectUris}"
          + "&code_challenge={code_challenge}&code_challenge_method=${
            client.attributes."pkce.code.challenge.method"
          }";

        tokenLogoutUrl =
          "${issuer}/protocol/openid-connect/logout"
          + "?post_logout_redirect_uri=${client.attributes."post.logout.redirect.uris"}";

        tokenAuthInline = true;

        sso = {
          ssoService = cfg.keycloak.endpoint;
          tokenService = "${cfg.keycloak.endpoint}/realms/${cfg.keycloak.realm}/protocol/openid-connect";
          inherit (client) clientId;
        };
      };
    };

    services.jicofo = {
      enable = true;
    };

    services.prosody = {
      package = pkgs.prosody.override {
        withExtraLuaPackages = p: [
          p.basexx
          p.cjson
          p.luaossl
          p.inspect
        ];
      };

      # Fact: NixOS's default muc, with muc_wait_for_host on conference, which triggers the auth flow.
      muc = lib.mkForce [
        {
          domain = "conference.${cfg.endpoint}";
          name = "Jitsi Meet MUC";
          allowners_muc = false;
          roomLocking = false;
          roomDefaultPublicJids = true;
          extraModules = [
            "muc_meeting_id"
            "muc_wait_for_host"
          ];
          extraConfig = ''
            restrict_room_creation = true
            storage = "memory"
            admins = { "focus@auth.${cfg.endpoint}" }
          '';
        }
        {
          domain = "breakout.${cfg.endpoint}";
          name = "Jitsi Meet Breakout MUC";
          roomLocking = false;
          roomDefaultPublicJids = true;
          extraModules = [ "muc_meeting_id" ];
          extraConfig = ''
            restrict_room_creation = true
            storage = "memory"
            admins = { "focus@auth.${cfg.endpoint}", "jvb@auth.${cfg.endpoint}" }
          '';
        }
        {
          domain = "internal.auth.${cfg.endpoint}";
          name = "Jitsi Meet Videobridge MUC";
          roomLocking = false;
          roomDefaultPublicJids = true;
          extraConfig = ''
            storage = "memory"
            admins = { "focus@auth.${cfg.endpoint}", "jvb@auth.${cfg.endpoint}", "jigasi@auth.${cfg.endpoint}" }
          '';
        }
        {
          domain = "lobby.${cfg.endpoint}";
          name = "Jitsi Meet Lobby MUC";
          roomLocking = false;
          roomDefaultPublicJids = true;
          extraConfig = ''
            restrict_room_creation = true
            storage = "memory"
          '';
        }
      ];

      # Fact: asap_* is the jitsi handbook's; the default log includes debug; prosody needs ssl for its certificate.
      extraConfig = ''
        asap_accepted_issuers = { "${issuer}" }
        asap_accepted_audiences = { "account" }
        asap_require_room_claim = false;
        log = { { to = "syslog", levels = { min = "info" } } }
        ssl = { cafile = "/etc/ssl/certs/ca-bundle.crt" }
      '';

      virtualHosts = {
        "${cfg.endpoint}".extraConfig = lib.mkForce ''
          authentication = "token"
          app_id = "${cfg.name}"
          allow_empty_token = false
          cache_keys_url = "${issuer}/protocol/openid-connect/certs"
          lobby_muc = "lobby.${cfg.endpoint}"
          main_muc = "conference.${cfg.endpoint}"
          modules_enabled = {
            "persistent_lobby";
          }
        '';

        "guest.${cfg.endpoint}".extraConfig = lib.mkForce ''
          authentication = "jitsi-anonymous"
          modules_enabled = {
            "smacks";
          }
        '';
      };
    };
  };
}
