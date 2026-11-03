{
  config,
  lib,
  pkgs,
  org,
  ...
}:

let
  cfg = config.o11n.glesys.updaterecord;
in
{

  options.o11n.glesys.updaterecord = {
    recordid = lib.mkOption {
      description = "The glesys id of the record";
      type = lib.types.str;
    };
    device = lib.mkOption {
      description = "Device that should be watched.";
      type = lib.types.str;
    };
  };

  config = {

    sops.secrets."glesys-api/secret-key" = {
      inherit (org.service.glesys-api.secrets) sopsFile;
      owner = "root";
      group = "root";
    };

    systemd.services."glesys-updaterecord" = {
      description = "update A record for stationary.kompismoln.se";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig =
        let
          user = "${org.service.glesys-api.data.account}:$(<${
            config.sops.secrets."glesys-api/secret-key".path
          })";
          data = "recordid=${cfg.recordid}&data=$ipv4";
          url = "${org.service.glesys-api.endpoint}/domain/updaterecord";
        in
        {
          ExecStart = pkgs.writeShellScript "glesys-updaterecord" ''
            ipv4="$(${pkgs.iproute2}/bin/ip -4 -o addr show ${cfg.device} | ${pkgs.gawk}/bin/awk '{split($4, a, "/"); print a[1]}')"
            ${lib.getExe pkgs.curl} -sSX POST -d "${data}" -u ${user} ${url} | ${pkgs.util-linux}/bin/logger -t dhcpcd
          '';
        };
    };

    systemd.timers."glesys-updaterecord" = {
      description = "update A record for stationary.ahbk.se every 10 minutes";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "10min";
      };
    };
  };
}
