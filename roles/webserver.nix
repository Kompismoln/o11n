# roles/webserver.nix
{ inputs, ... }:
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
    nixpkgs.overlays = [
      (import ../overlays/webserver.nix { inherit inputs; })
    ];
    o11n = {
      reverse-tunnel.enable = true;
      egress-proxy.enable = true;
      fail2ban.enable = true;
      postgresql.enable = true;
      nginx = {
        enable = true;
        monitor = false;
      };
    };

  };
}
