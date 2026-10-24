# roles/webserver.nix
{
  flake.nixosModules.webserver = {
    imports = [
      ../nixos/collabora.nix
      ../nixos/egress-proxy.nix
      ../nixos/fail2ban.nix
      ../nixos/mobilizon.nix
      ../nixos/monitor.nix
      ../nixos/mysql.nix
      ../nixos/nextcloud.nix
      ../nixos/nextcloud-rolf.nix
      ../nixos/nginx.nix
      ../nixos/postgresql.nix
      ../nixos/react.nix
      ../nixos/redis.nix
      ../nixos/reverse-tunnel.nix
      ../nixos/svelte.nix
      ../nixos/wordpress.nix
    ];
    o11n = {
      reverse-tunnel.enable = true;
      egress-proxy.enable = true;
      fail2ban.enable = true;
      nginx = {
        enable = true;
        monitor = false;
      };
    };

  };
}
