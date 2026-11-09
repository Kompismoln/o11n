# nixos/org/log-retention.nix
# Policy: a host keeps its logs, and fail2ban its record of bans, for the org's logRetention.
{
  config,
  lib,
  org,
  ...
}:
let
  days = toString org.logRetention;
in
{
  # Fact: journald removes a file of its journal once all of it is past MaxRetentionSec, and starts one a month by
  # default; a day's file keeps the retention to a day of it.
  services.journald.settings.Journal = {
    MaxRetentionSec = "${days}d";
    MaxFileSec = "1day";
  };

  # Fact: logrotate removes only the file past its count, so a count that was higher leaves the rest behind, and a
  # flood's rotations within a day shorten the days its count keeps: the count bounds what a flood leaves on /var, and
  # tmpfiles removes by age. logrotate's renames refresh a file's ctime, so age is its mtime alone.
  services.logrotate.settings.nginx.rotate = lib.mkIf config.services.nginx.enable (
    2 * org.logRetention
  );
  systemd.tmpfiles.rules = lib.mkIf config.services.nginx.enable [
    "e /var/log/nginx - - - m:${days}d"
    "x /var/log/nginx/*.log"
  ];

  # Fact: bantime-increment finds an address's earlier bans in fail2ban's database, which forgets them after dbpurgeage,
  # a day by default.
  services.fail2ban.daemonSettings.Definition.dbpurgeage =
    lib.mkIf config.services.fail2ban.enable "${days}d";
}
