# nixos/org/ssh.nix
{ org, ... }:
{
  services = {
    fail2ban.jails = {
      sshd.settings = {
        filter = "sshd[mode=normal]";
      };
    };

    openssh = {
      enable = true;
      # Policy: the org's own addresses, whose peers wireguard has let in, are spared sshd's penalties, as for
      # connections o11n opens without logging in.
      settings.PerSourcePenaltyExemptList = "${org.prefix}::/48,${org.prefix4}.0.0/16";
      extraConfig = ''
        Match User *
          PasswordAuthentication no
          ChallengeResponseAuthentication no
          KbdInteractiveAuthentication no
      '';

      hostKeys = [
        {
          path = "/keys/ssh_host_ed25519_key";
          type = "ed25519";
        }
      ];
    };
  };
}
