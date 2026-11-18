{ org, pkgs, ... }:
{
  services.fail2ban = {
    enable = true;
    maxretry = 1;
    bantime = "1d";
    bantime-increment.enable = true;
    # Fact: iptables refuses a chain name over 28 characters, as f2b-<jail> is for a jail named after an app, and
    # fail2ban counts the ban anyway; nftables's actions ban in sets of their own table, whose names have room.
    banaction = "nftables-multiport";
    banaction-allports = "nftables-allports";
    packageFirewall = pkgs.nftables;
    ignoreIP = [
      "${org.prefix}::/48"
      "${org.prefix4}.0.0/16"
    ];
  };
}
