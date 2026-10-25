{
  config,
  host,
  inputs,
  lib,
  ...
}:

let
  cfg = config.o11n.react;

  eachSite = lib.filterAttrs (_: cfg: cfg.enable) cfg.sites;

  siteOpts = {
    options = {
      enable = lib.mkEnableOption "react-app for this host.";
      location = lib.mkOption {
        description = "URL path to serve the application.";
        default = "/";
        type = lib.types.str;
      };
      ssl = lib.mkOption {
        description = "Whether the react-app can assume https or not.";
        type = lib.types.bool;
      };
      api = lib.mkOption {
        description = "URL for the API endpoint";
        type = lib.types.str;
      };
      appname = lib.mkOption {
        description = "Internal namespace";
        type = lib.types.str;
      };
      hostname = lib.mkOption {
        description = "Network namespace";
        type = lib.types.str;
      };
    };
  };

  reactPkgs' = appname: inputs.${appname}.packages.${host.system}.vite-static;

  reactPkgs = lib.mapAttrs (
    _: cfg:
    (reactPkgs' cfg.appname).overrideAttrs {
      env = {
        VITE_API_ENDPOINT = cfg.api;
      };
    }
  ) cfg.sites;
in
{

  options = {
    o11n.react = {
      sites = lib.mkOption {
        type = with lib.types; attrsOf (submodule siteOpts);
        default = { };
        description = "Specification of one or more React sites to serve";
      };
    };
  };

  config = lib.mkIf (eachSite != { }) {
    services.nginx.virtualHosts = lib.mapAttrs' (
      _: cfg:
      lib.nameValuePair cfg.hostname {
        forceSSL = cfg.ssl;
        enableACME = cfg.ssl;
        root = "${reactPkgs.${cfg.appname}}/dist";
        locations."${cfg.location}" = {
          index = "index.html";
          extraConfig = ''
            try_files $uri $uri/ /index.html;
          '';
        };
      }
    ) eachSite;
  };
}
