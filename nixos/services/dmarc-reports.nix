{
  config,
  lib,
  org,
  pkgs,
  ...
}:
let
  service = org.service.dmarc-reports;
  ready = org.mailserver != null && service.principal != null && service.principal.mail.inbox;

  read = pkgs.writeShellApplication {
    name = "dmarc-reports";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      getent
      gnused
      gzip
      ripmime
      unzip
      xmlstarlet
    ];
    text = builtins.readFile ./dmarc-reports.sh;
  };
in
{
  imports = [
    ../org/mail.nix
  ];

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = org.mailserver != null;
          message = "The dmarc-reports service reads the reports at the mail server: declare [mailserver].";
        }
        {
          assertion = service.principal != null && service.principal.mail.inbox;
          message = "The dmarc-reports service reads the reports in its own inbox, as its principal: give [service.dmarc-reports] an id and principal.mail.inbox = true.";
        }
      ];
    }

    (lib.mkIf ready {
      o11n.mail.failures.dmarc-reports = service.handle;

      systemd.services.dmarc-reports = {
        description = "Read the DMARC reports in ${service.principal.mail.address}'s inbox";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        environment = {
          DMARC_SERVER = "mail.${org.mailserver.endpoint}";
          DMARC_LOGIN = service.principal.mail.address;
          DMARC_PASSWORD = config.sops.secrets."${service.name}/mail".path;
          DMARC_RETENTION = toString org.logRetention;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe read;
          User = service.name;
          Group = service.name;
          CapabilityBoundingSet = "";
          LockPersonality = true;
          MemoryDenyWriteExecute = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHome = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          ProtectProc = "invisible";
          ProtectSystem = "strict";
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
            "AF_UNIX"
          ];
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          SystemCallArchitectures = "native";
          SystemCallFilter = "@system-service";
        };
      };

      systemd.timers.dmarc-reports = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "hourly";
          Persistent = true;
        };
      };
    })
  ];
}
