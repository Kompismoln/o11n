{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.o11n.jitsi;
  issuer = "https://${cfg.keycloak.endpoint}/realms/${cfg.keycloak.realm}";
in
{
  options.o11n.jitsi = {
    enable = lib.mkEnableOption "Jitsi Meet with keycloak authentication";

    name = lib.mkOption {
      type = lib.types.str;
      description = "Name is used as client id for this instance";
      example = "jitsi";
    };

    endpoint = lib.mkOption {
      type = lib.types.str;
      description = "Public domain jitsi is served on";
      example = "meet.example.com";
    };

    keycloak = lib.mkOption {
      type = lib.types.submodule {
        options = {
          endpoint = lib.mkOption {
            type = lib.types.str;
            description = "Public domain keycloak is served on";
            example = "auth.example.com";
          };
          realm = lib.mkOption {
            type = lib.types.str;
            description = "Keycloak realm for this instance";
            example = "jitsi-realm";
          };
        };
      };
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowInsecurePredicate =
      pkg:
      builtins.elem (lib.getName pkg) [
        "jitsi-meet"
      ];

    # Jitsi Videobridge is a JVM app, and it depends on libjitsi,
    # which uses JNA (Java Native Access) to call into native code.
    # SystemD's ExecPaths/NoExecPaths restriction block this call.
    # So we unblock it.
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

      # Verbatim from jitsi handbook
      # https://jitsi.github.io/handbook/docs/devops-guide/authentication
      config = {
        hosts.anonymousdomain = "guest.${cfg.endpoint}";

        tokenAuthUrl =
          "${issuer}/protocol/openid-connect/auth"
          + "?client_id=${cfg.name}"
          + "&response_type=code&scope=openid"
          + "&state={state}"
          + "&redirect_uri=https://${cfg.endpoint}/static/sso.html"
          + "&code_challenge={code_challenge}&code_challenge_method=S256";

        tokenLogoutUrl =
          "${issuer}/protocol/openid-connect/logout"
          + "?post_logout_redirect_uri=https://${cfg.endpoint}/static/logout.html";

        tokenAuthInline = true;

        sso = {
          ssoService = cfg.keycloak.endpoint;
          tokenService = "${cfg.keycloak.endpoint}/realms/${cfg.keycloak.realm}/protocol/openid-connect";
          clientId = cfg.name;
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

      # NixOS's default muc but with muc_wait_for_host as extra module on conference
      # to trigger auth flow.
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

      # asap_* is from jitsi handbook
      # default log includes debug which is chatty af
      # ssl is needed for prosody to be able to certificate
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
