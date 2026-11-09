{ org, ... }:
{
  services.fail2ban = {
    enable = true;
    maxretry = 1;
    bantime = "1d";
    bantime-increment.enable = true;
    ignoreIP = [
      "${org.prefix}::/48"
      "${org.prefix4}.0.0/16"
    ];
  };
}
