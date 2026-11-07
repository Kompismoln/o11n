{ org, ... }:
{
  services.fail2ban = {
    enable = true;
    maxretry = 1;
    bantime = "1d";
    bantime-increment.enable = true;
    # Policy: as sshd's penalties spare them (nixos/org/ssh.nix), so does fail2ban spare the org's own addresses, which
    # wireguard has let in.
    ignoreIP = [
      "${org.prefix}::/48"
      "${org.prefix4}.0.0/16"
    ];
  };
}
