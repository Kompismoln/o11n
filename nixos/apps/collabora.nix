{
  app,
  lib,
  pkgs,
  ...
}:
let
  port = 9980;

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
      proxyPass = "http://[::1]:${toString port}";
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
    # Policy: coolwsd serves the hosts it's told of alone; told of none, it would serve whichever asked first.
    aliasGroups = map (url: {
      host = "${url}:${if lib.hasPrefix "https://" url then "443" else "80"}";
    }) app.collabora.allowedHosts;

    settings = {
      allowed_languages = "en_US sv_SE";
      ssl = {
        enable = false;
        termination = true;
      };
      # Fact: coolwsd listens on any or loopback, not on an address.
      net = {
        proto = "IPv6";
        listen = "loopback";
      };
      storage.wopi.alias_groups."@mode" = "groups";
    };
  };
}
