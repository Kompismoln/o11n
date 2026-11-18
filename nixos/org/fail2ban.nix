{
  lib,
  org,
  pkgs,
  ...
}:
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
    # Fact: journald keeps the lines of a service that runs as an app, whose uid is over 999, in a journal of the uid's,
    # which the systemd backend reads only if it was there as the jail started, unless it opens the local journals
    # rather than the files it finds.
    jails.DEFAULT.settings.backend = lib.mkForce "systemd[journalflags=1, rotated=on]";
    ignoreIP = [
      "${org.prefix}::/48"
      "${org.prefix4}.0.0/16"
    ];
  };
}
