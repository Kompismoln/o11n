# nixos/apps/django.nix
{
  app,
  config,
  host,
  inputs,
  ...
}:
let
  packages = inputs.${app.django.input}.packages.${host.system};
in
{
  imports = [
    ../django.nix
    ../nginx.nix
  ];

  sops.secrets."${app.name}/secret-key" = {
    inherit (app.secrets) sopsFile;
    owner = app.name;
    group = app.name;
  };

  o11n.django.apps.${app.name} = {
    enable = true;
    inherit (app) name endpoint;
    inherit (app.principal) bindAddress;
    inherit (app.django)
      module
      locationProxy
      trustedOrigins
      timeout
      ;
    home = "${app.principal.home}/django";
    package = packages.django-app;
    scripts = packages.scripts or null;
    secretKeyPath = config.sops.secrets."${app.name}/secret-key".path;
    inherit (app) database;
    user = app.name;
  };
}
