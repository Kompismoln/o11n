{
  services.openssh.extraConfig = ''
    Match User egress-proxy
      AllowTcpForwarding local
      X11Forwarding no
      AllowAgentForwarding no
      PermitTunnel no
      PermitTTY no
  '';
}
