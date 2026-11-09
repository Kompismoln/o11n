{
  config,
  lib,
  org,
  pkgs,
  ...
}:
let
  inherit (org.service.logs) name;

  summary = pkgs.writeShellApplication {
    name = "o11n-logs";
    # Policy: a section that finds nothing says nothing, and the rest go on.
    bashOptions = [
      "nounset"
      "pipefail"
    ];
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gzip
      pkgs.iproute2
      config.systemd.package
    ];
    runtimeEnv = {
      ORG_PREFIX6 = org.prefix;
      ORG_PREFIX4 = org.prefix4;
    };
    text = builtins.readFile ./logs.sh;
  };
in
{
  # Policy: the logs service reads the journal and nginx's logs as itself, and its ssh-key runs the summary alone, with
  # nothing forwarded; it's no one's way to a shell or to root.
  users.users.${name} = {
    shell = pkgs.bash;
    extraGroups = [ "systemd-journal" ];
  };

  services.openssh.extraConfig = ''
    Match User ${name}
      ForceCommand ${lib.getExe summary} "\$SSH_ORIGINAL_COMMAND"
      AllowTcpForwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      X11Forwarding no
      PermitTunnel no
      PermitTTY no
  '';

  # Fact: tmpfiles sets an ACL on what exists, and nginx makes its log directory as it starts, after tmpfiles.
  systemd.tmpfiles.rules = lib.optionals config.services.nginx.enable [
    "d /var/log/nginx 0750 ${config.services.nginx.user} ${config.services.nginx.group} -"
    "A+ /var/log/nginx - - - - u:${name}:rX,d:u:${name}:rX"
  ];
}
