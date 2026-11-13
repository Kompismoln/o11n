{
  app,
  host,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  packages = inputs.${app.rolf.input}.packages.${host.system};
  user = app.name;
  inherit (app.principal) home;
  source = "${home}/${app.rolf.source}";
  siteRoot = "${home}/_site";
  sourceRoot = "${home}/_src";

  sync =
    pkgs.runCommand app.name
      {
        src = packages.default;
        nativeBuildInputs = [ pkgs.makeWrapper ];
      }
      ''
        mkdir -p $out/bin

        makeWrapper \
          $src/bin/rolf \
          $out/bin/${app.name} \
            --append-flags ${source} \
            --append-flags ${sourceRoot} \
            --append-flags ${siteRoot} \
            --append-flags --watch
      '';
in
{
  environment.systemPackages = [ sync ];

  # Policy: nginx serves the site from the app's home, which only the app's group can enter.
  assertions = [
    {
      assertion = lib.elem "nginx" app.principal.members;
      message = "rolf ${app.name} has nginx serve its site from ${home}: add \"nginx\" to app.${app.name}.principal.members.";
    }
  ];

  systemd.tmpfiles.rules = [
    "d '${source}' 0750 ${user} ${user} - -"
  ];

  services.nginx.virtualHosts.${app.endpoint} = {
    forceSSL = app.ssl;
    enableACME = app.ssl;

    root = siteRoot;
    locations."/" = {
      index = "index.html";
      tryFiles = "$uri $uri/ /404.html";
    };
  };

  systemd.timers."${app.name}-build" = {
    description = "Scheduled building of todays articles";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:00";
      Unit = "${app.name}-build.service";
    };
  };

  systemd.services = {
    "${app.name}-build" = {
      description = "run ${app.name}-build";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${packages.gems}/bin/jekyll build -s ${sourceRoot} -d ${siteRoot} --disable-disk-cache";
        WorkingDirectory = sourceRoot;
        User = user;
        Group = user;
      };
    };
    ${app.name} = {
      description = "run ${app.name}";
      serviceConfig = {
        ExecStart = "${sync}/bin/${app.name}";
        WorkingDirectory = home;
        User = user;
        Group = user;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
