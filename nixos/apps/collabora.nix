# nixos/apps/collabora.nix
{
  app,
  lib,
  pkgs,
  ...
}:
let
  port = 9980;
  inherit (app.principal) bindAddress;

  dicts = [
    pkgs.hunspellDicts.sv_SE
    pkgs.hunspellDicts.en_US
  ];
in
{
  environment.systemPackages = dicts;

  systemd.services.coolwsd = {
    environment.DICPATH = lib.concatMapStringsSep ":" (d: "${d}/share/hunspell") dicts;
    preStart = ''
      mkdir -p /var/lib/cool/systemplate/usr/share/hunspell

      ${pkgs.lib.concatMapStringsSep "\n" (dict: ''
        for f in ${dict}/share/hunspell/*; do
          ln -sf "$f" /var/lib/cool/systemplate/usr/share/hunspell/
        done
      '') dicts}
    '';
  };

  services.nginx.virtualHosts.${app.endpoint} =
    let
      proxyPass = "http://[${bindAddress}]:${toString port}";
    in
    {
      forceSSL = app.ssl;
      enableACME = app.ssl;

      locations = {
        "^~ /browser" = {
          inherit proxyPass;
          extraConfig = ''
            proxy_set_header Host $host;
          '';
        };
        "^~ /hosting/discovery" = {
          inherit proxyPass;
          extraConfig = ''
            proxy_set_header Host $host;
          '';
        };
        "^~ /hosting/capabilities" = {
          inherit proxyPass;
          extraConfig = ''
            proxy_set_header Host $host;
          '';
        };
        "~ ^/(c|l)ool" = {
          inherit proxyPass;
          extraConfig = ''
            proxy_set_header Host $host;
          '';
        };

        "~ ^/cool/(.*)/ws$" = {
          priority = 1;
          inherit proxyPass;
          extraConfig = ''
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "Upgrade";
            proxy_set_header Host $host;
            proxy_read_timeout 36000s;
          '';
        };

        "^~ /cool/adminws" = {
          inherit proxyPass;
          extraConfig = ''
            proxy_set_header Host $host;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "Upgrade";
            proxy_read_timeout 36000s;
          '';
        };
      };
    };

  services.collabora-online = {
    enable = true;
    inherit port;
    aliasGroups = app.collabora.allowedHosts;

    settings = {
      allowed_languages = "en_US sv_SE";
      ssl = {
        enable = false;
        termination = true;
      };
      net = {
        proto = "IPv6";
        listen = bindAddress;
      };
    };
  };
}
