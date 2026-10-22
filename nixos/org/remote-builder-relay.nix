# nixos/org/remote-builder-relay.nix
{
  config,
  host,
  lib,
  org,
  ...
}:
let
  pathPrefix = "nix-daemon";

  builders = lib.filter (peer: lib.elem "remote-builder" peer.roles) (lib.attrValues org.host);

  builder = lib.throwIfNot (lib.length builders == 1) ''
    The remote-builder-relay role relays to the host with the remote-builder role, and there are ${toString (lib.length builders)}.
  '' (lib.head builders);

  vpn = lib.throwIfNot (lib.any (vpn: lib.elem vpn builder.vpns) host.vpns) ''
    ${host.name} relays to ${builder.name} over a vpn, and they share none.
  '' (lib.findFirst (vpn: lib.elem vpn builder.vpns) null host.vpns);
in
{
  imports = [
    ../nginx.nix
  ];

  assertions = [
    {
      assertion = host.endpoint != null;
      message = "The remote-builder-relay role serves on the host's endpoint, and ${host.name} has none.";
    }
  ];

  o11n.nginx.enable = true;

  # A tunnel sends a request per write, so connections to the builder are kept open.
  services.nginx.upstreams.nix-remote-builder = {
    servers."[${builder.network.${vpn}.address}]:443" = { };
    extraConfig = "keepalive 8;";
  };

  # For clients that can't reach the builder themselves, such as an IPv4-only one when the
  # builder has only IPv6. The builder checks their bearer.
  services.nginx.virtualHosts.${host.endpoint} = {
    forceSSL = true;
    enableACME = true;
    locations."/${pathPrefix}/" = {
      proxyPass = "https://nix-remote-builder";
      # The builder's nginx picks its vhost by Host, so it gets the builder's endpoint.
      recommendedProxySettings = false;
      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_set_header Host ${builder.endpoint};
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_ssl_server_name on;
        proxy_ssl_name ${builder.endpoint};
        proxy_ssl_verify on;
        proxy_ssl_verify_depth 2;
        proxy_ssl_trusted_certificate ${config.security.pki.caBundle};
      '';
    };
  };
}
