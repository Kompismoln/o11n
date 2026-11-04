# roles/app-scheduler.nix
{
  flake.nixosModules.app-scheduler =
    {
      lib,
      host,
      org,
      ...
    }:
    let
      apps = lib.filter (app: lib.elem host.name app.run-on-hosts) (lib.attrValues org.app);
    in
    {
      # Policy: an app gets its kind's configuration and its own, called with the app as the org's is; an app of a
      # kind is served through nginx.
      imports =
        lib.optional (lib.any (app: app.kind != null) apps) ../nixos/nginx.nix
        ++ lib.concatMap (
          app:
          map
            (
              file:
              {
                inputs,
                o11nInputs,
                config,
                host,
                pkgs,
                org,
                lib,
                ...
              }:
              (import file) {
                inherit
                  app
                  o11nInputs
                  inputs
                  config
                  host
                  pkgs
                  org
                  lib
                  ;
              }
            )
            (
              lib.optional (app.kind != null) ../nixos/apps/${app.kind}.nix
              ++ lib.optional (app.configurationFile != null) app.configurationFile
            )
        ) apps;

      config = lib.mkMerge (
        map (app: {
          services.nginx.virtualHosts = lib.genAttrs (app.altpoints or [ ]) (_: {
            forceSSL = true;
            enableACME = true;
            locations."/".return = "301 https://${app.endpoint}$request_uri";
          });
        }) apps
      );
    };
}
